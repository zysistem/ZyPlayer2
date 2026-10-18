import Foundation

/// Oynatma takılmalarının teşhis kaydı:
/// `~/Library/Application Support/ZyPlayer/playback-diag.log`.
///
/// Sessizdir — yalnızca bir şey ters gittiğinde satır yazar: mpv'nin kare
/// sayaçları (düşen / geciken / zamanlaması kaçan kare) arttığında, bir kare
/// çizimi uzun sürdüğünde, ana iş parçacığı yanıt vermediğinde ve Drive
/// senkronu çalıştığında. Takılma anında hangisinin olduğu saat damgalarından
/// okunur. Dosya her açılışta sıfırlanır.
enum PlaybackDiagnostics {
    static let fileURL = AppPaths.file("playback-diag.log")

    private static let queue = DispatchQueue(label: "com.zyplayer.diagnostics", qos: .utility)
    private static var handle: FileHandle?
    private static var started = false

    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    /// Açılışta bir kez (ana iş parçacığında) çağrılır.
    static func start() {
        guard !started else { return }
        started = true
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        queue.async {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            handle = try? FileHandle(forWritingTo: fileURL)
        }
        log("ZyPlayer \(version) açıldı")
        startMainThreadWatchdog()
    }

    /// Herhangi bir iş parçacığından çağrılabilir.
    static func log(_ message: String) {
        let now = Date()
        queue.async {
            let line = "\(stampFormatter.string(from: now)) \(message)\n"
            handle?.write(Data(line.utf8))
        }
    }

    static func milliseconds(since start: DispatchTime) -> Int {
        Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
    }

    /// Ana iş parçacığına 100 ms'de bir boş bir iş gönderir; 100 ms içinde
    /// işlenmezse ana iş parçacığının ne kadar takıldığını yazar.
    private static func startMainThreadWatchdog() {
        let thread = Thread {
            while true {
                let sent = DispatchTime.now()
                let answered = DispatchSemaphore(value: 0)
                DispatchQueue.main.async { answered.signal() }
                if answered.wait(timeout: .now() + 0.1) == .timedOut {
                    answered.wait()
                    log("ANA İŞ PARÇACIĞI \(milliseconds(since: sent)) ms yanıt vermedi")
                }
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        thread.name = "com.zyplayer.diagnostics.watchdog"
        thread.qualityOfService = .utility
        thread.start()
    }
}
