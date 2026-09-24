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
                        guard write(absolutized(body, base: absolute), to: folder, name: name)
                        else { return nil }
                        nested[key] = name
                    }
                    out = out.replacingOccurrences(of: reference, with: nested[key]!)
                }
                lines.append(out)
            }
            text = lines.joined(separator: "\n")
        } else {
            // Doğrudan bir medya listesi: yalnızca adresleri mutlaklaştırılır.
            text = absolutized(master, base: masterURL)
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

    private static func fetch(_ url: URL, headers: [String: String]) async -> String? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode)
        else { return nil }
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
            let body = file(forRequest: request)
            var head = body == nil ? "HTTP/1.1 404 Not Found\r\n" : "HTTP/1.1 200 OK\r\n"
            head += "Content-Type: application/vnd.apple.mpegurl\r\n"
            head += "Content-Length: \(body?.count ?? 0)\r\n"
            head += "Connection: close\r\n\r\n"
            var response = Data(head.utf8)
            if let body, !request.hasPrefix("HEAD ") { response.append(body) }
            connection.send(content: response, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    /// "GET /{id}/master.m3u8 HTTP/1.1" → klasördeki dosya. Klasörün dışına
    /// çıkan (`..`) bir yol reddedilir.
    private nonisolated static func file(forRequest request: String) -> Data? {
        let parts = request.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2, parts[0] == "GET" || parts[0] == "HEAD" else { return nil }
        let path = String(parts[1].split(separator: "?").first ?? "")
        let root = HLSPlaylistLocalizer.directory.standardizedFileURL
        let target = root.appendingPathComponent(path).standardizedFileURL
        guard target.path.hasPrefix(root.path + "/") else { return nil }
        return try? Data(contentsOf: target)
    }
}
