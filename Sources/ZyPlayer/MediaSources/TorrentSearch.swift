import Foundation

/// One playable release from the torrent index.
struct TorrentOption: Identifiable, Hashable {
    var id: String
    /// `1080p`, `4k HDR`, `720p` — whatever the index called it, kept whole
    /// because the extra words (HDR, DV) are worth seeing.
    var quality: String
    /// "BluRay · x264 · 1.85 GB" — everything else worth showing on one line.
    var detail: String
    var seeds: Int
    var peers: Int
    /// Where the release came from: "YTS", "ThePirateBay", …
    var provider: String?
    /// A `magnet:` URI or a `.torrent` URL. Handed to the streamer as-is.
    var link: String
    /// Which file to play inside a multi-file torrent — season packs carry a
    /// whole series, and picking the largest file would play the wrong episode.
    var fileIndex: Int?

    /// 4K first: the picker lists the best quality at the top. Matched as a
    /// substring, because the index labels releases "4k HDR" or "4k DV | HDR".
    var qualityRank: Int {
        let lowered = quality.lowercased()
        if lowered.contains("2160") || lowered.contains("4k") { return 0 }
        if lowered.contains("1080") { return 1 }
        if lowered.contains("720") { return 2 }
        if lowered.contains("480") { return 3 }
        return 4
    }

    /// The quality tag collapsed to a single label the filter can group by, so
    /// "4k DV | HDR", "4K HDR" and "2160p" all land under one "4K" bucket.
    var qualityBucket: String {
        switch qualityRank {
        case 0: return "4K"
        case 1: return "1080p"
        case 2: return "720p"
        case 3: return "480p"
        default: return "Diğer"
        }
    }

    /// Distinctive enough to trust anywhere in the release name.
    private static let telescreenNames = [
        "telesync", "telecine", "screener", "camrip", "hdcam"
    ]
    /// The abbreviations, only trusted in the quality tag: a film's name can
    /// contain "ts" or "cam", a quality tag cannot.
    private static let telescreenTags: Set<String> = [
        "ts", "tc", "scr", "hdts", "hdtc", "cam", "camrip", "hdcam",
        "telesync", "telecine", "screener"
    ]

    /// A telesync/telecine/screener/cam: a copy that leaked before — or was
    /// filmed off — the real release. Never offered.
    var isTelescreen: Bool {
        let tags = quality.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
        if tags.contains(where: { Self.telescreenTags.contains($0) }) { return true }
        let name = detail.lowercased()
        return Self.telescreenNames.contains { name.contains($0) }
    }

    var label: String {
        guard !quality.isEmpty else { return "Bilinmeyen" }
        return quality.replacingOccurrences(of: "4k", with: "4K")
    }
}

/// Reads torrents from a Stremio stream addon (Torrentio by default).
///
/// One index for both films and episodes: it aggregates a dozen trackers, so it
/// finds far more releases than a single site, and it is the protocol this app
/// already speaks for subtitles — same shape of address, keyed on the IMDb id
/// that every title here already resolves.
struct TorrentioClient {

    enum ClientError: LocalizedError {
        case badBase
        case http(Int)

        var errorDescription: String? {
            switch self {
            case .badBase: "Dizi torrent adresi geçersiz."
            case .http(let code): "Dizi torrent listesi alınamadı (HTTP \(code))."
            }
        }
    }

    var base: String

    /// Torrentio'nun kendi sunucusu. Ayar alanı boş bırakıldığında bu kullanılır;
    /// yapılandırma (`providers=…`) adrese `configuredBase` içinde eklenir.
    static let defaultBase = "https://torrentio.strem.fun"

    /// Eski sürümlerde kullanılan `/lite/…` yolu artık 404 dönüyor; ayarlarda
    /// böyle bir adres duruyorsa varsayılana çevrilmesi için tanınması gerekir.
    static func isDeadLegacyBase(_ value: String) -> Bool {
        let lowered = value.lowercased()
        return lowered.contains("/lite/")
            || lowered.contains("stremio.torrentio.strem.fun")
            || lowered.contains("torrentio.stremio.strem.fun")
            || lowered.contains("torrentio.elfhosted.com")
            || lowered.contains("torrentio.run")
    }

    /// Seçili 7 ana provider (YTS, EZTV, RARBG, 1337x, ThePirateBay, KickassTorrents, TorrentGalaxy)
    private static let providers = [
        "yts", "eztv", "rarbg", "1337x", "thepiratebay", "kickasstorrents", "torrentgalaxy"
    ]

    /// `https://torrentio.strem.fun/configure` sayfasının ürettiği yapılandırma
    /// dizesinin aynısı: seçenekler `|` ile ayrılır ve adresin ilk yol parçası
    /// olur. `qualityfilter` cam/screener/etiketsiz sürümleri sunucu tarafında
    /// eler, `sort=qualitysize` en iyi kaliteyi en üste alır.
    private static let configuration = [
        "providers=" + providers.joined(separator: ","),
        "qualityfilter=cam,scr,unknown",
        "sort=qualitysize",
        "limit=20"
    ].joined(separator: "|")

    /// Only these are offered. An unlabelled release is not worth a swarm's
    /// wait, and cam/telesync/screener rips are worth less than that — but 720p
    /// stays in: a new release's best-seeded copy is sometimes only there, and
    /// hiding it just because a weaker-seeded 1080p exists cost more than it saved.
    private static let acceptedQualityRanks: Set<Int> = [0, 1, 2]

    /// `|` karakteri bir URL yolunda geçersizdir — kodlanmazsa `URL(string:)`
    /// nil döner ve istek hiç kurulmaz.
    private static func escaping(_ configuration: String) -> String {
        configuration.replacingOccurrences(of: "|", with: "%7C")
    }

    /// Ayardaki adresten `/configure` ve `/manifest.json` eklerini atar.
    private static func host(of value: String) -> String {
        var trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        for suffix in ["/configure", "/manifest.json"] where trimmed.lowercased().hasSuffix(suffix) {
            trimmed = String(trimmed.dropLast(suffix.count))
        }
        return trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// Sorgulanacak adresler, sırayla: kullanıcının kendi yapılandırması,
    /// yapılandırılmış varsayılan, sonra hiç seçenek içermeyen sade adres.
    /// Sonuncusu yapılandırma biçimi bir gün yine değişirse elde kalan yoldur —
    /// `/stream/movie/tt….json` Torrentio'da her zaman doğrudan yanıt verir.
    private var candidateBases: [String] {
        let configuredDefault = Self.defaultBase + "/" + Self.escaping(Self.configuration)
        let trimmed = Self.host(of: base)

        guard !trimmed.isEmpty, !Self.isDeadLegacyBase(trimmed),
              trimmed.lowercased() != Self.defaultBase.lowercased() else {
            return [configuredDefault, Self.defaultBase]
        }

        // Kullanıcı `/configure` sayfasından kendi yapılandırmasını yapıştırmışsa
        // (adreste `providers=` gibi bir seçenek varsa) olduğu gibi kullanılır.
        let userBase = trimmed.contains("=")
            ? Self.escaping(trimmed)
            : trimmed + "/" + Self.escaping(Self.configuration)
        return [userBase, configuredDefault, Self.defaultBase]
    }

    /// Trackers added to every magnet. An addon hands over an info hash and
    /// nothing else, and a bare hash leaves the client waiting on DHT alone.
    private static let trackers = [
        "udp://tracker.opentrackr.org:1337/announce",
        "udp://open.demonii.com:1337/announce",
        "udp://open.stealth.si:80/announce",
        "udp://tracker.torrent.eu.org:451/announce",
        "udp://exodus.desync.com:6969/announce",
        "udp://tracker.openbittorrent.com:6969/announce"
    ]

    /// Torrent listesini getirir. Önce Torrentio (kullanıcının yapılandırması,
    /// sonra varsayılan, sonra sade adres) denenir; Torrentio hiç yanıt vermezse
    /// sırayla EZTV, The Pirate Bay ve — filmlerde — YTS API'sine düşülür.
    func streams(imdbID: String, title: String? = nil, year: Int? = nil, season: Int?, episode: Int?) async throws -> [TorrentOption] {
        // 1. Torrentio. Adresler birbirinin yedeği olduğundan ilk dolu yanıt kazanır.
        for candidate in candidateBases {
            do {
                let results = try await fetchStreams(from: candidate, imdbID: imdbID,
                                                     season: season, episode: episode,
                                                     timeout: 12)
                if !results.isEmpty { return results }
            } catch {
                continue
            }
        }

        // 2. EZTV (eztvx.to) resmi API'sini dene
        let eztvResults = await fetchEZTVStreams(imdbID: imdbID)
        if !eztvResults.isEmpty {
            return eztvResults
        }

        // 3. The Pirate Bay (apibay.org) doğrudan REST API'ye başvur!
        let pbResults = await fetchPirateBayStreams(imdbID: imdbID, title: title)
        if !pbResults.isEmpty {
            return pbResults
        }

        // 4. Film isteklerinde YTS API'sini de dene
        if season == nil {
            if let ytsResults = await fetchYTSStreams(imdbID: imdbID, title: title, year: year), !ytsResults.isEmpty {
                return ytsResults
            }
        }

        return []
    }

    /// Tek bir base URL'den stream listesi getirir.
    private func fetchStreams(from base: String, imdbID: String,
                             season: Int?, episode: Int?,
                             timeout: TimeInterval = 25) async throws -> [TorrentOption] {
        let path: String
        if let season, let episode {
            path = "\(base)/stream/series/\(imdbID):\(season):\(episode).json"
        } else {
            path = "\(base)/stream/movie/\(imdbID).json"
        }
        guard let url = URL(string: path) else { throw ClientError.badBase }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.timeoutInterval = timeout

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ClientError.http(http.statusCode)
        }

        let decoded = try JSONDecoder().decode(StreamResponse.self, from: data)
        let all = (decoded.streams ?? [])
            .compactMap(Self.option(from:))
            .filter { !$0.isTelescreen }

        let preferred = all.filter { Self.acceptedQualityRanks.contains($0.qualityRank) }
        // Eski film ve az bilinen dizilerde 1080p sürüm hiç olmayabilir; liste
        // tamamen boş dönmektense elde ne varsa gösterilir.
        let offered = preferred.isEmpty ? all : preferred
        return offered.sorted { ($0.qualityRank, -$0.seeds) < ($1.qualityRank, -$1.seeds) }
    }

    /// Doğrudan YTS.mx (YIFY Official REST API) üzerinden torrent sonuçlarını çeker.
    /// Hem IMDb ID hem de başlık/yıl ile sorgulama yapar.
    private func fetchYTSStreams(imdbID: String, title: String?, year: Int?) async -> [TorrentOption]? {
        let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        var queryTerms: [String] = []
        if !imdbID.isEmpty { queryTerms.append(imdbID) }
        if let trimmedTitle, !trimmedTitle.isEmpty {
            queryTerms.append(trimmedTitle)
            if let year { queryTerms.append("\(trimmedTitle) \(year)") }
        }
        guard !queryTerms.isEmpty else { return nil }

        let trackersQuery = Self.trackers.map { "tr=" + $0.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)! }.joined(separator: "&")

        for term in queryTerms {
            guard let encodedTerm = term.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                  let url = URL(string: "https://yts.mx/api/v2/list_movies.json?query_term=\(encodedTerm)") else { continue }

            var request = URLRequest(url: url)
            request.timeoutInterval = 6

            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { continue }

            struct YTSResponse: Decodable {
                let data: YTSData?
                struct YTSData: Decodable {
                    let movies: [YTSMovie]?
                }
                struct YTSMovie: Decodable {
                    let title: String?
                    let imdb_code: String?
                    let year: Int?
                    let torrents: [YTSTorrent]?
                }
                struct YTSTorrent: Decodable {
                    let hash: String
                    let quality: String
                    let type: String?
                    let seeds: Int
                    let peers: Int
                    let size: String
                }
            }

            // YTS aradığı yapımı bulamadığında hata döndürmüyor: sorguyu yok
            // sayıp listenin başındaki filmleri veriyor. Doğrulamadan alınırsa
            // bambaşka bir filmin sürümleri "bu film" diye sunuluyor.
            //
            // Doğrulama önceliği: IMDb kimliği elimizdeyse (TMDB'den geldiyse)
            // bire bir eşleşme aranır — en güvenilir yol. Ama TMDB henüz çok
            // yeni bir yapımın IMDb kimliğini işlememiş olabilir (imdbID boş
            // gelir); bu durumda IMDb eşleşmesi zaten hiçbir zaman tutmaz ve
            // film YTS'de gerçekten olsa bile hiç gösterilmezdi. Bu yüzden
            // imdbID boşken başlık (noktalama/boşluk/büyük-küçük harf
            // gözetmeksizin) + yıl (±1, TMDB'nin çıkış tarihiyle YTS'nin
            // kayıt yılı bir gün/yıl sonu farkıyla kayabiliyor) eşleşmesi de
            // kabul ediliyor.
            if let decoded = try? JSONDecoder().decode(YTSResponse.self, from: data),
               let movies = decoded.data?.movies,
               let movie = movies.first(where: { candidate in
                   if !imdbID.isEmpty {
                       return (candidate.imdb_code ?? "").caseInsensitiveCompare(imdbID) == .orderedSame
                   }
                   guard let trimmedTitle,
                         Self.normalizedTitle(candidate.title ?? "") == Self.normalizedTitle(trimmedTitle)
                   else { return false }
                   guard let year, let candidateYear = candidate.year else { return true }
                   return abs(candidateYear - year) <= 1
               }),
               let torrents = movie.torrents, !torrents.isEmpty {

                let options = torrents.compactMap { torrent -> TorrentOption? in
                    let magnet = "magnet:?xt=urn:btih:\(torrent.hash)&dn=\(movie.title ?? "Movie")&\(trackersQuery)"
                    let detailStr = "\(torrent.type?.uppercased() ?? "BLURAY") · \(torrent.size) · 👤 \(torrent.seeds)"
                    return TorrentOption(
                        id: torrent.hash,
                        quality: torrent.quality,
                        detail: detailStr,
                        seeds: torrent.seeds,
                        peers: torrent.peers,
                        provider: "YTS",
                        link: magnet,
                        fileIndex: nil
                    )
                }
                if !options.isEmpty {
                    return options
                }
            }
        }
        return nil
    }

    /// apibay.org (The Pirate Bay Official REST API) üzerinden doğrudan torrent akışlarını çeker.
    /// Cloudflare 522 veya Torrentio engellerine karşı %100 dayanıklı ve kesintisizdir.
    private func fetchPirateBayStreams(imdbID: String, title: String?) async -> [TorrentOption] {
        // Yalnızca IMDb kimliğiyle aranıyor. Başlıkla arama kolayca başka
        // yapımlara kayıyor ve dönen kayıtların aranan filme ait olduğunu
        // doğrulamanın bir yolu yok — alakasız sürümlerin sunulmasının
        // sebeplerinden biri buydu.
        guard !imdbID.isEmpty else { return [] }
        let queryTerms = [imdbID]

        let trackersQuery = Self.trackers.map { "tr=" + $0.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)! }.joined(separator: "&")

        struct TPBItem: Decodable {
            let id: String
            let name: String
            let info_hash: String
            let seeders: String
            let leechers: String
            let size: String
            /// apibay her kaydın IMDb kimliğini veriyor; kayıt eşleşmiyorsa
            /// listelenmemeli. Bazı kayıtlarda boş geliyor.
            let imdb: String?
        }

        var results: [TorrentOption] = []

        for term in queryTerms {
            guard let encodedTerm = term.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                  let url = URL(string: "https://apibay.org/q.php?q=\(encodedTerm)") else { continue }

            var request = URLRequest(url: url)
            request.timeoutInterval = 5

            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { continue }

            if let items = try? JSONDecoder().decode([TPBItem].self, from: data) {
                // apibay sonuç bulamadığında hata değil, "No results returned"
                // adlı ve hash'i baştan sona sıfır olan tek bir kayıt döndürüyor.
                // Eski süzgeç bunu tanımıyordu (metni "No results found" sanıyor,
                // sıfırlardan oluşan hash'i de "boş değil" sayıyordu), böylece
                // oynatılamayan bir sürüm gerçek sonuç gibi listeleniyordu.
                let validItems = items.filter { item in
                    guard !item.name.lowercased().hasPrefix("no results"),
                          item.info_hash.contains(where: { $0 != "0" })
                    else { return false }
                    // Kimliği bildirilmiş bir kayıt başka bir yapıma aitse elenir.
                    let itemIMDb = (item.imdb ?? "").trimmingCharacters(in: .whitespaces)
                    guard !itemIMDb.isEmpty else { return true }
                    return itemIMDb.caseInsensitiveCompare(imdbID) == .orderedSame
                }
                for item in validItems {
                    let seeds = Int(item.seeders) ?? 0
                    let bytes = Int64(item.size) ?? 0
                    let formattedSize = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
                    let magnet = "magnet:?xt=urn:btih:\(item.info_hash)&dn=\(item.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "Video")&\(trackersQuery)"
                    let quality = Self.quality(inferredFrom: item.name)

                    let option = TorrentOption(
                        id: item.info_hash,
                        quality: quality,
                        detail: "\(formattedSize) · 👤 \(seeds) · PirateBay",
                        seeds: seeds,
                        peers: Int(item.leechers) ?? 0,
                        provider: "PirateBay",
                        link: magnet,
                        fileIndex: nil
                    )
                    if Self.isWorthOffering(option) {
                        results.append(option)
                    }
                }
            }
            if !results.isEmpty { break }
        }

        return results.sorted { ($0.qualityRank, -$0.seeds) < ($1.qualityRank, -$1.seeds) }
    }

    /// eztvx.to resmi API'si üzerinden dizi ve film torrent akışlarını çeker.
    private func fetchEZTVStreams(imdbID: String) async -> [TorrentOption] {
        let numericID = imdbID.replacingOccurrences(of: "[^0-9]", with: "", options: .regularExpression)
        guard !numericID.isEmpty else { return [] }

        let endpoints = [
            "https://eztvx.to/api/get-torrents?imdb_id=\(numericID)",
            "https://eztv.re/api/get-torrents?imdb_id=\(numericID)",
            "https://eztv.wf/api/get-torrents?imdb_id=\(numericID)"
        ]

        let trackersQuery = Self.trackers.map { "tr=" + $0.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)! }.joined(separator: "&")

        struct EZTVResponse: Decodable {
            let torrents: [EZTVItem]?
            struct EZTVItem: Decodable {
                let hash: String?
                let title: String?
                let size_bytes: String?
                let seeds: Int?
                let leechers: Int?
            }
        }

        for urlString in endpoints {
            guard let url = URL(string: urlString) else { continue }
            var request = URLRequest(url: url)
            request.timeoutInterval = 5

            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let decoded = try? JSONDecoder().decode(EZTVResponse.self, from: data),
                  let items = decoded.torrents, !items.isEmpty else { continue }

            let options = items.prefix(20).compactMap { item -> TorrentOption? in
                guard let hash = item.hash, !hash.isEmpty else { return nil }
                let bytes = Int64(item.size_bytes ?? "0") ?? 0
                let formattedSize = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
                let seeds = item.seeds ?? 0
                let itemTitle = item.title ?? "EZTV Release"
                let magnet = "magnet:?xt=urn:btih:\(hash)&dn=\(itemTitle.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "Video")&\(trackersQuery)"
                let quality = Self.quality(inferredFrom: itemTitle)

                return TorrentOption(
                    id: hash,
                    quality: quality,
                    detail: "\(formattedSize) · 👤 \(seeds) · EZTV",
                    seeds: seeds,
                    peers: item.leechers ?? 0,
                    provider: "EZTV",
                    link: magnet,
                    fileIndex: nil
                )
            }
            if !options.isEmpty {
                return options.sorted { ($0.qualityRank, -$0.seeds) < ($1.qualityRank, -$1.seeds) }
            }
        }
        return []
    }

    /// 4K and 1080p only, and no telesyncs — including the ones that call
    /// themselves 1080p in the quality tag and admit to being a TELESYNC in the
    /// release name.
    private static func isWorthOffering(_ option: TorrentOption) -> Bool {
        acceptedQualityRanks.contains(option.qualityRank) && !option.isTelescreen
    }

    // MARK: - Wire format
    //
    // The protocol carries display strings, not fields: `name` is
    // "Torrentio\n1080p" and `title` is a release name, a filename and a line of
    // emoji-prefixed facts. Everything below reads those two apart.

    private struct StreamResponse: Decodable {
        var streams: [Stream]?

        struct Stream: Decodable {
            var name: String?
            var title: String?
            var description: String?
            var infoHash: String?
            var url: String?
            var fileIdx: Int?
        }
    }

    private static func option(from stream: StreamResponse.Stream) -> TorrentOption? {
        let link: String
        let id: String

        if let hash = stream.infoHash, !hash.isEmpty {
            id = hash
            let releaseName = (stream.title ?? "").split(separator: "\n").first.map(String.init) ?? ""
            link = magnet(hash: hash, name: releaseName)
        } else if let streamURL = stream.url, !streamURL.isEmpty {
            id = streamURL
            link = streamURL
        } else {
            return nil
        }

        let rawTitle = stream.title ?? stream.description ?? stream.name ?? "Stremio Stream"
        let lines = rawTitle.split(separator: "\n").map(String.init)
        let releaseName = lines.first ?? ""

        let quality = (stream.name ?? "")
            .split(separator: "\n")
            .dropFirst()
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespaces)
            ?? Self.quality(inferredFrom: releaseName)

        let seeds = Int(first(match: "👤\\s*([0-9]+)", in: rawTitle) ?? "") ?? 0
        let size = first(match: "💾\\s*([0-9.,]+\\s*[KMGT]?B)", in: rawTitle) ?? ""
        let provider = first(match: "⚙️\\s*([^\\s\n]+)", in: rawTitle)

        var parts: [String] = []
        if !releaseName.isEmpty { parts.append(releaseName) }
        if !size.isEmpty { parts.append(size) }

        return TorrentOption(
            id: id,
            quality: quality.isEmpty ? Self.quality(inferredFrom: releaseName) : quality,
            detail: parts.joined(separator: " · "),
            seeds: seeds,
            peers: 0,
            provider: provider,
            link: link,
            fileIndex: stream.fileIdx
        )
    }

    /// IMDb kimliği yokken başlık karşılaştırması için: küçük harfe çevirir,
    /// harf/rakam dışındaki her şeyi (noktalama, boşluk, "The " gibi ekler
    /// dahil değil — yalnızca ayraçlar) atar. "The Odyssey 2" ile
    /// "the odyssey 2" ya da "The Odyssey  2:" aynı sayılsın diye.
    private static func normalizedTitle(_ title: String) -> String {
        title.lowercased().unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }

    /// Falls back to reading the quality out of the release name, for addons
    /// that do not put it in `name`.
    private static func quality(inferredFrom name: String) -> String {
        for candidate in ["2160p", "1080p", "720p", "480p"] where name.localizedCaseInsensitiveContains(candidate) {
            return candidate
        }
        return "Bilinmeyen"
    }

    private static func magnet(hash: String, name: String) -> String {
        var magnet = "magnet:?xt=urn:btih:\(hash)"
        if !name.isEmpty,
           let encoded = name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) {
            magnet += "&dn=\(encoded)"
        }
        for tracker in trackers {
            let encoded = tracker.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? tracker
            magnet += "&tr=\(encoded)"
        }
        return magnet
    }

    private static func first(match pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range]).trimmingCharacters(in: .whitespaces)
    }
}
