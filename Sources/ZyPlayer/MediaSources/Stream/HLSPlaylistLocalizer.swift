import Foundation
import Network

/// Bir HLS master listesini ve onun iç listelerini URLSession ile indirip yerel
/// bir kopya kurar; mpv/ffmpeg'e bu kopyanın `127.0.0.1` adresi verilir.
///
/// Neden: Dizipal'in oynatıcı sunucusu (`*.dplayer82.site`) Cloudflare WAF'ı
/// arkasında ve ffmpeg'in TLS parmak izini "bot" sayıyor — master.m3u8 geçiyor
/// ama `l.php`/`ld.php` iç listeleri 403 dönüyor. URLSession Safari'yle aynı TLS
/// yığınını kullandığı için geçebiliyor. Video parçaları ayrı bir CDN'de ve
/// ffmpeg'e açık; onlar doğrudan ağdan okunmaya devam eder.
///
/// Neden dosya değil de yerel HTTP: parça CDN'i `Referer` istiyor. ffmpeg'in HLS
/// okuyucusu `Referer`/`User-Agent`'ı listeyi açtığı bağlantıdan kopyalıyor;
/// liste diskten açılırsa kopyalayacak başlık yok ve parçalar 403. HTTP'den
/// açılınca başlıklar parçalara da taşınıyor — hem mpv'de hem indirmede.
///
/// Yerel listelerdeki tüm adresler mutlak yapılır. Liste VOD olduğu için
/// (`#EXT-X-ENDLIST`) bir kez indirmek yeter.
///
/// Medya parçaları da yerel sunucudan verilir (`HLSSegmentProxy`): mpv'nin
/// önbelleği dolunca parçalar oynatma hızında, duraklatınca hiç okunmuyor ve
/// uzak bağlantı parçanın ortasında bekliyor. Bazı sunucular (HDFC'nin
/// playmix CDN'i) bekleyen bağlantıyı kesiyor; ffmpeg'in HLS okuyucusu bunu
/// parçanın sonu sayıp yarım parçayla devam ediyor ve ses zaman damgası
/// sıçrıyor — oynatmada ara ara takılma, bazen ses çözücünün dakikalarca
/// bozulması. Vekil her parçayı tek seferde ve eksiksiz indirir.
enum HLSPlaylistLocalizer {
    /// Yerel listelerin yazıldığı klasör; sunucu yalnızca bunun altını verir.
    static let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ZyStreamHLS", isDirectory: true)

    /// Başarısızlıkta `nil` — çağıran özgün adresle devam eder.
    static func localize(_ masterURL: URL, headers: [String: String]) async -> URL? {
        guard let master = await fetch(masterURL, headers: headers),
              master.hasPrefix("#EXTM3U"),
              let server = await LocalPlaylistServer.shared.baseURL() else { return nil }

        let id = UUID().uuidString
        let folder = directory.appendingPathComponent(id, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch { return nil }

        let text: String
        if master.contains("#EXT-X-STREAM-INF") {
            // Master'daki her iç liste (varyant satırları ve EXT-X-MEDIA'nın
            // URI'leri) indirilip yerel bir dosyayla değiştirilir.
            var nested: [String: String] = [:]   // mutlak adres → yerel dosya adı
            var lines: [String] = []
            for line in master.components(separatedBy: .newlines) {
                var out = line
                for reference in references(in: line) {
                    guard let absolute = URL(string: reference, relativeTo: masterURL)?.absoluteURL
                    else { return nil }
                    let key = absolute.absoluteString
                    if nested[key] == nil {
                        guard let body = await fetch(absolute, headers: headers),
                              body.hasPrefix("#EXTM3U") else { return nil }
                        let name = "p\(nested.count + 1).m3u8"
                        let local = prepared(body, base: absolute, server: server, headers: headers)
                        guard write(local, to: folder, name: name) else { return nil }
                        nested[key] = name
                    }
                    out = out.replacingOccurrences(of: reference, with: nested[key]!)
                }
                lines.append(out)
            }
            text = lines.joined(separator: "\n")
        } else {
            // Doğrudan bir medya listesi.
            text = prepared(master, base: masterURL, server: server, headers: headers)
        }
        guard write(text, to: folder, name: "master.m3u8") else { return nil }
        return server.appendingPathComponent(id).appendingPathComponent("master.m3u8")
    }

    // MARK: - Yardımcılar

    /// Bir satırdaki liste adresleri: yorum olmayan satırın kendisi ya da
    /// etiketlerdeki `URI="…"` değerleri.
    private static func references(in line: String) -> [String] {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return [] }
        if !trimmed.hasPrefix("#") { return [trimmed] }
        var found: [String] = []
        var rest = Substring(trimmed)
        while let start = rest.range(of: "URI=\"") {
            let after = rest[start.upperBound...]
            guard let end = after.firstIndex(of: "\"") else { break }
            found.append(String(after[..<end]))
            rest = after[after.index(after: end)...]
        }
        return found
    }

    /// Bir medya listesinin yerel kopyası: adresler mutlak, parçalar yerel
    /// vekilden. Bayt aralıklı listelerde (`EXT-X-BYTERANGE`) vekil aynı dosyanın
    /// farklı aralıklarını ayırt edemez; parçalar doğrudan okunmaya devam eder.
    private static func prepared(_ playlist: String, base: URL, server: URL,
                                 headers: [String: String]) -> String {
        let absolute = absolutized(playlist, base: base)
        guard absolute.contains("#EXTINF"), !absolute.contains("#EXT-X-BYTERANGE") else {
            return absolute
        }
        let listID = UUID().uuidString
        var segments: [URL] = []
        let lines = absolute.components(separatedBy: .newlines).map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"),
                  let remote = URL(string: trimmed) else { return line }
            let index = segments.count
            segments.append(remote)
            // HDFC parçaları `.jpg` kılığında; mpv'ye gerçek türüyle görünsünler.
            let ext = remote.pathExtension.lowercased()
            let name = ["ts", "m4s", "mp4", "aac", "m4a", "mp3"].contains(ext)
                ? "\(index).\(ext)" : "\(index).ts"
            return server.appendingPathComponent("seg").appendingPathComponent(listID)
                .appendingPathComponent(name).absoluteString
        }
        HLSSegmentProxy.register(listID: listID, segments: segments, headers: headers)
        return lines.joined(separator: "\n")
    }

    /// Parça, anahtar ve iç liste adreslerini `base`'e göre mutlak yapar.
    private static func absolutized(_ playlist: String, base: URL) -> String {
        playlist.components(separatedBy: .newlines).map { line in
            var out = line
            for reference in references(in: line) {
                guard let absolute = URL(string: reference, relativeTo: base)?.absoluteString,
                      absolute != reference else { continue }
                out = out.replacingOccurrences(of: reference, with: absolute)
            }
            return out
        }.joined(separator: "\n")
    }

    private static let maxPlaylistBytes = 8 * 1024 * 1024

    /// Liste değilse (ör. doğrudan bir mp4) ilk baytlarda vazgeçer; filmin
    /// tamamı belleğe indirilmez.
    private static func fetch(_ url: URL, headers: [String: String]) async -> String? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        guard let (bytes, response) = try? await URLSession.shared.bytes(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              http.expectedContentLength <= Int64(maxPlaylistBytes)
        else { return nil }
        let signature = Data("#EXTM3U".utf8)
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count == signature.count, data != signature { return nil }
                if data.count > maxPlaylistBytes { return nil }
            }
        } catch {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func write(_ text: String, to folder: URL, name: String) -> Bool {
        (try? text.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)) != nil
    }
}

/// `HLSPlaylistLocalizer.directory` altındaki listeleri `127.0.0.1`'de veren,
/// yalnızca GET bilen küçük bir HTTP sunucusu. İlk ihtiyaçta rastgele bir
/// portta açılır ve uygulama boyunca açık kalır.
actor LocalPlaylistServer {
    static let shared = LocalPlaylistServer()

    private var listener: NWListener?
    private var base: URL?
    private let queue = DispatchQueue(label: "ZyStreamHLS.server")

    func baseURL() async -> URL? {
        if let base { return base }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        guard let listener = try? NWListener(using: parameters) else { return nil }
        listener.newConnectionHandler = { [queue] connection in
            connection.start(queue: queue)
            Self.serve(connection)
        }

        let port: UInt16? = await withCheckedContinuation { continuation in
            // İşleyici ilk sonuçta kendini söker: continuation bir kez döner.
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume(returning: listener.port?.rawValue)
                case .failed, .cancelled:
                    listener.stateUpdateHandler = nil
                    continuation.resume(returning: nil)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
        guard let port else { listener.cancel(); return nil }
        self.listener = listener
        base = URL(string: "http://127.0.0.1:\(port)")
        return base
    }

    private nonisolated static func serve(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, _, _ in
            let request = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
            let isHead = request.hasPrefix("HEAD ")
            let path = requestPath(request)
            if let path, let segment = HLSSegmentProxy.segment(forPath: path) {
                Task {
                    let body = await HLSSegmentProxy.download(segment.url, headers: segment.headers)
                    respond(connection, body: body, contentType: "video/mp2t", isHead: isHead,
                            rangeStart: rangeStart(in: request))
                }
                return
            }
            respond(connection, body: path.flatMap(file(atPath:)),
                    contentType: "application/vnd.apple.mpegurl", isHead: isHead, rangeStart: nil)
        }
    }

    /// `rangeStart` > 0 ise (ffmpeg yarıda kalan bir okumayı sürdürüyor) 206 ile
    /// o noktadan sonrası verilir.
    private nonisolated static func respond(_ connection: NWConnection, body: Data?,
                                            contentType: String, isHead: Bool,
                                            rangeStart: Int?) {
        var head: String
        var payload = body
        if let body, let start = rangeStart, start > 0, start < body.count {
            payload = body.subdata(in: start..<body.count)
            head = "HTTP/1.1 206 Partial Content\r\n"
            head += "Content-Range: bytes \(start)-\(body.count - 1)/\(body.count)\r\n"
        } else {
            head = body == nil ? "HTTP/1.1 404 Not Found\r\n" : "HTTP/1.1 200 OK\r\n"
        }
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(payload?.count ?? 0)\r\n"
        head += "Connection: close\r\n\r\n"
        var response = Data(head.utf8)
        if let payload, !isHead { response.append(payload) }
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    /// "GET /{id}/master.m3u8 HTTP/1.1" → "/{id}/master.m3u8".
    private nonisolated static func requestPath(_ request: String) -> String? {
        let parts = request.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2, parts[0] == "GET" || parts[0] == "HEAD" else { return nil }
        return String(parts[1].split(separator: "?").first ?? "")
    }

    /// "Range: bytes=N-" başlığındaki N.
    private nonisolated static func rangeStart(in request: String) -> Int? {
        for line in request.components(separatedBy: "\r\n")
        where line.lowercased().hasPrefix("range: bytes=") {
            let value = line.dropFirst("range: bytes=".count)
            return Int(value.split(separator: "-").first ?? "")
        }
        return nil
    }

    /// Klasördeki dosya. Klasörün dışına çıkan (`..`) bir yol reddedilir.
    private nonisolated static func file(atPath path: String) -> Data? {
        let root = HLSPlaylistLocalizer.directory.standardizedFileURL
        let target = root.appendingPathComponent(path).standardizedFileURL
        guard target.path.hasPrefix(root.path + "/") else { return nil }
        return try? Data(contentsOf: target)
    }
}

/// Yerel listelerdeki parçaların uzak adresleri ve onları indiren vekil.
///
/// Her parça istendiği anda uzak sunucudan tek seferde ve eksiksiz indirilir
/// (boyut `Content-Length` ile doğrulanır, eksik ya da hatalıysa yeniden
/// denenir), sonra mpv'ye yerel bağlantıdan verilir. mpv ne kadar yavaş okursa
/// okusun bekleyen bağlantı yerel olandır; uzak sunucunun kesebileceği yarım
/// bir indirme kalmaz.
enum HLSSegmentProxy {
    struct Segment {
        let url: URL
        let headers: [String: String]
    }

    private static let lock = NSLock()
    private static var lists: [String: (segments: [URL], headers: [String: String])] = [:]

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: configuration)
    }()

    static func register(listID: String, segments: [URL], headers: [String: String]) {
        lock.lock()
        lists[listID] = (segments, headers)
        lock.unlock()
    }

    /// "/seg/{liste}/{sıra}.{uzantı}" → uzak parça.
    static func segment(forPath path: String) -> Segment? {
        let parts = path.split(separator: "/")
        guard parts.count == 3, parts[0] == "seg",
              let index = Int(parts[2].split(separator: ".").first ?? "") else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard let list = lists[String(parts[1])], list.segments.indices.contains(index) else {
            return nil
        }
        return Segment(url: list.segments[index], headers: list.headers)
    }

    static func download(_ url: URL, headers: [String: String]) async -> Data? {
        for attempt in 1...3 {
            var request = URLRequest(url: url)
            for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
            if let (data, response) = try? await session.data(for: request),
               let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                // Sıkıştırılmış yanıtta beklenen boyut sıkıştırılmış haldedir;
                // karşılaştırma yalnızca düz yanıtta anlamlı.
                let expected = http.expectedContentLength
                let isEncoded = http.value(forHTTPHeaderField: "Content-Encoding") != nil
                if expected <= 0 || isEncoded || Int64(data.count) == expected { return data }
                PlaybackDiagnostics.log("HLS vekili: \(url.lastPathComponent) eksik indi (\(data.count)/\(expected)), deneme \(attempt)")
            } else {
                PlaybackDiagnostics.log("HLS vekili: \(url.lastPathComponent) indirilemedi, deneme \(attempt)")
            }
            try? await Task.sleep(nanoseconds: UInt64(attempt) * 500_000_000)
        }
        return nil
    }
}
