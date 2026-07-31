import Foundation

/// One download tracked by aria2.
struct TorrentDownload: Identifiable, Hashable {
    var id: String                 // aria2 GID
    var name: String
    var status: String             // active, waiting, paused, error, complete, removed
    var completedLength: Int64
    var totalLength: Int64
    var downloadSpeed: Int64
    var connections: Int
    var seeders: Int
    var filePaths: [String]
    var errorMessage: String?
    /// Set on a magnet's metadata entry once the real torrent starts.
    var followedBy: [String]

    var progress: Double {
        guard totalLength > 0 else { return 0 }
        return min(Double(completedLength) / Double(totalLength), 1)
    }

    var isFinished: Bool { status == "complete" }
    var isActive: Bool { status == "active" }

    /// "1,2 GB / 4,7 GB" style.
    var sizeLine: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        guard totalLength > 0 else { return formatter.string(fromByteCount: completedLength) }
        return "\(formatter.string(fromByteCount: completedLength)) / \(formatter.string(fromByteCount: totalLength))"
    }

    var speedLine: String {
        guard downloadSpeed > 0 else { return "" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return "\(formatter.string(fromByteCount: downloadSpeed))/sn"
    }

    /// Rough time remaining; nil when it cannot be estimated.
    var etaLine: String? {
        guard downloadSpeed > 1000, totalLength > completedLength else { return nil }
        let seconds = Double(totalLength - completedLength) / Double(downloadSpeed)
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter.string(from: seconds)
    }
}

/// Drives an `aria2c` process over JSON-RPC.
///
/// aria2 rather than libtorrent: the requirement is download-then-watch, with no
/// piece-level control or streaming-while-downloading, so a battle-tested single
/// binary beats writing a C++ bridge.
actor TorrentEngine {

    enum EngineError: LocalizedError {
        case binaryMissing
        case startFailed
        case rpc(String)

        var errorDescription: String? {
            switch self {
            case .binaryMissing:
                "aria2c bulunamadı. `brew install aria2` ile kurun."
            case .startFailed:
                "İndirme motoru başlatılamadı."
            case .rpc(let message):
                message
            }
        }
    }

    private var process: Process?
    private var port: UInt16 = 0
    private var secret = ""
    private let session = URLSession(configuration: .ephemeral)

    var isRunning: Bool { process?.isRunning == true }

    /// Prefers a copy bundled in the .app, falls back to Homebrew for development.
    private static var binaryURL: URL? {
        if let bundled = Bundle.main.url(forResource: "aria2c", withExtension: nil),
           FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled
        }
        for path in ["/opt/homebrew/bin/aria2c", "/usr/local/bin/aria2c", "/usr/bin/aria2c"] {
            if FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    static var isInstalled: Bool { binaryURL != nil }

    // MARK: - Lifecycle

    func start(downloadDirectory: String) async throws {
        if isRunning { return }
        guard let binary = Self.binaryURL else { throw EngineError.binaryMissing }

        port = try Self.freePort()
        secret = UUID().uuidString

        let sessionFile = AppPaths.file("aria2.session").path
        if !FileManager.default.fileExists(atPath: sessionFile) {
            FileManager.default.createFile(atPath: sessionFile, contents: nil)
        }

        let task = Process()
        task.executableURL = binary
        task.arguments = [
            "--enable-rpc",
            "--rpc-listen-port=\(port)",
            "--rpc-secret=\(secret)",
            // Bind to loopback only: this RPC controls the filesystem.
            "--rpc-listen-all=false",
            "--dir=\(downloadDirectory)",
            "--continue=true",
            "--max-concurrent-downloads=3",
            "--seed-time=0",              // download-then-watch: do not seed
            "--bt-save-metadata=true",
            "--save-session=\(sessionFile)",
            "--input-file=\(sessionFile)",
            "--save-session-interval=30",
            "--auto-save-interval=30",
            "--summary-interval=0",
            "--console-log-level=warn"
        ]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
        } catch {
            throw EngineError.startFailed
        }
        process = task

        // Wait for the RPC endpoint to answer before returning.
        for _ in 0..<40 {
            try? await Task.sleep(for: .milliseconds(100))
            if (try? await call("aria2.getVersion", params: [])) != nil { return }
        }
        throw EngineError.startFailed
    }

    func stop() {
        process?.terminate()
        process = nil
    }

    func setDownloadDirectory(_ path: String) async {
        _ = try? await call("aria2.changeGlobalOption", params: [["dir": path]])
    }

    // MARK: - Commands

    @discardableResult
    func addMagnet(_ uri: String) async throws -> String {
        let result = try await call("aria2.addUri", params: [[uri]])
        return result as? String ?? ""
    }

    @discardableResult
    func addTorrentFile(_ url: URL) async throws -> String {
        let data = try Data(contentsOf: url)
        let result = try await call("aria2.addTorrent", params: [data.base64EncodedString()])
        return result as? String ?? ""
    }

    func pause(_ gid: String) async {
        _ = try? await call("aria2.pause", params: [gid])
    }

    func resume(_ gid: String) async {
        _ = try? await call("aria2.unpause", params: [gid])
    }

    /// Removes the download; `deleteFiles` also clears partial data.
    func remove(_ gid: String, deleteFiles: Bool, filePaths: [String]) async {
        _ = try? await call("aria2.forceRemove", params: [gid])
        _ = try? await call("aria2.removeDownloadResult", params: [gid])
        guard deleteFiles else { return }
        for path in filePaths {
            try? FileManager.default.removeItem(atPath: path)
            try? FileManager.default.removeItem(atPath: path + ".aria2")
        }
    }

    /// Active, waiting and finished downloads in one list.
    func allDownloads() async -> [TorrentDownload] {
        let keys = [
            "gid", "status", "completedLength", "totalLength", "downloadSpeed",
            "connections", "numSeeders", "errorMessage", "files", "bittorrent", "followedBy"
        ]
        var collected: [TorrentDownload] = []

        if let active = try? await call("aria2.tellActive", params: [keys]) as? [[String: Any]] {
            collected += active.compactMap(Self.parse)
        }
        if let waiting = try? await call("aria2.tellWaiting", params: [0, 50, keys]) as? [[String: Any]] {
            collected += waiting.compactMap(Self.parse)
        }
        if let stopped = try? await call("aria2.tellStopped", params: [0, 50, keys]) as? [[String: Any]] {
            collected += stopped.compactMap(Self.parse)
        }

        // A magnet first downloads metadata, then spawns the real transfer.
        // Hide the metadata rows so the list shows one entry per torrent.
        let superseded = Set(collected.flatMap(\.followedBy))
        return collected.filter { !superseded.contains($0.id) }
    }

    private static func parse(_ raw: [String: Any]) -> TorrentDownload? {
        guard let gid = raw["gid"] as? String else { return nil }

        let files = (raw["files"] as? [[String: Any]]) ?? []
        let paths = files.compactMap { $0["path"] as? String }.filter { !$0.isEmpty }

        let bittorrent = raw["bittorrent"] as? [String: Any]
        let info = bittorrent?["info"] as? [String: Any]
        let name = (info?["name"] as? String)
            ?? paths.first.map { URL(fileURLWithPath: $0).lastPathComponent }
            ?? "Meta veri alınıyor…"

        return TorrentDownload(
            id: gid,
            name: name,
            status: raw["status"] as? String ?? "unknown",
            completedLength: Int64(raw["completedLength"] as? String ?? "0") ?? 0,
            totalLength: Int64(raw["totalLength"] as? String ?? "0") ?? 0,
            downloadSpeed: Int64(raw["downloadSpeed"] as? String ?? "0") ?? 0,
            connections: Int(raw["connections"] as? String ?? "0") ?? 0,
            seeders: Int(raw["numSeeders"] as? String ?? "0") ?? 0,
            filePaths: paths,
            errorMessage: raw["errorMessage"] as? String,
            followedBy: raw["followedBy"] as? [String] ?? []
        )
    }

    // MARK: - JSON-RPC

    @discardableResult
    private func call(_ method: String, params: [Any]) async throws -> Any? {
        guard port != 0 else { throw EngineError.startFailed }

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/jsonrpc")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": UUID().uuidString,
            "method": method,
            "params": ["token:\(secret)"] + params
        ])

        let (data, _) = try await session.data(for: request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        if let error = json?["error"] as? [String: Any],
           let message = error["message"] as? String {
            throw EngineError.rpc(message)
        }
        return json?["result"]
    }

    /// Asks the OS for a free TCP port by binding and immediately releasing it.
    private static func freePort() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw EngineError.startFailed }
        defer { close(fd) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { throw EngineError.startFailed }

        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &assigned) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        return UInt16(bigEndian: assigned.sin_port)
    }
}
