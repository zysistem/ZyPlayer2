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

    static let defaultBase = "https://torrentio.strem.fun"

    /// Bölge engellemesini aşmak için otomatik olarak denenen yedek public
    /// Torrentio instance'ları. Kullanıcı kendi adresini girdiyse bu liste
    /// atlanır; yalnızca varsayılan adres kullanılıyorken devreye girer.
    /// Bölge engellemesini aşmak için otomatik olarak denenen yedek public
    /// Torrentio ve alternatif Stremio torrent mirror'ları. Kullanıcı kendi
    /// adresini girdiyse bu liste atlanır.
    private static let fallbackMirrors = [
        "https://torrentio.strem.fun",
        "https://stremio.torrentio.strem.fun",
        "https://torrentio.stremio.strem.fun",
        "https://torrentio.elfhosted.com",
        "https://torrentio.superstrem.io",
        "https://torrentio.run"
    ]

    /// Trackers to search, in the addon's own configuration syntax. Its full set
    /// includes regional and anime-only indexes whose releases are noise here.
    private static let providers = [
        "eztv", "thepiratebay", "torrentgalaxy", "yts", "rarbg", "1337x"
    ]

    /// Only these are offered. A 720p or an unlabelled release is not worth a
    /// swarm's wait, and cam/telesync/screener rips are worth less than that.
    private static let acceptedQualityRanks: Set<Int> = [0, 1]

    /// The base with the provider selection appended.
    ///
    /// An address copied from the addon's own `/configure` page already carries
    /// its settings in the path, so that is left untouched — it is how someone
    /// can pick a different set without a code change.
    private var configuredBase: String {
        var trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        for suffix in ["/configure", "/manifest.json"] where trimmed.hasSuffix(suffix) {
            trimmed = String(trimmed.dropLast(suffix.count))
        }
        if trimmed.contains("=") { return trimmed }
        return trimmed + "/providers=" + Self.providers.joined(separator: ",")
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

    /// Verilen temel adres için torrent listesi getirir. Bölge engellemesini
    /// aşmak için birden fazla public instance sırayla denenir; ilk başarılı
    /// yanıt döner. Eğer tüm mirror'lar başarısız olursa doğrudan YTS API'ye
    /// (YIFY Official API) başvurur.
    func streams(imdbID: String, season: Int?, episode: Int?) async throws -> [TorrentOption] {
        // Kullanıcı kendi adresini girdiyse doğrudan kullan — yedek instance
        // listesini pas geç.
        let trimmedBase = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let isCustomBase = !trimmedBase.isEmpty
            && trimmedBase.lowercased() != Self.defaultBase.lowercased()

        if isCustomBase {
            return try await fetchStreams(from: configuredBase, imdbID: imdbID,
                                         season: season, episode: episode)
        }

        // Varsayılan adres için bölge engeline karşı yedek instance'ları dene.
        let providerConfig = "/providers=" + Self.providers.joined(separator: ",")
        var lastError: Error = ClientError.badBase

        for mirror in Self.fallbackMirrors {
            let mirrorBase = mirror.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let fullBase = mirrorBase + providerConfig

            do {
                let results = try await fetchStreams(from: fullBase, imdbID: imdbID,
                                                    season: season, episode: episode,
                                                    timeout: 8)
                if !results.isEmpty {
                    return results
                }
            } catch {
                lastError = error
                continue
            }
        }

        // Torrentio mirror'ları açılmıyorsa ve istek bir filme aitse, YTS.mx resmi API'sinden çek
        if season == nil {
            if let ytsResults = try? await fetchYTSStreams(imdbID: imdbID), !ytsResults.isEmpty {
                return ytsResults
            }
        }

        throw lastError
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
        return (decoded.streams ?? [])
            .compactMap(Self.option(from:))
            .filter(Self.isWorthOffering)
            .sorted { ($0.qualityRank, -$0.seeds) < ($1.qualityRank, -$1.seeds) }
    }

    /// Doğrudan YTS.mx (YIFY Official REST API) üzerinden torrent sonuçlarını çeker.
    private func fetchYTSStreams(imdbID: String) async throws -> [TorrentOption] {
        guard let url = URL(string: "https://yts.mx/api/v2/list_movies.json?query_term=\(imdbID)") else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return [] }

        struct YTSResponse: Decodable {
            let data: YTSData?
            struct YTSData: Decodable {
                let movies: [YTSMovie]?
            }
            struct YTSMovie: Decodable {
                let title: String?
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

        guard let decoded = try? JSONDecoder().decode(YTSResponse.self, from: data),
              let movies = decoded.data?.movies,
              let movie = movies.first,
              let torrents = movie.torrents else { return [] }

        let trackersQuery = Self.trackers.map { "tr=" + $0.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)! }.joined(separator: "&")

        return torrents.compactMap { torrent -> TorrentOption? in
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
            var infoHash: String?
            var fileIdx: Int?
        }
    }

    private static func option(from stream: StreamResponse.Stream) -> TorrentOption? {
        guard let hash = stream.infoHash, !hash.isEmpty else { return nil }

        let title = stream.title ?? ""
        let lines = title.split(separator: "\n").map(String.init)
        let releaseName = lines.first ?? ""

        let quality = (stream.name ?? "")
            .split(separator: "\n")
            .dropFirst()
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespaces)
            ?? Self.quality(inferredFrom: releaseName)

        let seeds = Int(first(match: "👤\\s*([0-9]+)", in: title) ?? "") ?? 0
        let size = first(match: "💾\\s*([0-9.,]+\\s*[KMGT]?B)", in: title) ?? ""
        let provider = first(match: "⚙️\\s*([^\\s\n]+)", in: title)

        var parts: [String] = []
        if !releaseName.isEmpty { parts.append(releaseName) }
        if !size.isEmpty { parts.append(size) }

        return TorrentOption(
            id: hash,
            quality: quality.isEmpty ? Self.quality(inferredFrom: releaseName) : quality,
            detail: parts.joined(separator: " · "),
            seeds: seeds,
            // The protocol reports watchers, not leechers; there is no peer count.
            peers: 0,
            provider: provider,
            link: magnet(hash: hash, name: releaseName),
            fileIndex: stream.fileIdx
        )
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
