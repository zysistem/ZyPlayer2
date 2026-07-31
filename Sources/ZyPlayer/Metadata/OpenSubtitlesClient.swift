import Foundation

/// Searches and downloads subtitles from opensubtitles.com (REST API v1).
struct OpenSubtitlesClient {

    enum ClientError: LocalizedError {
        case missingKey
        case http(Int, String)
        case noDownloadLink
        case quotaExhausted

        var errorDescription: String? {
            switch self {
            case .missingKey:
                "OpenSubtitles API anahtarı girilmemiş."
            case .quotaExhausted:
                "Günlük indirme kotanız dolmuş."
            case .noDownloadLink:
                "Altyazı bağlantısı alınamadı."
            case .http(let code, let body):
                "OpenSubtitles hatası (\(code)): \(body.prefix(120))"
            }
        }
    }

    var apiKey: String
    /// Comma-separated ISO codes, e.g. "tr,en".
    var languages: String = "tr,en"

    private static let base = URL(string: "https://api.opensubtitles.com/api/v1")!
    /// The API rejects requests without a descriptive User-Agent.
    private static let userAgent = "ZyPlayer v0.1"

    struct Subtitle: Identifiable, Hashable {
        var id: String            // file id, used for download
        var language: String
        var releaseName: String
        var downloadCount: Int
        var isHearingImpaired: Bool
        var rating: Double
        var uploader: String?
        /// The uploaded file's own name, shown when it says something the
        /// release name does not.
        var fileName: String?
        /// Frame rate the subtitle was timed to — the usual reason a subtitle
        /// drifts against an otherwise matching release.
        var fps: Double?
        /// OpenSubtitles matched this against the hash of the playing file, so
        /// it is the right version regardless of what the name says.
        var matchesFile: Bool = false

        var languageName: String {
            let locale = Locale(identifier: "tr")
            return locale.localizedString(forLanguageCode: language)?.capitalized
                ?? language.uppercased()
        }
    }

    // MARK: - Search

    /// Searches for a title, narrowing to a season/episode where given.
    ///
    /// An IMDb id beats the free-text `query`, which matches loosely enough to
    /// return another film's subtitles. The file hash does not narrow anything —
    /// it makes the API flag the entries that were timed against exactly this
    /// file, which is the only trustworthy answer to "does this version fit?".
    func search(query: String,
                season: Int? = nil,
                episode: Int? = nil,
                imdbID: String? = nil,
                hash: (hash: String, size: Int64)? = nil) async throws -> [Subtitle] {
        guard !apiKey.isEmpty else { throw ClientError.missingKey }

        var components = URLComponents(url: Self.base.appendingPathComponent("subtitles"),
                                       resolvingAgainstBaseURL: false)!
        var items: [URLQueryItem] = [
            .init(name: "languages", value: languages),
            .init(name: "order_by", value: "download_count"),
            .init(name: "order_direction", value: "desc")
        ]

        // The API wants a bare number: `tt0133093` earns a 301 to `133093`, and
        // URLSession follows it having dropped the Api-Key header.
        let numericID = imdbID
            .map { String($0.filter(\.isNumber).drop { $0 == "0" }) }
            .flatMap { $0.isEmpty ? nil : $0 }

        if let numericID {
            // For an episode the id in hand is the show's, which is what
            // `parent_imdb_id` expects alongside the two numbers.
            let key = (season != nil && episode != nil) ? "parent_imdb_id" : "imdb_id"
            items.append(.init(name: key, value: numericID))
        } else {
            items.append(.init(name: "query", value: query))
        }
        if let season { items.append(.init(name: "season_number", value: String(season))) }
        if let episode { items.append(.init(name: "episode_number", value: String(episode))) }
        if let hash { items.append(.init(name: "moviehash", value: hash.hash)) }
        // The API enforces a canonical parameter order: anything else earns a
        // 301 to the sorted form, and the redirect is a second round trip that
        // only happens to keep the Api-Key header.
        components.queryItems = items.sorted { $0.name < $1.name }

        let data = try await get(components.url!)

        struct Response: Decodable {
            struct Item: Decodable {
                struct Attributes: Decodable {
                    struct File: Decodable {
                        var file_id: Int?
                        var file_name: String?
                    }
                    var language: String?
                    var release: String?
                    var download_count: Int?
                    var hearing_impaired: Bool?
                    var ratings: Double?
                    var uploader: Uploader?
                    var files: [File]?
                    var fps: Double?
                    var moviehash_match: Bool?
                }
                struct Uploader: Decodable { var name: String? }
                var attributes: Attributes?
            }
            var data: [Item]?
        }

        let decoded = try JSONDecoder().decode(Response.self, from: data)
        let subtitles = (decoded.data ?? []).compactMap { item -> Subtitle? in
            guard let attributes = item.attributes,
                  let file = attributes.files?.first,
                  let fileID = file.file_id else { return nil }
            let release = attributes.release ?? file.file_name ?? "Altyazı"
            return Subtitle(
                id: String(fileID),
                language: attributes.language ?? "?",
                releaseName: release,
                downloadCount: attributes.download_count ?? 0,
                isHearingImpaired: attributes.hearing_impaired ?? false,
                rating: attributes.ratings ?? 0,
                uploader: attributes.uploader?.name,
                fileName: file.file_name == release ? nil : file.file_name,
                fps: attributes.fps,
                matchesFile: attributes.moviehash_match ?? false
            )
        }
        // Hash matches to the top; the API orders by download count only. Split
        // rather than sorted(by:), which is not stable and would scramble the
        // download-count order inside each group.
        return subtitles.filter(\.matchesFile) + subtitles.filter { !$0.matchesFile }
    }

    // MARK: - Download

    /// Resolves a download link and writes the subtitle next to the cache.
    func download(_ subtitle: Subtitle) async throws -> URL {
        guard !apiKey.isEmpty else { throw ClientError.missingKey }

        var request = URLRequest(url: Self.base.appendingPathComponent("download"))
        request.httpMethod = "POST"
        applyHeaders(to: &request)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: ["file_id": Int(subtitle.id) ?? 0]
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            if http.statusCode == 406 { throw ClientError.quotaExhausted }
            throw ClientError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }

        struct DownloadResponse: Decodable {
            var link: String?
            var file_name: String?
        }
        let decoded = try JSONDecoder().decode(DownloadResponse.self, from: data)
        guard let link = decoded.link, let linkURL = URL(string: link) else {
            throw ClientError.noDownloadLink
        }

        let (fileData, _) = try await URLSession.shared.data(from: linkURL)
        let name = decoded.file_name ?? "\(subtitle.id).srt"
        let destination = AppPaths.subtitleDirectory
            .appendingPathComponent(sanitize(name))
        try fileData.write(to: destination, options: .atomic)
        return destination
    }

    // MARK: - Plumbing

    private func get(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        applyHeaders(to: &request)
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ClientError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    private func applyHeaders(to request: inout URLRequest) {
        request.setValue(apiKey, forHTTPHeaderField: "Api-Key")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 25
    }

    private func sanitize(_ name: String) -> String {
        name.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
    }
}
