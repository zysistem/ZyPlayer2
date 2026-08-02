import Foundation
import Observation

/// Plays a torrent without downloading it first.
///
/// aria2, which drives the Downloads screen, has no sequential piece selection —
/// it is built for "fetch the file, then watch it". Streaming needs the opposite,
/// so this runs the vendored WebTorrent helper (`Vendor/TorrentStream`), which
/// pulls pieces front-to-back and serves them over local HTTP for mpv to read.
///
/// Everything it fetches lands in a cache directory that is wiped when playback
/// stops and again when the app launches, so nothing survives a session.
@Observable
final class TorrentStreamer {

    enum Phase: Equatable {
        case idle
        /// Helper starting, metadata not in yet.
        case connecting
        /// Metadata is in; filling the buffer before handing over to the player.
        case buffering
        /// Playing.
        case streaming
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var peers = 0
    private(set) var speed: Int64 = 0
    private(set) var progress: Double = 0
    private(set) var downloaded: Int64 = 0
    /// 0–1 of the head buffer the helper fills before playback can start.
    private(set) var bufferProgress: Double = 0
    private(set) var title = ""
    /// Hash of the release being streamed, so its row can show the state.
    private(set) var activeHash: String?
    private(set) var activeFileIndex: Int?

    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var stdoutBuffer = Data()
    @ObservationIgnored private var streamURL: URL?
    @ObservationIgnored private var onReady: ((URL, String) -> Void)?
    @ObservationIgnored private var handedOver = false
    @ObservationIgnored private var watchdog: Task<Void, Never>?
    /// True once the helper says the head buffer is full.
    @ObservationIgnored private var isPlayable = false

    /// A swarm that has produced nothing by now is not going to.
    private static let firstByteTimeout = Duration.seconds(75)

    var isBusy: Bool {
        switch phase {
        case .connecting, .buffering, .streaming: true
        case .idle, .failed: false
        }
    }

    // MARK: - Environment

    /// The helper is a folder reference in the bundle's Resources.
    static var helperURL: URL? {
        guard let dir = Bundle.main.url(forResource: "TorrentStream", withExtension: nil) else {
            return nil
        }
        let script = dir.appendingPathComponent("stream.mjs")
        return FileManager.default.fileExists(atPath: script.path) ? script : nil
    }

    /// Node ships with neither macOS nor the app; it has to be on the machine.
    static var nodeURL: URL? {
        for path in ["/usr/local/bin/node", "/opt/homebrew/bin/node", "/usr/bin/node"] {
            if FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    static var isAvailable: Bool { helperURL != nil && nodeURL != nil }

    static var unavailableReason: String? {
        if helperURL == nil { return "Torrent akış yardımcısı uygulamada bulunamadı." }
        if nodeURL == nil { return "Node.js bulunamadı. `brew install node` ile kurun." }
        return nil
    }

    /// Wiped on stop and on launch — a crash must not leave gigabytes behind.
    static var cacheDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base
            .appendingPathComponent("ZyPlayer", isDirectory: true)
            .appendingPathComponent("TorrentStream", isDirectory: true)
    }

    static func clearCache() {
        try? FileManager.default.removeItem(at: cacheDirectory)
    }

    /// Yardımcıyı öldürür ve **öldüğü kesinleştikten sonra** önbelleği siler.
    ///
    /// Sıra burada her şeydir: `terminate()` yalnızca SIGTERM gönderir, süreç o
    /// anda ölmez. Hemen ardından silinen klasörü hâlâ yazmakta olan WebTorrent
    /// yeniden yaratır ve indirdiği parçalar diskte kalır — kapatılan her
    /// içerikten geriye gigabaytlar birikmesinin sebebi budur.
    private static func shutDown(_ process: Process, then finish: (() -> Void)? = nil) {
        process.terminate()
        // Takılmış bir sürecin arkasında süresiz beklenmez.
        let deadline = Date().addingTimeInterval(4)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
        }
        clearCache()
        finish?()
    }

    /// `torrent-stream.log`, next to mpv's own log. Truncated per run.
    private static func errorLogHandle() -> FileHandle? {
        let url = AppPaths.file("torrent-stream.log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return try? FileHandle(forWritingTo: url)
    }

    // MARK: - Playback

    /// Starts streaming `torrent`. `onReady` fires once, with the local URL to
    /// hand to the player, as soon as enough has buffered.
    @MainActor
    func start(_ torrent: TorrentOption, title: String, onReady: @escaping (URL, String) -> Void) {
        stop()

        self.title = title
        self.onReady = onReady
        self.activeHash = torrent.id
        self.activeFileIndex = torrent.fileIndex
        
        guard let node = Self.nodeURL, let helper = Self.helperURL else {
            phase = .failed(Self.unavailableReason ?? "Torrent akışı kullanılamıyor.")
            return
        }

        let directory = Self.cacheDirectory
        try? FileManager.default.removeItem(at: directory)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            phase = .failed("Önbellek klasörü oluşturulamadı.")
            return
        }

        self.title = title
        self.onReady = onReady
        self.activeHash = torrent.id
        self.handedOver = false
        self.peers = 0
        self.speed = 0
        self.progress = 0
        self.downloaded = 0
        self.phase = .connecting

        let task = Process()
        task.executableURL = node
        var arguments = [
            helper.path,
            "--torrent", torrent.link,
            "--dir", directory.path,
            "--port", "0"
        ]
        if let index = torrent.fileIndex {
            arguments += ["--file-index", String(index)]
        }
        task.arguments = arguments
        // The helper is ESM and resolves `webtorrent` from the folder it lives in.
        task.currentDirectoryURL = helper.deletingLastPathComponent()

        let pipe = Pipe()
        task.standardOutput = pipe
        // Kept rather than discarded: when the helper dies, this file is the
        // only place that says why.
        task.standardError = Self.errorLogHandle() ?? FileHandle.nullDevice

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            DispatchQueue.main.async { self?.consume(data) }
        }

        task.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.handleExit() }
        }

        do {
            try task.run()
        } catch {
            phase = .failed("Akış motoru başlatılamadı.")
            return
        }
        process = task

        watchdog = Task { [weak self] in
            try? await Task.sleep(for: Self.firstByteTimeout)
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.failIfStalled() }
        }
    }

    /// Stops the helper but keeps the message on screen, so the row that failed
    /// can say why.
    @MainActor
    private func fail(_ message: String) {
        terminate()
        phase = .failed(message)
        Self.clearCache()
    }

    @MainActor
    private func failIfStalled() {
        guard !handedOver, isBusy, downloaded == 0 else { return }
        fail("Eş bulunamadı — bu sürümü paylaşan kimse yok gibi görünüyor. Başka bir kalite deneyin.")
    }

    /// Yardımcıyı bu nesneden koparır ve çalışan süreci geri verir; kapatma
    /// kararını çağıran verir (arka planda mı, beklenerek mi).
    @MainActor
    private func detachHelper() -> Process? {
        watchdog?.cancel()
        watchdog = nil
        let running = process
        if let running {
            (running.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
            running.terminationHandler = nil
        }
        process = nil
        streamURL = nil
        onReady = nil
        return running
    }

    /// Kills the helper without touching the visible state.
    ///
    /// Süreç arka planda kapatılır: ölmesini beklemek arayüzü dondurur, ama
    /// önbelleğin silinmesi o beklemenin bitmesine bağlıdır.
    @MainActor
    private func terminate() {
        guard let running = detachHelper() else { return }
        DispatchQueue.global(qos: .utility).async { Self.shutDown(running) }
    }

    /// Uygulama kapanırken kullanılır: süreç ölene ve önbellek silinene kadar
    /// bekler. Arka plana atılan bir temizlik, uygulama sonlandığı anda yarıda
    /// kalır ve klasör diskte kalırdı.
    @MainActor
    func stopAndWait() {
        let running = detachHelper()
        resetState()
        if let running {
            let done = DispatchSemaphore(value: 0)
            DispatchQueue.global(qos: .userInitiated).async {
                Self.shutDown(running) { done.signal() }
            }
            _ = done.wait(timeout: .now() + 6)
        }
        Self.clearCache()
    }

    /// Called when playback ends or the app quits.
    @MainActor
    func stop() {
        terminate()
        resetState()
        Self.clearCache()
    }

    @MainActor
    private func resetState() {
        stdoutBuffer = Data()
        handedOver = false
        isPlayable = false
        bufferProgress = 0
        activeHash = nil
        activeFileIndex = nil
        title = ""
        peers = 0
        speed = 0
        progress = 0
        downloaded = 0
        phase = .idle
    }

    // MARK: - Helper protocol

    /// The helper writes one JSON object per line.
    @MainActor
    private func consume(_ data: Data) {
        stdoutBuffer.append(data)
        while let newline = stdoutBuffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = stdoutBuffer[stdoutBuffer.startIndex..<newline]
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...newline)
            guard !line.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
            else { continue }
            handle(object)
        }
    }

    @MainActor
    private func handle(_ message: [String: Any]) {
        switch message["event"] as? String {
        case "ready":
            guard let string = message["url"] as? String, let url = URL(string: string) else { return }
            streamURL = url
            if let name = message["name"] as? String, !name.isEmpty, title.isEmpty { title = name }
            if phase == .connecting { phase = .buffering }
            handOverIfBuffered()

        case "playable":
            isPlayable = true
            bufferProgress = 1
            handOverIfBuffered()

        case "progress":
            peers = message["peers"] as? Int ?? peers
            speed = Int64(message["speed"] as? Double ?? Double(speed))
            progress = message["progress"] as? Double ?? progress
            downloaded = Int64(message["downloaded"] as? Double ?? Double(downloaded))
            bufferProgress = message["buffer"] as? Double ?? bufferProgress
            handOverIfBuffered()

        case "warn":
            // The helper survived a library error; nothing to show the user, but
            // it belongs in the log next to mpv's.
            NSLog("ZyPlayer torrent stream: %@", message["message"] as? String ?? "")

        case "error":
            fail(message["message"] as? String ?? "Torrent akışı başarısız.")

        default:
            break
        }
    }

    /// Hands the URL to the player once the helper says the head of the file is
    /// buffered. The helper decides, because only it knows which bytes arrived —
    /// a total byte count says nothing about whether the *first* pieces are in.
    @MainActor
    private func handOverIfBuffered() {
        guard !handedOver, isPlayable, let url = streamURL, let onReady else { return }
        handedOver = true
        phase = .streaming
        onReady(url, title)
    }

    @MainActor
    private func handleExit() {
        guard isBusy else { return }
        phase = .failed("Akış beklenmedik şekilde durdu.")
        process = nil
    }

    // MARK: - Display

    var statusLine: String {
        switch phase {
        case .idle: return ""
        case .failed(let message): return message
        case .connecting: return peers > 0 ? "\(peers) eşe bağlanıldı…" : "Eşler aranıyor…"
        case .buffering, .streaming:
            var parts = ["\(peers) eş"]
            if speed > 0 {
                let formatter = ByteCountFormatter()
                formatter.countStyle = .file
                parts.append("\(formatter.string(fromByteCount: speed))/sn")
            }
            if phase == .buffering {
                parts.append("tampon %\(Int(bufferProgress * 100))")
            }
            return parts.joined(separator: " · ")
        }
    }
}
