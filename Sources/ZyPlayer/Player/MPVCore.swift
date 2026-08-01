import Foundation
import Cmpv

/// Thin, Swift-friendly wrapper around a libmpv handle.
///
/// The video is not drawn by mpv into its own window; `MPVLayer` owns an
/// `mpv_render_context` and draws frames into a `CAOpenGLLayer`. That keeps the
/// picture inside our SwiftUI hierarchy so controls can be composed on top of it.
final class MPVCore {

    enum Event {
        case fileLoaded
        case endFile
        case propertyChanged(name: String)
        case shutdown
    }

    private(set) var handle: OpaquePointer?
    private let eventQueue = DispatchQueue(label: "com.zyplayer.mpv.events")
    private var eventHandler: ((Event) -> Void)?

    // Properties we keep mirrored on the main thread for the UI to read.
    private(set) var duration: Double = 0
    private(set) var position: Double = 0
    private(set) var isPaused: Bool = true
    private(set) var volume: Double = 100
    private(set) var speed: Double = 1.0

    // MARK: - Lifecycle

    init() {
        handle = mpv_create()
    }

    /// Applies startup options and initialises the handle. Must run before any
    /// playback command; options like `vo` cannot change afterwards.
    func start(logFile: URL? = nil) {
        guard let handle else { return }

        // `vo=libmpv` is the render-API video output: mpv hands us frames instead
        // of creating a window of its own.
        setOption("vo", "libmpv")
        setOption("hwdec", "videotoolbox")
        setOption("keep-open", "yes")
        setOption("osc", "no")
        setOption("osd-level", "0")
        setOption("input-default-bindings", "no")
        setOption("input-vo-keyboard", "no")
        // Dual-audio releases are the norm on the Turkish streaming sites: pick the
        // Turkish dub when the file carries one, otherwise mpv falls through to the
        // file's own default track. Every spelling shows up in the wild, and an
        // explicit `aid` chosen later still overrides this.
        setOption("alang", "tur,tr,turkish,türkçe")
        // Trailers are YouTube URLs, resolved by mpv's ytdl hook. Give it an
        // absolute path: a bundled .app does not inherit the shell's PATH.
        setOption("ytdl", "yes")
        setOption("ytdl-format", "bestvideo[height<=?1080]+bestaudio/best")
        for candidate in ["/opt/homebrew/bin/yt-dlp", "/usr/local/bin/yt-dlp"]
        where FileManager.default.isExecutableFile(atPath: candidate) {
            setOption("script-opts", "ytdl_hook-ytdl_path=\(candidate)")
            break
        }
        // Generous cache so network and cloud sources survive stalls.
        setOption("cache", "yes")
        setOption("demuxer-max-bytes", "150MiB")
        setOption("demuxer-readahead-secs", "20")

        if let logFile {
            setOption("log-file", logFile.path)
            setOption("msg-level", "all=v")
        }

        mpv_initialize(handle)

        for name in ["duration", "time-pos", "pause", "volume", "speed", "eof-reached"] {
            mpv_observe_property(handle, 0, name, MPV_FORMAT_DOUBLE)
        }
        // Booleans need their own format.
        mpv_observe_property(handle, 0, "pause", MPV_FORMAT_FLAG)
        mpv_observe_property(handle, 0, "eof-reached", MPV_FORMAT_FLAG)

        startEventLoop()
    }

    func onEvent(_ handler: @escaping (Event) -> Void) {
        eventHandler = handler
    }

    func shutdown() {
        guard let handle else { return }
        self.handle = nil
        mpv_terminate_destroy(handle)
    }

    private let mpvQueue = DispatchQueue(label: "com.zyplayer.mpv.commandQueue", qos: .userInitiated)

    // MARK: - Options & properties

    func setOption(_ name: String, _ value: String) {
        guard let handle else { return }
        mpv_set_option_string(handle, name, value)
    }

    func setProperty(_ name: String, _ value: String) {
        guard let handle else { return }
        mpvQueue.async { [weak self] in
            guard let self, self.handle == handle else { return }
            mpv_set_property_string(handle, name, value)
        }
    }

    func setProperty(_ name: String, _ value: Double) {
        guard let handle else { return }
        mpvQueue.async { [weak self] in
            guard let self, self.handle == handle else { return }
            var v = value
            mpv_set_property(handle, name, MPV_FORMAT_DOUBLE, &v)
        }
    }

    func setProperty(_ name: String, _ value: Bool) {
        guard let handle else { return }
        mpvQueue.async { [weak self] in
            guard let self, self.handle == handle else { return }
            var v: Int32 = value ? 1 : 0
            mpv_set_property(handle, name, MPV_FORMAT_FLAG, &v)
        }
    }

    func doubleProperty(_ name: String) -> Double? {
        guard let handle else { return nil }
        var v: Double = 0
        return mpv_get_property(handle, name, MPV_FORMAT_DOUBLE, &v) >= 0 ? v : nil
    }

    func stringProperty(_ name: String) -> String? {
        guard let handle, let raw = mpv_get_property_string(handle, name) else { return nil }
        defer { mpv_free(raw) }
        return String(cString: raw)
    }

    // MARK: - Commands

    /// Sends a command as an argv-style array, keeping every C string alive for
    /// the duration of the call.
    func command(_ args: [String]) {
        guard let handle else { return }
        mpvQueue.async { [weak self] in
            guard let self, self.handle == handle else { return }
            let owned: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) }
            defer { owned.forEach { if let p = $0 { free(p) } } }

            var argv: [UnsafePointer<CChar>?] = owned.map { $0.map { UnsafePointer($0) } }
            argv.append(nil)
            argv.withUnsafeMutableBufferPointer { buffer in
                _ = mpv_command(handle, buffer.baseAddress)
            }
        }
    }

    /// Sets HTTP headers for the next network stream — Google Drive serves media
    /// only with a bearer token, and streaming-site CDNs check `Referer` and a
    /// browser `User-Agent`.
    ///
    /// `User-Agent` and `Referer` go through their own mpv options rather than
    /// `http-header-fields`: that property is a *comma-separated* list, and a
    /// Safari UA ("(KHTML, like Gecko)") would be split at its comma and sent as
    /// two broken fields. Both options are always written — cleared when absent —
    /// so a stream's headers never leak into the next, plainer file.
    func setHTTPHeaders(_ headers: [String: String]) {
        var remaining = headers
        setProperty("user-agent", remaining.removeValue(forKey: "User-Agent") ?? "")
        let referer = remaining.removeValue(forKey: "Referer")
            ?? remaining.removeValue(forKey: "Referrer") ?? ""
        setProperty("referrer", referer)

        guard !remaining.isEmpty else {
            setProperty("http-header-fields", "")
            return
        }
        let joined = remaining.map { "\($0.key): \($0.value)" }.joined(separator: ",")
        setProperty("http-header-fields", joined)
    }

    func loadFile(_ url: URL, startAt seconds: Double? = nil, options: [String: String] = [:]) {
        let target = url.isFileURL ? url.path : url.absoluteString
        var perFile = options
        if let seconds { perFile["start"] = String(Int(seconds)) }

        guard !perFile.isEmpty else {
            command(["loadfile", target])
            return
        }
        // Since mpv 0.38 the signature is
        // `loadfile <url> [<flags> [<index> [<options>]]]`, so the per-file
        // options go in the *fourth* slot. Passing them third makes mpv reject
        // the whole command with MPV_ERROR_INVALID_PARAMETER and nothing loads
        // at all.
        let joined = perFile.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ",")
        command(["loadfile", target, "replace", "0", joined])
    }

    func play() { setProperty("pause", false) }
    func pause() { setProperty("pause", true) }
    func togglePause() { command(["cycle", "pause"]) }

    /// `exact` decodes up to the requested frame; the keyframe form only jumps to
    /// the nearest index entry, which is an order of magnitude cheaper and is what
    /// a live scrubber drag wants.
    func seek(to seconds: Double, exact: Bool = true) {
        command(["seek", String(seconds), exact ? "absolute+exact" : "absolute+keyframes"])
    }

    func seek(by seconds: Double) {
        command(["seek", String(seconds), "relative"])
    }

    func setVolume(_ value: Double) {
        setProperty("volume", max(0, min(150, value)))
    }

    func setSpeed(_ value: Double) {
        setProperty("speed", max(0.25, min(4.0, value)))
    }

    // MARK: - Tracks

    /// mpv renders `track-list` as JSON when read as a string.
    func trackList() -> [MediaTrack] {
        guard let json = stringProperty("track-list"),
              let data = json.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return raw.compactMap(MediaTrack.init(mpvEntry:))
    }

    func selectAudioTrack(id: Int?) {
        setProperty("aid", id.map(String.init) ?? "no")
    }

    func selectSubtitleTrack(id: Int?) {
        setProperty("sid", id.map(String.init) ?? "no")
    }

    /// Loads an external subtitle file and selects it.
    /// Dış altyazı dosyasını yükler ve seçer. Başlık verildiğinde iz menüde o
    /// adla görünür — çeviriler "Parça 3" diye çıkmasın diye.
    func addSubtitleFile(_ url: URL, title: String? = nil, lang: String? = nil) {
        if let title {
            command(["sub-add", url.path, "select", title, lang ?? ""])
        } else {
            command(["sub-add", url.path, "select"])
        }
    }

    /// Dosyası yerinde değişen bir dış altyazıyı yeniden okutur. Çeviri
    /// ilerledikçe aynı dosyaya yazıp bunu çağırıyoruz: yeni bir parça çevrildikçe
    /// altyazı oynatma sırasında güncelleniyor, yeni bir iz açılmıyor.
    func reloadSubtitle(id: Int) {
        command(["sub-reload", String(id)])
    }

    /// Pushes the whole subtitle style; safe to call while playing.
    func applySubtitleStyle(_ style: SubtitleStyle) {
        for (name, value) in style.mpvProperties {
            setProperty(name, value)
        }
    }

    // MARK: - Event loop

    private func startEventLoop() {
        eventQueue.async { [weak self] in
            while let self, let handle = self.handle {
                guard let raw = mpv_wait_event(handle, 0.05) else { continue }
                let event = raw.pointee
                switch event.event_id {
                case MPV_EVENT_SHUTDOWN:
                    self.emit(.shutdown)
                    return
                case MPV_EVENT_FILE_LOADED:
                    self.refreshMirroredProperties()
                    self.emit(.fileLoaded)
                case MPV_EVENT_END_FILE:
                    self.emit(.endFile)
                case MPV_EVENT_PROPERTY_CHANGE:
                    if let prop = UnsafeMutablePointer<mpv_event_property>(OpaquePointer(event.data)) {
                        let name = String(cString: prop.pointee.name)
                        self.apply(name: name, property: prop.pointee)
                        self.emit(.propertyChanged(name: name))
                    }
                default:
                    break
                }
            }
        }
    }

    private func apply(name: String, property: mpv_event_property) {
        switch (name, property.format) {
        case ("duration", MPV_FORMAT_DOUBLE):
            if let v = property.data?.assumingMemoryBound(to: Double.self).pointee { duration = v }
        case ("time-pos", MPV_FORMAT_DOUBLE):
            if let v = property.data?.assumingMemoryBound(to: Double.self).pointee { position = v }
        case ("volume", MPV_FORMAT_DOUBLE):
            if let v = property.data?.assumingMemoryBound(to: Double.self).pointee { volume = v }
        case ("speed", MPV_FORMAT_DOUBLE):
            if let v = property.data?.assumingMemoryBound(to: Double.self).pointee { speed = v }
        case ("pause", MPV_FORMAT_FLAG):
            if let v = property.data?.assumingMemoryBound(to: Int32.self).pointee { isPaused = v != 0 }
        default:
            break
        }
    }

    private func refreshMirroredProperties() {
        duration = doubleProperty("duration") ?? duration
        position = doubleProperty("time-pos") ?? 0
        volume = doubleProperty("volume") ?? volume
        speed = doubleProperty("speed") ?? speed
    }

    private func emit(_ event: Event) {
        guard let eventHandler else { return }
        DispatchQueue.main.async { eventHandler(event) }
    }
}
