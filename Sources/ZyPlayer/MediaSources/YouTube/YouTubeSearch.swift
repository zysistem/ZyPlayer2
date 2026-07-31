import Foundation

/// Aramada çıkan tek bir YouTube videosu.
///
/// Kütüphane öğesi değil: kalıcı bir kaydı yok, yalnızca arama sonucunda
/// yaşıyor. Oynatma `videoID` üzerinden mpv'nin ytdl kancasıyla yapılıyor.
struct YouTubeVideo: Identifiable, Hashable {
    let videoID: String
    let title: String
    /// Kanal adı — "Kurtlar Vadisi" gibi resmi bir kanal, sonucun güvenilirliğini
    /// gösterdiği için kartta yazıyor.
    let channel: String
    /// "1:28:02" biçiminde süre metni; canlı yayınlarda boş olur.
    let durationText: String
    let durationSeconds: Int
    let viewCountText: String
    let publishedText: String
    let thumbnailURL: URL?

    var id: String { videoID }

    /// mpv'ye verilen adres. yt-dlp bunu gerçek akış adresine çeviriyor.
    var watchURL: URL? {
        URL(string: "https://www.youtube.com/watch?v=\(videoID)")
    }

    /// Kart altındaki tek satırlık bilgi: kanal · süre · görüntülenme.
    var subtitleLine: String {
        [channel, durationText, viewCountText]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}

/// YouTube oynatmanın dış bağımlılığı.
///
/// Adresi mpv'nin ytdl kancası çözüyor, o da yt-dlp'yi çağırıyor. Paketlenmiş bir
/// .app kabuğun PATH'ini devralmadığı için MPVCore mutlak yol veriyor; burada da
/// aynı iki yola bakılıyor, ayarlarda ve oynatmadan önce uyarabilmek için.
enum YouTubePlaybackCheck {
    static let searchPaths = ["/opt/homebrew/bin/yt-dlp", "/usr/local/bin/yt-dlp"]

    static var isToolInstalled: Bool {
        searchPaths.contains { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

enum YouTubeError: LocalizedError {
    case badResponse
    case noResults

    var errorDescription: String? {
        switch self {
        case .badResponse: "YouTube yanıt vermedi."
        case .noResults: "YouTube'da sonuç bulunamadı."
        }
    }
}

/// YouTube araması — anahtar istemez.
///
/// Sitenin kendi iç API'si (InnerTube) kullanılıyor: `youtubei/v1/search`
/// uç noktası tarayıcının attığı isteğin aynısını kabul ediyor ve HTML kazımaya
/// göre çok daha küçük, çok daha kararlı bir JSON döndürüyor. Resmi Data API
/// v3'ün aksine ne API anahtarı ne de kota derdi var.
///
/// Yanıt ağacı YouTube tarafında sık sık yeniden düzenleniyor, o yüzden sabit bir
/// yol izlenmiyor: ağaç baştan sona dolaşılıp `videoRenderer` düğümleri
/// toplanıyor. Düzen değişse de videolar aynı düğümde durduğu için arama
/// çalışmaya devam ediyor.
struct YouTubeClient {
    /// Tarayıcı gibi görünmek şart: bilinmeyen bir istemci adıyla YouTube boş
    /// yanıt döndürüyor.
    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 " +
        "(KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36"

    /// Kısa videolar (klipler, Shorts, fragmanlar) elenirken kullanılan sınır.
    /// Amaç dizi/film bulmak; 4 dakikanın altındaki hiçbir şey bölüm değil.
    private static let minimumDuration = 240

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func search(_ query: String, limit: Int = 24) async throws -> [YouTubeVideo] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return [] }

        var request = URLRequest(url: URL(string: "https://www.youtube.com/youtubei/v1/search")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "context": [
                "client": [
                    "clientName": "WEB",
                    "clientVersion": "2.20240101.00.00",
                    "hl": "tr",
                    "gl": "TR"
                ]
            ],
            "query": trimmed
        ])

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let root = try? JSONSerialization.jsonObject(with: data) else {
            throw YouTubeError.badResponse
        }

        var seen = Set<String>()
        var videos: [YouTubeVideo] = []
        for renderer in Self.videoRenderers(in: root) {
            guard let video = Self.video(from: renderer) else { continue }
            guard video.durationSeconds >= Self.minimumDuration else { continue }
            guard seen.insert(video.videoID).inserted else { continue }
            videos.append(video)
            if videos.count >= limit { break }
        }
        return videos
    }

    // MARK: - Ayrıştırma

    /// JSON ağacındaki bütün `videoRenderer` düğümlerini sırayla verir. Sıra
    /// YouTube'un alaka sıralaması; olduğu gibi korunuyor.
    private static func videoRenderers(in node: Any) -> [[String: Any]] {
        var found: [[String: Any]] = []
        if let dict = node as? [String: Any] {
            if let renderer = dict["videoRenderer"] as? [String: Any] {
                found.append(renderer)
            }
            for value in dict.values {
                found.append(contentsOf: videoRenderers(in: value))
            }
        } else if let array = node as? [Any] {
            for value in array {
                found.append(contentsOf: videoRenderers(in: value))
            }
        }
        return found
    }

    private static func video(from renderer: [String: Any]) -> YouTubeVideo? {
        guard let videoID = renderer["videoId"] as? String, !videoID.isEmpty,
              let title = text(renderer["title"]), !title.isEmpty else { return nil }

        // Süresi olmayan sonuç canlı yayın ya da yayınlanmamış içeriktir.
        let durationText = text(renderer["lengthText"]) ?? ""

        return YouTubeVideo(
            videoID: videoID,
            title: title,
            channel: text(renderer["ownerText"]) ?? text(renderer["longBylineText"]) ?? "",
            durationText: durationText,
            durationSeconds: seconds(fromDuration: durationText),
            viewCountText: shortViewCount(text(renderer["shortViewCountText"])
                                          ?? text(renderer["viewCountText"]) ?? ""),
            publishedText: text(renderer["publishedTimeText"]) ?? "",
            thumbnailURL: thumbnailURL(videoID: videoID)
        )
    }

    /// YouTube metinleri iki biçimde geliyor: `simpleText` ya da parçalara ayrılmış
    /// `runs`. İkisini de tek bir dizeye indiriyor.
    private static func text(_ node: Any?) -> String? {
        guard let dict = node as? [String: Any] else { return nil }
        if let simple = dict["simpleText"] as? String { return simple }
        if let runs = dict["runs"] as? [[String: Any]] {
            let joined = runs.compactMap { $0["text"] as? String }.joined()
            return joined.isEmpty ? nil : joined
        }
        return nil
    }

    /// "1:28:02" → 5282. Ayrıştırılamayan (boş) süre 0 döner ve sonuç elenir.
    private static func seconds(fromDuration text: String) -> Int {
        let parts = text.split(separator: ":").compactMap { Int($0) }
        guard !parts.isEmpty else { return 0 }
        return parts.reduce(0) { $0 * 60 + $1 }
    }

    /// Küçük afişin adresi. Yanıttaki adresler imzalı ve uzun ömürlü değil;
    /// `i.ytimg.com` üzerindeki sabit adres her video için çalışıyor.
    private static func thumbnailURL(videoID: String) -> URL? {
        URL(string: "https://i.ytimg.com/vi/\(videoID)/mqdefault.jpg")
    }

    /// "3.036.179 görüntüleme" uzun; kartta "3.036.179" yeter.
    private static func shortViewCount(_ text: String) -> String {
        text.replacingOccurrences(of: " görüntüleme", with: "")
            .replacingOccurrences(of: " views", with: "")
    }
}
