import Foundation
import Observation

/// Akış sitelerinden çözülen bir yayını (m3u8/mp4) `ffmpeg` ile diske indirir.
///
/// Torrent indirmeleri `aria2` ile yürür; akış yayınlarının çoğu HLS (m3u8)
/// olduğundan doğrudan dosya indirilemiyor — segmentleri birleştirip tek bir
/// mp4'e yazmak için `ffmpeg` kullanılıyor. İndirilenler ekranı hem bu listeyi
/// hem torrent listesini gösteriyor.
///
/// Sıra tek tek işleniyor: her iş için önce yayın çözülüyor (WKWebView tabanlı
/// `StreamResolver` MainActor'a bağlı), sonra `ffmpeg` çağrılıyor. Bir sezonun
/// tüm bölümleri arka arkaya kuyruğa alınıp sırayla iniyor.
@MainActor
@Observable
final class StreamDownloadStore {

    private(set) var items: [StreamDownloadItem] = []

    /// Sağlayıcı çözümü RootView'den bağlanır; canlı ayarları okur ki alan adı
    /// değişince yeni indirmeler doğru adrese gitsin.
    var lookup: (String) -> StreamProvider? = { _ in nil }

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private var pending: [StreamDownloadJob] = []
    /// Süren her indirmenin ffmpeg süreci — id'ye göre; durdurmak için tutuluyor.
    /// Aynı anda birden çok indirme olabildiğinden tekil değil, sözlük.
    @ObservationIgnored private var runningProcesses: [UUID: Process] = [:]
    /// Aynı anda kaç iş çalışıyor (çözümleme + indirme dâhil).
    @ObservationIgnored private var activeJobs = 0
    /// Aynı anda en çok kaç dosya insin.
    @ObservationIgnored private let maxConcurrent = 2

    init(settings: AppSettings) {
        self.settings = settings
        loadPersisted()
    }

    var isEngineAvailable: Bool { Self.ffmpegPath != nil }

    // MARK: - Kalıcılık

    @ObservationIgnored private static let storeURL = AppPaths.file("stream-downloads.json")

    private struct Record: Codable {
        var request: StreamDownloadRequest
        var status: StreamDownloadItem.Status
        var destinationPath: String
    }

    /// Listeyi diske yazar; uygulama kapanıp açılınca indirmeler kaybolmasın diye.
    private func persist() {
        let records = items.map {
            Record(request: $0.request, status: $0.status, destinationPath: $0.destinationPath)
        }
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: Self.storeURL, options: .atomic)
    }

    /// Açılışta kayıtlı listeyi yükler. Yarım kalanlar (resolving/downloading)
    /// "bekliyor"a çekilir; `resumePersisted()` bunları yeniden sıraya alır.
    private func loadPersisted() {
        guard let data = try? Data(contentsOf: Self.storeURL),
              let records = try? JSONDecoder().decode([Record].self, from: data) else { return }
        for record in records {
            let exists = FileManager.default.fileExists(atPath: record.destinationPath)
            var status = record.status
            if status == .resolving || status == .downloading { status = exists ? .complete : .waiting }
            if status == .waiting, exists { status = .complete }
            let item = StreamDownloadItem(request: record.request,
                                          destinationPath: record.destinationPath, status: status)
            if status == .complete { item.progress = 1 }
            items.append(item)
        }
    }

    /// RootView, sağlayıcı çözümünü (`lookup`) bağladıktan sonra çağırır: açılışta
    /// yarım kalan indirmeleri yeniden sıraya alır. HLS baştan iner (segment
    /// birleştirme ortadan sürdürülemiyor).
    func resumePersisted() {
        for item in items where item.status == .waiting {
            let (folder, output) = destination(for: item.request)
            if FileManager.default.fileExists(atPath: output.path) {
                item.status = .complete
                item.progress = 1
                continue
            }
            pending.append(StreamDownloadJob(request: item.request, item: item,
                                             folderURL: folder, outputURL: output))
        }
        persist()
        processQueue()
    }

    // MARK: - Kuyruğa alma

    /// Verilen istekleri kuyruğa ekler ve boştaysa işlemeyi başlatır. Her istek
    /// için indirme klasörü içinde `folderName` altında bir dosya oluşturulur.
    func enqueue(_ requests: [StreamDownloadRequest]) {
        for request in requests {
            let (folder, output) = destination(for: request)
            // Zaten diskte var: tekrar indirme (kullanıcı "bende olanları indirme"
            // dedi). Bölüm bölüm indirmede sahip olunan bölümler atlanır.
            if FileManager.default.fileExists(atPath: output.path) { continue }
            // Aynı dosya zaten kuyrukta/iniyorsa atla.
            if items.contains(where: { $0.destinationPath == output.path
                && $0.status != .error && $0.status != .cancelled }) { continue }
            let item = StreamDownloadItem(request: request, destinationPath: output.path)
            items.append(item)
            pending.append(StreamDownloadJob(request: request, item: item,
                                             folderURL: folder, outputURL: output))
        }
        persist()
        processQueue()
    }

    /// İsteğin indirme klasörü ve hedef dosyası. İndirme dizini ayarlardan okunur.
    /// `folderName` "Dizi/Sezon 1" gibi çok parçalı olabilir — her parça ayrı ayrı
    /// temizlenip alt klasör olarak ekleniyor.
    private func destination(for request: StreamDownloadRequest) -> (folder: URL, output: URL) {
        let root = URL(fileURLWithPath: settings.downloadDirectory.isEmpty
                       ? Self.defaultDownloadDirectory : settings.downloadDirectory)
        var folder = root
        for part in request.folderName.split(separator: "/") {
            folder.appendPathComponent(Self.sanitize(String(part)), isDirectory: true)
        }
        let output = folder.appendingPathComponent(Self.sanitize(request.fileName))
        return (folder, output)
    }

    // MARK: - Eylemler

    func cancel(_ item: StreamDownloadItem) {
        pending.removeAll { $0.item.id == item.id }
        if let process = runningProcesses[item.id] {
            item.status = .cancelled
            process.terminate()
        } else if item.status == .waiting || item.status == .resolving {
            item.status = .cancelled
        }
        persist()
    }

    func remove(_ item: StreamDownloadItem) {
        cancel(item)
        items.removeAll { $0.id == item.id }
        persist()
    }

    /// Biten, hatalı ve iptal edilenleri listeden kaldırır; süren ve bekleyenlere
    /// dokunmaz.
    func clearFinished() {
        items.removeAll { $0.status == .complete || $0.status == .error || $0.status == .cancelled }
        persist()
    }

    /// Temizlenebilecek (biten/hatalı/iptal) bir öğe var mı.
    var hasClearable: Bool {
        items.contains { $0.status == .complete || $0.status == .error || $0.status == .cancelled }
    }

    // MARK: - Kuyruk işleme

    /// Kuyruğu işler: `maxConcurrent` sınırına kadar iş paralel başlatır. Her iş
    /// bitince sayaç düşürülüp kuyruk yeniden yoklanır. MainActor'a bağlı olduğu
    /// için sayaç erişimi güvenli.
    private func processQueue() {
        while activeJobs < maxConcurrent, !pending.isEmpty {
            let job = pending.removeFirst()
            if job.item.status == .cancelled { continue }
            activeJobs += 1
            Task {
                await run(job)
                activeJobs -= 1
                processQueue()
            }
        }
    }

    private func run(_ job: StreamDownloadJob) async {
        let item = job.item
        // HLS indirmeleri ölü bir segmentte ya da CDN kesintisinde asılı
        // kalabiliyor; her turda yayın taze çözülüp ffmpeg gözcüyle yeniden
        // başlatılıyor. Birkaç tur denenip yine olmazsa hata.
        let maxAttempts = 3
        for attempt in 1...maxAttempts {
            guard item.status != .cancelled else { return }
            item.status = .resolving
            item.errorMessage = nil

            // Sayfadaki tüm sunucular (HdFilmCehennemi'de Close + Rapidrame).
            let embeds: [StreamEmbed]
            do {
                embeds = try await fetchEmbeds(pageURL: job.request.pageURL,
                                               providerID: job.request.providerID)
            } catch {
                if item.status != .cancelled {
                    item.status = .error
                    item.errorMessage = "Yayın çözülemedi."
                }
                persist()
                return
            }
            guard item.status != .cancelled else { return }

            try? FileManager.default.createDirectory(at: job.folderURL, withIntermediateDirectories: true)

            // Her sunucuyu uçtan uca dene: biri çözülüp inMEZse (ör. Close bozuk)
            // diğerine (Rapidrame) geç. Kolay pes etme.
            for embed in embeds {
                guard item.status != .cancelled else { return }
                item.status = .resolving
                // Eşzamanlı indirmelerde çakışmasın diye her embed'e taze çözümleyici.
                let resolver = StreamResolver()
                guard let resolved = try? await resolver.resolve(embed, timeout: .seconds(8)) else {
                    continue   // bu sunucu çözülemedi → sıradaki sunucu
                }
                guard item.status != .cancelled else { return }

                item.status = .downloading
                let ok = await runFFmpeg(source: resolved, output: job.outputURL, item: item)
                if ok {
                    // Altyazıları videonun yanına aynı adla yaz — hem in-app mpv
                    // (sub-auto fuzzy) hem Infuse bunları otomatik yükler.
                    await saveSubtitles(resolved.subtitles, headers: resolved.headers,
                                        besideVideo: job.outputURL)
                    item.progress = 1
                    item.status = .complete
                    // Bilinçli olarak kütüphaneye eklenmiyor.
                    persist()
                    return
                }
                guard item.status != .cancelled else { return }
                // Bu sunucu indi ama başarısız oldu → sıradaki sunucuyu dene.
            }

            // Bu turda hiçbir sunucu inmedi: son tur değilse kısa bekleyip yeniden dene.
            if attempt < maxAttempts {
                item.status = .waiting
                try? await Task.sleep(for: .seconds(2))
            }
        }
        if item.status != .cancelled {
            item.status = .error
            if item.errorMessage == nil { item.errorMessage = "İndirme başarısız." }
        }
        persist()
    }

    /// Sayfadaki tüm oynatıcı sunucularını döndürür (HdFilmCehennemi'de Close +
    /// Rapidrame). İndirme bunları uçtan uca sırayla deniyor.
    private func fetchEmbeds(pageURL: String, providerID: String) async throws -> [StreamEmbed] {
        guard let provider = lookup(providerID) else { throw StreamDownloadError.noProvider }
        let embeds = try await provider.embeds(forPage: pageURL)
        guard !embeds.isEmpty else { throw StreamDownloadError.noEmbed }
        return embeds
    }

    // MARK: - Altyazılar (yan dosya)

    /// Her altyazıyı `<video-adı>.<etiket>.<uzantı>` olarak videonun yanına yazar.
    /// Yerel (çözümleyicinin geçici .vtt'si) doğrudan kopyalanır; uzak olanlar
    /// Referer/User-Agent ile indirilir.
    private func saveSubtitles(_ subtitles: [StreamSubtitle], headers: [String: String],
                               besideVideo output: URL) async {
        guard !subtitles.isEmpty else { return }
        let base = output.deletingPathExtension().lastPathComponent
        let dir = output.deletingLastPathComponent()
        var used = Set<String>()
        for subtitle in subtitles {
            guard let data = await subtitleData(subtitle, headers: headers), !data.isEmpty else { continue }
            let ext = { () -> String in
                let e = subtitle.url.pathExtension.lowercased()
                return (e == "srt" || e == "vtt") ? e : "vtt"
            }()
            var label = Self.sanitize(subtitle.label ?? "Altyazı")
            if label.isEmpty { label = "Altyazı" }
            var name = "\(base).\(label).\(ext)"
            var counter = 2
            while used.contains(name.lowercased()) {
                name = "\(base).\(label) \(counter).\(ext)"
                counter += 1
            }
            used.insert(name.lowercased())
            try? data.write(to: dir.appendingPathComponent(name))
        }
    }

    private func subtitleData(_ subtitle: StreamSubtitle, headers: [String: String]) async -> Data? {
        if subtitle.url.isFileURL {
            return try? Data(contentsOf: subtitle.url)
        }
        var request = URLRequest(url: subtitle.url)
        request.timeoutInterval = 20
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            return nil
        }
        return data
    }

    // MARK: - ffmpeg

    /// Yayını `output.part` dosyasına indirir; bitince asıl ada taşır. `.part`
    /// uzantısı yarım dosyanın kütüphaneye (video değil) alınmasını engelliyor.
    private func runFFmpeg(source: ResolvedStream, output: URL, item: StreamDownloadItem) async -> Bool {
        guard let ffmpeg = Self.ffmpegPath else {
            item.errorMessage = "ffmpeg bulunamadı. `brew install ffmpeg`."
            return false
        }

        let partURL = output.appendingPathExtension("part")
        try? FileManager.default.removeItem(at: partURL)

        var arguments = ["-nostdin", "-y", "-loglevel", "info", "-stats"]
        // Referer/User-Agent CDN'in beklediği başlıklar; oynatmada olduğu gibi
        // burada da geçilmezse 403 dönebilir.
        var headerLines = ""
        for (key, value) in source.headers where key.lowercased() != "user-agent" {
            headerLines += "\(key): \(value)\r\n"
        }
        if !headerLines.isEmpty { arguments += ["-headers", headerLines] }
        if let ua = source.headers.first(where: { $0.key.lowercased() == "user-agent" })?.value {
            arguments += ["-user_agent", ua]
        }
        // Segment kesintilerinde asılı kalmak yerine yeniden bağlan: HLS
        // indirmelerinin en sık takıldığı yer ölü/yavaş bir segment. Bir okuma
        // 15 sn içinde ilerlemezse koptu sayılıp yeniden bağlanılır.
        arguments += ["-reconnect", "1", "-reconnect_streamed", "1",
                      "-reconnect_delay_max", "4", "-rw_timeout", "15000000"]
        // Türk akış CDN'leri HLS segmentlerini `.jpg` gibi sahte uzantılarla
        // gizliyor; ffmpeg 8.x güvenlik gereği bilinmeyen uzantılı segmentleri
        // reddedip "Invalid data / no stream" veriyor. Bu üç seçenek katı uzantı
        // denetimini kapatıp tüm segmentlere izin veriyor. `-i`'den ÖNCE gelmeli.
        //
        // DİKKAT: bunlar HLS demuxer'ına özel; doğrudan mp4 gibi HLS olmayan bir
        // girdide "Option not found" deyip tüm işi bozuyorlar. Bu yüzden yalnızca
        // URL bir HLS yayınına benziyorsa ekleniyor.
        let lowerURL = source.url.absoluteString.lowercased()
        let isHLS = lowerURL.contains(".m3u8") || lowerURL.contains("/hls")
            || lowerURL.contains("master.txt") || lowerURL.contains("/txt/")
        if isHLS {
            arguments += ["-extension_picky", "0",
                          "-allowed_extensions", "ALL",
                          "-allowed_segment_extensions", "ALL"]
        }
        arguments += ["-i", source.url.absoluteString]
        // ÖNEMLİ: çıktı adı `…mp4.part` olduğundan ffmpeg biçimi uzantıdan
        // çıkaramaz; `-f mp4` ile açıkça verilmezse "suitable output format
        // bulunamadı" deyip çöker. TS/AAC bir HLS'i mp4'e sararken gereken
        // `aac_adtstoasc` süzgecini modern ffmpeg kendisi ekliyor; elle
        // eklersek doğrudan mp4 kaynaklarda hata veriyor, o yüzden eklemiyoruz.
        arguments += ["-c", "copy", "-movflags", "+faststart", "-f", "mp4"]
        arguments += [partURL.path]

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = arguments
        let errorPipe = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe

        // ffmpeg ilerlemeyi stderr'e yazıyor: başta "Duration:", sonra sürekli
        // "time=" satırları. Aynı borudan hem ilerlemeyi okuyoruz hem de hata
        // ayıklama için son satırları biriktiriyoruz.
        let errorBox = StderrBox()
        errorPipe.fileHandleForReading.readabilityHandler = { [weak item] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            errorBox.append(text)
            guard let item else { return }
            let (duration, time) = Self.parseProgress(text)
            Task { @MainActor in
                if let duration, duration > 0 { item.durationSeconds = duration }
                if let time {
                    item.positionSeconds = time
                    if item.durationSeconds > 0 {
                        item.progress = min(0.999, time / item.durationSeconds)
                    }
                }
            }
        }

        // Gözcü: ilerleme (positionSeconds) belirli süre hiç artmazsa yayın
        // asılı kalmış demektir — süreci öldür ki `run()` yeniden denesin.
        // `-rw_timeout`/reconnect çoğu takılmayı kendi çözer; bu son güvence.
        let stallTimeout: Double = 40
        let watchdog = Task { @MainActor [weak item] in
            var lastPosition = -1.0
            var lastChange = Date()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard let item, runningProcesses[item.id] != nil else { break }
                if item.positionSeconds != lastPosition {
                    lastPosition = item.positionSeconds
                    lastChange = Date()
                } else if Date().timeIntervalSince(lastChange) > stallTimeout {
                    item.errorMessage = "Takıldı, yeniden deneniyor…"
                    runningProcesses[item.id]?.terminate()
                    break
                }
            }
        }

        // terminationHandler run()'dan ÖNCE kurulur: çok hızlı çıkan bir ffmpeg
        // sonra kurarsak devam sinyalini kaçırıp kilitlenebiliriz.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in cont.resume() }
            runningProcesses[item.id] = process
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                item.errorMessage = "ffmpeg başlatılamadı."
                cont.resume()
            }
        }
        watchdog.cancel()
        errorPipe.fileHandleForReading.readabilityHandler = nil
        runningProcesses[item.id] = nil

        let success = process.terminationStatus == 0
            && FileManager.default.fileExists(atPath: partURL.path)
        if success {
            try? FileManager.default.removeItem(at: output)
            try? FileManager.default.moveItem(at: partURL, to: output)
            return true
        }
        try? FileManager.default.removeItem(at: partURL)
        // terminate() SIGTERM gönderir; kullanıcı durdurduysa hata değil iptal.
        if item.status == .cancelled { return false }
        let tail = errorBox.tail()
        Self.logFailure(url: source.url.absoluteString, status: process.terminationStatus, stderr: tail)
        item.errorMessage = Self.friendlyError(from: tail)
        return false
    }

    /// ffmpeg çıktısının sonundan kullanıcıya gösterilecek kısa neden çıkarır.
    nonisolated private static func friendlyError(from stderr: String) -> String {
        let lower = stderr.lowercased()
        if lower.contains("403") { return "Erişim reddedildi (403)" }
        if lower.contains("404") { return "Kaynak bulunamadı (404)" }
        if lower.contains("suitable output format") { return "Biçim hatası (ffmpeg)" }
        if lower.contains("invalid data") { return "Yayın çözülemedi (geçersiz veri)" }
        if lower.contains("connection") || lower.contains("timed out") { return "Bağlantı hatası" }
        // Son anlamlı satırı göster.
        if let last = stderr.split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map(String.init).last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            return String(last.prefix(80))
        }
        return "İndirme başarısız (ffmpeg)"
    }

    /// Hata ayıklama için başarısız indirmeleri bir günlük dosyasına yazar.
    nonisolated private static func logFailure(url: String, status: Int32, stderr: String) {
        NSLog("ZyStream indirme hatası (%d): %@", status, url)
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("zystream-download.log")
        let entry = "[\(Date())] status=\(status) url=\(url)\n\(stderr)\n\n"
        if let data = entry.data(using: .utf8) {
            if let handle = try? FileHandle(forWritingTo: logURL) {
                handle.seekToEndOfFile(); handle.write(data); try? handle.close()
            } else {
                try? data.write(to: logURL)
            }
        }
    }

    /// stderr parçasından süre ve geçerli konumu (saniye) okur.
    nonisolated private static func parseProgress(_ text: String) -> (duration: Double?, time: Double?) {
        var duration: Double?
        var time: Double?
        if let range = text.range(of: "Duration: ") {
            let tail = text[range.upperBound...].prefix(11)
            duration = seconds(fromTimecode: String(tail))
        }
        // Son "time=" değeri en güncel konum.
        var searchStart = text.startIndex
        while let range = text.range(of: "time=", range: searchStart..<text.endIndex) {
            let tail = text[range.upperBound...].prefix(11)
            if let value = seconds(fromTimecode: String(tail)) { time = value }
            searchStart = range.upperBound
        }
        return (duration, time)
    }

    /// "01:23:45.67" → saniye.
    nonisolated private static func seconds(fromTimecode raw: String) -> Double? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.split(separator: ":")
        guard parts.count == 3,
              let h = Double(parts[0]), let m = Double(parts[1]),
              let s = Double(parts[2]) else { return nil }
        return h * 3600 + m * 60 + s
    }

    // MARK: - Yardımcılar

    /// Dosya/klasör adından geçersiz karakterleri temizler.
    static func sanitize(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:*?\"<>|")
        let cleaned = name.components(separatedBy: invalid).joined(separator: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "ZyStream" : cleaned
    }

    static let ffmpegPath: String? = {
        let candidates = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    static var defaultDownloadDirectory: String {
        (FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
         ?? FileManager.default.homeDirectoryForCurrentUser).path
    }
}

/// İndirilenler ekranında gösterilen tek bir akış indirmesi.
@MainActor
@Observable
final class StreamDownloadItem: Identifiable {
    let id = UUID()
    /// Yeniden başlatınca (uygulama kapanıp açılınca) indirmeyi baştan kurabilmek
    /// için isteğin tamamı saklanıyor.
    let request: StreamDownloadRequest
    let destinationPath: String
    var status: Status = .waiting
    var progress: Double = 0
    var positionSeconds: Double = 0
    var durationSeconds: Double = 0
    var errorMessage: String?

    var title: String { request.title }

    init(request: StreamDownloadRequest, destinationPath: String, status: Status = .waiting) {
        self.request = request
        self.destinationPath = destinationPath
        self.status = status
    }

    enum Status: String, Codable {
        case waiting, resolving, downloading, complete, error, cancelled
    }

    var isActive: Bool { status == .resolving || status == .downloading }

    var statusLine: String {
        switch status {
        case .waiting:     return "Sırada"
        case .resolving:   return "Yayın çözülüyor…"
        case .downloading: return "İndiriliyor"
        case .complete:    return "Tamamlandı"
        case .cancelled:   return "İptal edildi"
        case .error:       return errorMessage ?? "Hata"
        }
    }
}

/// İndirme isteği: hangi sayfa, hangi klasör ve hangi dosya adıyla.
struct StreamDownloadRequest: Codable {
    let pageURL: String
    let providerID: String
    /// İndirilenler satırında görünen ad.
    let title: String
    /// Kaydedilecek dosya adı (uzantı dâhil), ör. "S02E03.mp4".
    let fileName: String
    /// IMDb/TMDB adıyla oluşturulacak klasör, ör. "Breaking Bad".
    let folderName: String
}

private struct StreamDownloadJob {
    let request: StreamDownloadRequest
    let item: StreamDownloadItem
    let folderURL: URL
    let outputURL: URL
}

enum StreamDownloadError: Error {
    case noProvider, noEmbed
}

/// ffmpeg stderr'inin son bölümünü iş parçacığı güvenli biriktirir (arka plandaki
/// `readabilityHandler`'dan yazılıp bitişte okunuyor).
final class StderrBox: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""
    private let maxChars = 6000

    func append(_ text: String) {
        lock.lock(); defer { lock.unlock() }
        buffer += text
        if buffer.count > maxChars {
            buffer = String(buffer.suffix(maxChars))
        }
    }

    func tail() -> String {
        lock.lock(); defer { lock.unlock() }
        return buffer
    }
}
