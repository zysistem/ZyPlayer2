import Foundation

/// Otomatik "Tanıtımı Geç" / "Sonraki Bölüm" düğmeleri için tespit edilen zaman
/// işaretleri. Hepsi saniye cinsinden ve isteğe bağlı — bilinmeyen alan `nil`
/// kalır, o düğme eski sezgisel kurala düşer.
///
/// Infuse'un yaptığı gibi burada da iki gerçek veri kaynağı var: dosyaya gömülü
/// bölüm (chapter) işaretleri (kesin) ve onlar yoksa ffmpeg ile sessizlik/siyah
/// kare analizi (yaklaşık). Sihir yok — sınır bir yerden okunur ya da hesaplanır.
struct SkipMarkers: Equatable, Codable {
    /// Tanıtımın (intro/jenerik başı/özet) başladığı an — yalnızca chapter
    /// kaynağından geliyor (chapter'ın kendi zaman damgası). `nil` iken düğme
    /// oynatmanın başından itibaren gösterilir; cold open (tanıtımdan önce
    /// oynayan bir sahne) varsa bu alan onu atlayıp doğru anda göstermeyi
    /// sağlar. ffmpeg analizi yalnızca bitişi (introEnd) hesaplıyor — başlangıcı
    /// değil, o yüzden analiz kaynaklı işaretlerde bu her zaman `nil`.
    var introStart: Double?
    /// Tanıtımın (intro/jenerik başı/özet) bittiği an. "Tanıtımı Geç" tam bu
    /// saniyeye atlar.
    var introEnd: Double?
    /// Kapanış jeneriğinin başladığı an. Bundan sonra "Sonraki Bölüm" belirir.
    var creditsStart: Double?
    /// İşaretler nereden geldi — kesin (chapter) mi, yaklaşık (analiz) mi.
    var source: Source = .none

    enum Source: String, Equatable, Codable { case none, chapters, analysis }

    var isEmpty: Bool { introEnd == nil && creditsStart == nil }
}

/// Chapter işaretlerini sınıflandırır ve gerektiğinde ffmpeg taramasıyla kendi
/// işaretlerini üretir. Tüm işlem senkron ve saf — çağıran taraf arka plana atar.
enum IntroSkipDetector {

    // MARK: - Chapter'lardan (kesin)

    /// Baştaki tanıtım/özet chapter'larını tanıyan kelimeler (küçük harf).
    private static let introWords = [
        "intro", "opening", "op credits", "opening credits", "title sequence",
        "titles", "recap", "previously", "cold open", "teaser",
        "jenerik", "açılış", "giriş", "tanıtım", "özet", "önceki bölüm"
    ]
    /// Kapanış jeneriği chapter'larını tanıyan kelimeler (küçük harf).
    private static let creditsWords = [
        "credit", "credits", "end credits", "ending", "outro", "closing",
        "kapanış", "son jenerik", "bitiş", "jenerik son"
    ]

    /// Dosyaya gömülü chapter'lardan intro/jenerik sınırlarını çıkarır. Chapter
    /// bitişi = bir sonraki chapter'ın başı olduğundan atlama noktası tam saniyeye
    /// oturur. Chapter yoksa boş döner.
    static func fromChapters(_ chapters: [(title: String, time: Double)],
                             duration: Double) -> SkipMarkers {
        guard duration > 0, chapters.count >= 2 else { return SkipMarkers() }
        var markers = SkipMarkers()
        let sorted = chapters.sorted { $0.time < $1.time }
        for (i, ch) in sorted.enumerated() {
            let title = ch.title.lowercased()
            guard !title.isEmpty else { continue }
            let end = i + 1 < sorted.count ? sorted[i + 1].time : duration
            // İlk yarıdaki intro/özet chapter'ı → tanıtım başı (en erken olanı,
            // ardışık birden çok intro chapter'ı olabilir — "Recap" + "Opening"
            // gibi) ve tanıtım sonu (en geç olanı). Başlangıcın kendisi
            // saklanması sayede kendinden önceki adsız/"Cold Open" bir
            // chapter'ı (introWords'te değil) yanlışlıkla tanıtım sayıp erken
            // göstermiyoruz — düğme yalnızca gerçek tanıtım chapter'ı
            // başladığında beliriyor.
            if ch.time < duration * 0.5, introWords.contains(where: title.contains) {
                markers.introStart = min(markers.introStart ?? .infinity, ch.time)
                markers.introEnd = max(markers.introEnd ?? 0, end)
                markers.source = .chapters
            }
            // Son %40'ta başlayan jenerik chapter'ı → jenerik başı (en erken olanı).
            if ch.time > duration * 0.6, creditsWords.contains(where: title.contains) {
                markers.creditsStart = min(markers.creditsStart ?? .infinity, ch.time)
                markers.source = .chapters
            }
        }
        if markers.creditsStart == .infinity { markers.creditsStart = nil }
        if markers.introStart == .infinity { markers.introStart = nil }
        return markers
    }

    // MARK: - ffmpeg analizi (yaklaşık)

    /// ffmpeg ikili dosyasının yolu; yoksa analiz atlanır.
    static let ffmpegPath: String? = {
        ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    /// Sessizlik + siyah kare geçişlerinden tanıtım sonu ve jenerik başını tahmin
    /// eder. `needIntro`/`needCredits` chapter'ın zaten verdiği alanı atlamak için.
    /// **Senkron ve yavaş** (ffmpeg çözümlemesi) — mutlaka arka planda çağır.
    static func analyze(url: URL, headers: [String: String], duration: Double,
                        ffmpegPath: String, needIntro: Bool, needCredits: Bool) -> SkipMarkers {
        var markers = SkipMarkers()
        if needIntro, let end = scanIntro(url: url, headers: headers, ffmpegPath: ffmpegPath) {
            markers.introEnd = end
            markers.source = .analysis
        }
        if needCredits, duration > 300,
           let start = scanCredits(url: url, headers: headers, duration: duration,
                                   ffmpegPath: ffmpegPath) {
            markers.creditsStart = start
            markers.source = .analysis
        }
        return markers
    }

    /// Baştaki ~170 sn'de siyah kareyle sessizliğin çakıştığı en geç geçişi tanıtım
    /// sonu sayar. Kararsızsa `nil` döner — kör bir atlama yerine sezgiyi bırakırız.
    private static func scanIntro(url: URL, headers: [String: String],
                                  ffmpegPath: String) -> Double? {
        let target = url.isFileURL ? url.path : url.absoluteString
        var args = ["-hide_banner", "-nostats"]
        args += headerArgs(headers)
        args += ["-t", "170", "-i", target,
                 "-vf", "blackdetect=d=0.05:pic_th=0.85:pix_th=0.10",
                 "-af", "silencedetect=n=-30dB:d=0.4",
                 "-f", "null", "-"]
        let log = runFFmpeg(ffmpegPath, args, timeout: 90)
        let blackEnds = parseBlack(log).map(\.end).filter { $0 >= 15 && $0 <= 155 }
        guard !blackEnds.isEmpty else { return nil }
        let silences = parseSilence(log)
        func nearSilence(_ t: Double) -> Bool {
            silences.contains { abs(($0.end ?? $0.start) - t) < 2.5 }
        }
        // Sessizlikle çakışan en geç siyah-kare bitişi; hiçbiri çakışmıyorsa
        // tahmin etmeyiz (yanlış yere atlamaktansa sezgiye düşmek yeğdir).
        return blackEnds.filter(nearSilence).max()
    }

    /// Sondaki ~240 sn'de, kalan sürenin %25'inden azını bırakan ve sessizlikle
    /// birlikte gelen ilk siyah geçişi jenerik başı sayar. `-ss` girişten önce
    /// verildiğinden filtre zaman damgaları taranan parçanın başına göredir; bu
    /// yüzden `ss` geri eklenir.
    private static func scanCredits(url: URL, headers: [String: String],
                                    duration: Double, ffmpegPath: String) -> Double? {
        let target = url.isFileURL ? url.path : url.absoluteString
        let tail = min(240.0, duration * 0.5)
        let ss = duration - tail
        var args = ["-hide_banner", "-nostats", "-ss", String(Int(ss))]
        args += headerArgs(headers)
        args += ["-t", String(Int(tail)), "-i", target,
                 "-vf", "blackdetect=d=0.08:pic_th=0.90:pix_th=0.10",
                 "-af", "silencedetect=n=-30dB:d=0.4",
                 "-f", "null", "-"]
        let log = runFFmpeg(ffmpegPath, args, timeout: 120)
        let blackStarts = parseBlack(log).map { ss + $0.start }
        let silences = parseSilence(log).map { ss + $0.start }
        // Jenerik, kalan sürenin son çeyreğinde başlar; müzik/konuşma değiştiği için
        // yakınında bir sessizlik sınırı olur. Bu koşulu sağlayan en erken siyahı al.
        let threshold = duration * 0.75
        let candidates = blackStarts
            .filter { $0 >= threshold && $0 < duration - 10 }
            .filter { s in silences.contains { abs($0 - s) < 4 } }
        return candidates.min()
    }

    // MARK: - ffmpeg süreç yardımcıları

    /// User-Agent ve öbür başlıkları ffmpeg argümanlarına çevirir. Başlıklar `-i`
    /// ÖNCESİNDE verilmeli; CDN'ler Referer/UA olmadan 403 döndürür.
    private static func headerArgs(_ headers: [String: String]) -> [String] {
        var args: [String] = []
        var remaining = headers
        if let ua = remaining.removeValue(forKey: "User-Agent"), !ua.isEmpty {
            args += ["-user_agent", ua]
        }
        let lines = remaining
            .filter { !$0.value.isEmpty }
            .map { "\($0.key): \($0.value)" }
            .joined(separator: "\r\n")
        if !lines.isEmpty { args += ["-headers", lines + "\r\n"] }
        return args
    }

    /// ffmpeg'i çalıştırıp stderr çıktısını döndürür (tespit logları stderr'e
    /// yazılır). `timeout` saniyesinde takılırsa süreç sonlandırılır.
    private static func runFFmpeg(_ ffmpegPath: String, _ args: [String],
                                  timeout: TimeInterval) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        process.arguments = args
        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = FileHandle.nullDevice
        do { try process.run() } catch { return "" }

        // Uzak akış takılırsa süreci gözcüyle kes.
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)

        let data = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// `black_start:… black_end:…` satırlarını ayrıştırır.
    private static func parseBlack(_ log: String) -> [(start: Double, end: Double)] {
        var result: [(Double, Double)] = []
        for line in log.components(separatedBy: .newlines) where line.contains("black_start") {
            guard let start = value(after: "black_start:", in: line),
                  let end = value(after: "black_end:", in: line) else { continue }
            result.append((start, end))
        }
        return result
    }

    /// `silence_start:` ve `silence_end:` satırlarını ayrıştırır (bitiş olmayabilir).
    private static func parseSilence(_ log: String) -> [(start: Double, end: Double?)] {
        var result: [(Double, Double?)] = []
        for line in log.components(separatedBy: .newlines) {
            if let start = value(after: "silence_start:", in: line) {
                result.append((start, nil))
            } else if let end = value(after: "silence_end:", in: line) {
                result.append((end, end))
            }
        }
        return result
    }

    /// Bir etiketten sonraki ilk ondalık sayıyı okur ("… silence_end: 12.34 |…").
    private static func value(after label: String, in line: String) -> Double? {
        guard let range = line.range(of: label) else { return nil }
        let rest = line[range.upperBound...].drop { $0 == " " }
        let token = rest.prefix { $0.isNumber || $0 == "." || $0 == "-" }
        return Double(token)
    }
}
