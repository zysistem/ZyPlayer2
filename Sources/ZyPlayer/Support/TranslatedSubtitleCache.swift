import CryptoKit
import Foundation

/// Çevrilmiş altyazıları diskte saklar: aynı içerik aynı motorla ikinci kez
/// açıldığında çeviri yeniden yapılmaz.
///
/// Anahtar, kaynak altyazının **içeriğinden** üretiliyor; dosya adından ya da
/// yolundan değil. Böylece aynı altyazı geçici bir klasöre yeniden indirilse
/// ya da gömülü akıştan tekrar çıkartılsa bile önbellek tutuyor.
enum TranslatedSubtitleCache {

    /// `~/Library/Application Support/ZyPlayer/TranslatedSubtitles`
    static let directory: URL = {
        let dir = AppPaths.supportDirectory
            .appendingPathComponent("TranslatedSubtitles", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Çeviri biçimi değişirse eski önbellek kendiliğinden geçersiz olsun diye.
    /// v1 → v2 (2026-08-28): `LLMTranslator.systemPrompt`/`userPrompt` sinema
    /// bağlamı/tutarlılık vurgusuyla yeniden yazıldı. Eski sürümle çevrilmiş
    /// dosyalar diskte kalıyor ama artık hiçbir anahtar onlara denk gelmiyor,
    /// bu yüzden "aynı altyazıyı aynı motorla yeniden çevir" isteği eski,
    /// düşük kaliteli çıktıyı sessizce geri getirmek yerine gerçekten yeniden
    /// çeviriyor.
    private static let formatVersion = "v2"

    /// Anahtar **yalnızca kaynak altyazının içeriğinden** üretiliyor. Motor adı
    /// dosya adına ayrı bir ek olarak yazılıyor, anahtarın içine karışmıyor:
    /// bir içeriği Google ile çevirip sonra ayarlardan Z.ai'ye geçen kullanıcı,
    /// aynı altyazıyı yeniden açtığında eski çevirisini bulabilsin diye.
    static func key(source: String) -> String {
        let digest = SHA256.hash(data: Data("\(formatVersion)|\(source)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func url(for key: String, engine: TranslationEngine) -> URL {
        directory.appendingPathComponent("\(key)-\(engine.rawValue).vtt")
    }

    struct Hit {
        var url: URL
        /// Çeviriyi hangi motorun yaptığı; kullanıcıya bildirmek için.
        var engine: TranslationEngine?

        var engineName: String { engine?.title ?? "kayıtlı çeviri" }
    }

    /// Bu içeriğin daha önce çevrilmiş hâlini arar.
    ///
    /// `exact: true` yalnızca istenen motorun kendi dosyasına bakar — kullanıcı
    /// menüden bir motor seçtiğinde başka bir motorun eski çevirisiyle sessizce
    /// değiştirilmemesi için. `exact: false` (dosya kapat-aç sırasındaki sessiz
    /// geri yükleme) hangi motorla çevrilmişse onu kabul eder; kaynak altyazı
    /// zaten elde yoksa herhangi bir çeviri hiç olmamasından iyidir.
    static func cached(key: String, preferring engine: TranslationEngine, exact: Bool = false) -> Hit? {
        let exactURL = url(for: key, engine: engine)
        if FileManager.default.fileExists(atPath: exactURL.path) {
            touch(exactURL)
            return Hit(url: exactURL, engine: engine)
        }
        guard !exact else { return nil }

        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let matches = files.filter {
            $0.pathExtension == "vtt" && $0.lastPathComponent.hasPrefix("\(key)-")
        }
        // Birden çok motorla çevrilmişse en son kullanılan gelsin.
        let newest = matches.max {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a < b
        }
        guard let newest else { return nil }
        touch(newest)
        let suffix = newest.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "\(key)-", with: "")
        return Hit(url: newest, engine: TranslationEngine(rawValue: suffix))
    }

    private static func touch(_ url: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    @discardableResult
    static func store(_ webVTT: String, key: String, engine: TranslationEngine) -> URL? {
        let url = url(for: key, engine: engine)
        do {
            try webVTT.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    // MARK: - Videoya göre kayıt

    /// Bir videonun çevrilmiş altyazısı.
    struct Entry: Codable {
        var file: String
        var engine: String
        /// Kaynak altyazının adı ("İngilizce · SRT") — kullanıcıya bildirmek için.
        var label: String
        var date: Date

        init(file: String, engine: String, label: String, date: Date) {
            self.file = file
            self.engine = engine
            self.label = label
            self.date = date
        }

        // Alan eklendiğinde eski kayıtlar okunmaya devam etsin diye hoşgörülü.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            file = (try? c.decode(String.self, forKey: .file)) ?? ""
            engine = (try? c.decode(String.self, forKey: .engine)) ?? ""
            label = (try? c.decode(String.self, forKey: .label)) ?? "altyazı"
            date = (try? c.decode(Date.self, forKey: .date)) ?? .distantPast
        }
    }

    /// Video kimliği → o video için yapılmış çeviriler.
    ///
    /// İçerik özeti tek başına yetmiyor: kullanıcı filmi kapatıp yeniden
    /// açtığında elle eklediği `.srt` artık ekli olmuyor, dolayısıyla
    /// özetlenecek bir kaynak da kalmıyor. Videonun kendi kimliğiyle tutulan bu
    /// dizin sayesinde çeviri, kaynak altyazı ortada olmasa da geri geliyor.
    private struct Index: Codable {
        var videos: [String: [Entry]] = [:]

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            videos = (try? c.decode([String: [Entry]].self, forKey: .videos)) ?? [:]
        }
    }

    private static let index = LocalStore(fileName: "translated-subtitles.json",
                                          defaultValue: Index())

    static func record(video: String, file: URL, engine: TranslationEngine, label: String) {
        guard !video.isEmpty else { return }
        index.update { current in
            var list = current.videos[video] ?? []
            list.removeAll { $0.file == file.lastPathComponent }
            list.append(Entry(file: file.lastPathComponent, engine: engine.rawValue,
                              label: label, date: Date()))
            // Bir video için birkaç izi çevirmiş olabilir; son beşi yeter.
            current.videos[video] = Array(list.suffix(5))
        }
    }

    /// Bu video için saklanan çeviriler, en yenisi başta. Dosyası silinmiş
    /// kayıtlar (önbellek temizlenmişse) elenir.
    static func entries(video: String) -> [(entry: Entry, url: URL)] {
        guard !video.isEmpty else { return [] }
        return (index.value.videos[video] ?? [])
            .sorted { $0.date > $1.date }
            .compactMap { entry in
                let url = directory.appendingPathComponent(entry.file)
                guard FileManager.default.fileExists(atPath: url.path) else { return nil }
                return (entry, url)
            }
    }

    // MARK: - Ayarlar için

    struct Stats {
        var count: Int
        var bytes: Int

        var isEmpty: Bool { count == 0 }

        var summary: String {
            guard count > 0 else { return "Kayıtlı çeviri yok." }
            let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
            return "\(count) çeviri saklanıyor (\(size))."
        }
    }

    static func stats() -> Stats {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let vtt = files.filter { $0.pathExtension == "vtt" }
        let bytes = vtt.reduce(0) { total, url in
            total + ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return Stats(count: vtt.count, bytes: bytes)
    }

    @discardableResult
    static func clear() -> Int {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        var removed = 0
        for file in files where file.pathExtension == "vtt" {
            if (try? FileManager.default.removeItem(at: file)) != nil { removed += 1 }
        }
        // Dosyalar gidince dizin de boşalmalı, yoksa var olmayan çevirilere
        // işaret eden kayıtlar kalır.
        index.replace(with: Index())
        return removed
    }
}
