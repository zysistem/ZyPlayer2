import Foundation

/// Dizipal — a Turkish series-first streaming site, shown in the app as
/// "ZySeries".
///
/// Two things set it apart from `HdFilmCehennemiProvider`:
///
///   1. **The player is not in the page.** A watch page only carries a
///      `data-cfg` hash; the embed URL comes back from a POST to
///      `/ajax-player-config`, and only when that POST rides the same session
///      that was served the page. So both the page and the POST go through the
///      site's one warmed `WebFetcher`.
///   2. **No IMDb id anywhere.** `details` returns `imdbID: nil`, which sends
///      `StreamDetailLoader` down its title-search path for the TMDB match —
///      matching by name is the only option here.
///
/// The domain moves constantly (the site itself announces the next one in a
/// banner), which is exactly what the editable base URL in Settings is for.
struct DizipalProvider: StreamProvider {
    static let defaultBaseURL = "https://dizipal2108.com"

    let id = "dizipal"
    let displayName = "ZySeries"
    let kind: StreamKind = .series
    /// Injected from settings so the domain can be changed when the site moves.
    var baseURL: String

    init(baseURL: String = DizipalProvider.defaultBaseURL) {
        self.baseURL = baseURL
    }

    @MainActor
    private func load(_ url: String) async throws -> String {
        try await WebFetcherPool.fetcher(for: baseURL).text(url)
    }

    // MARK: - Search

    func search(_ query: String) async throws -> [StreamHit] {
        let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let html = try await load("\(baseURL)/arama?q=\(q)")
        return Self.hits(fromCards: html, providerID: id, providerName: displayName,
                         absolutize: absolute, decode: decodeEntities)
    }

    // MARK: - Discover (landing rows)

    func discover() async throws -> [StreamShelf] {
        // Ten of each, the two rows the site's own menu leads with.
        async let films = shelf(title: "ZySeries · Son Filmler", path: "/filmler", limit: 10)
        async let series = shelf(title: "ZySeries · Son Diziler", path: "/diziler", limit: 10)
        return await [films, series].filter { !$0.hits.isEmpty }
    }

    private func shelf(title: String, path: String, limit: Int) async -> StreamShelf {
        let html = (try? await load(baseURL + path)) ?? ""
        let hits = Self.hits(fromCards: html, providerID: id, providerName: displayName,
                             absolutize: absolute, decode: decodeEntities)
        return StreamShelf(title: title, hits: Array(hits.prefix(limit)))
    }

    /// Both the listing grids (`<li class="content-card">`) and the search page
    /// (`<article class="content-card">`) use the same card markup, so one split on
    /// the class name feeds every screen. The kind comes from the href — `/dizi/`
    /// or `/film/` — rather than the badge text, which is styled markup.
    private static func hits(fromCards html: String, providerID: String, providerName: String,
                             absolutize: (String) -> String, decode: (String) -> String) -> [StreamHit] {
        var seen = Set<String>()
        return html.components(separatedBy: "content-card").dropFirst().compactMap { fragment in
            // Stop at the card's end so a regex can't reach into the next one.
            let card = fragment.components(separatedBy: "</a>").first ?? fragment
            guard let href = match("href=\"([^\"]+/(?:dizi|film)/[^\"]+)\"", in: card) else { return nil }
            let url = absolutize(href)
            guard seen.insert(url).inserted else { return nil }

            let title = match("class=\"card-title\"[^>]*>([^<]+)<", in: card)
                ?? match("<img[^>]+alt=\"([^\"]+)\"", in: card)
            guard let title, !title.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }

            // Posters are lazy-loaded: the real URL is on `data-src`, and `src`
            // holds a base64 placeholder pixel.
            let poster = match("data-src=\"(https?://[^\"]+)\"", in: card)
            let year = match("class=\"card-year\"[^>]*>\\s*(\\d{4})", in: card).flatMap(Int.init)

            return StreamHit(
                providerID: providerID,
                providerName: providerName,
                kind: url.contains("/dizi/") ? .series : .movie,
                title: decode(title).replacingOccurrences(of: " izle", with: ""),
                year: year,
                posterURL: poster.flatMap { URL(string: $0) },
                pageURL: url
            )
        }
    }

    /// Free function so the card parser can stay `static` (it runs off one HTML
    /// blob and needs nothing from the instance but `absolute`/`decodeEntities`).
    private static func match(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let m = regex.firstMatch(in: text, range: range), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Details

    func details(_ hit: StreamHit) async throws -> StreamDetails {
        let html = try await load(hit.pageURL)
        let title = firstMatch("<h1[^>]*>([^<]+)</h1>", in: html).map(decodeEntities) ?? hit.title
        let overview = firstMatch("<meta[^>]+name=\"description\"[^>]+content=\"([^\"]+)\"", in: html)
            .map(decodeEntities)

        var hit = hit
        hit.title = title

        let episodes = Self.parseEpisodes(html: html, absolutize: absolute)
        // No IMDb id on this site — the TMDB match has to come from the title.
        if episodes.isEmpty {
            return StreamDetails(hit: hit, overview: overview, imdbID: nil,
                                 episodes: [], moviePageURL: hit.pageURL)
        }
        return StreamDetails(hit: hit, overview: overview, imdbID: nil,
                             episodes: episodes, moviePageURL: nil)
    }

    /// Episode links are `/bolum/{slug}-{season}-sezon-{episode}-bolum`, so the
    /// numbers come from the URL rather than the row's label markup.
    /// Thumbnails are scraped from the `img` tag in each episode's list row.
    private static func parseEpisodes(html: String, absolutize: (String) -> String) -> [StreamEpisode] {
        guard let regex = try? NSRegularExpression(
            pattern: "href=\"([^\"]*/bolum/[^\"]*?-(\\d+)-sezon-(\\d+)-bolum/?)\"",
            options: [.caseInsensitive]
        ) else { return [] }

        // Also build a thumbnail map: look for episode-card/episode-item blocks
        // and extract img src alongside the href.
        let thumbRegex = try? NSRegularExpression(
            pattern: "href=\"([^\"]*/bolum/[^\"]+?)\"|data-src=\"(https?://[^\"]+)\"|src=\"(https?://[^\",]+\\.(?:jpe?g|png|webp)[^\"]*)\"",
            options: [.caseInsensitive]
        )

        // Build href -> thumbnail map by scanning episode blocks
        var thumbMap: [String: URL] = [:]
        if let thumbRegex {
            // Split on common episode-list item delimiters
            for block in html.components(separatedBy: "episode-item").dropFirst() +
                          html.components(separatedBy: "bolum-item").dropFirst() {
                let ns = block as NSString
                let fullRange = NSRange(location: 0, length: min(ns.length, 800))
                var href: String?
                var thumb: URL?
                for m in thumbRegex.matches(in: block, range: fullRange) {
                    if m.range(at: 1).location != NSNotFound,
                       let r = Range(m.range(at: 1), in: block) {
                        href = String(block[r])
                    } else if m.range(at: 2).location != NSNotFound,
                              let r = Range(m.range(at: 2), in: block),
                              thumb == nil {
                        thumb = URL(string: String(block[r]))
                    } else if m.range(at: 3).location != NSNotFound,
                              let r = Range(m.range(at: 3), in: block),
                              thumb == nil {
                        thumb = URL(string: String(block[r]))
                    }
                }
                if let href, let thumb { thumbMap[absolutize(href)] = thumb }
            }
        }

        let ns = html as NSString
        var seen = Set<String>()
        var episodes: [StreamEpisode] = []
        for m in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let href = ns.substring(with: m.range(at: 1))
            guard seen.insert(href).inserted else { continue }
            let absURL = absolutize(href)
            episodes.append(StreamEpisode(
                season: Int(ns.substring(with: m.range(at: 2))) ?? 1,
                episode: Int(ns.substring(with: m.range(at: 3))) ?? 0,
                title: nil,
                thumbnailURL: thumbMap[absURL],
                pageURL: absURL
            ))
        }
        return episodes.sorted { ($0.season, $0.episode) < ($1.season, $1.episode) }
    }

    // MARK: - Embeds

    /// A film or episode page carries only a `data-cfg` hash; the embed comes from
    /// `/ajax-player-config`, which answers `{"success":true,"config":{"v":…,"t":…}}`.
    /// A series landing page has no `data-cfg` at all, so it throws `.noEmbed` and
    /// the store falls through to the episode list — the same shape
    /// `HdFilmCehennemiProvider` relies on.
    func embeds(forPage pageURL: String) async throws -> [StreamEmbed] {
        let html = try await load(pageURL)
        guard let cfg = firstMatch("data-cfg=\"([^\"]+)\"", in: html) else { throw StreamError.noEmbed }

        let raw = try await WebFetcherPool.fetcher(for: baseURL)
            .post("\(baseURL)/ajax-player-config", form: ["cfg": cfg])
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let config = object["config"] as? [String: Any],
              let value = config["v"] as? String, !value.isEmpty else { throw StreamError.noEmbed }

        // `v` is normally the embed URL outright; when the site returns a whole
        // iframe tag instead, the src is what we want out of it.
        let url = value.contains("<iframe")
            ? (firstMatch("src=\"([^\"]+)\"", in: value) ?? "")
            : value
        guard !url.isEmpty else { throw StreamError.noEmbed }

        return [StreamEmbed(url: absolute(url), referer: pageURL, label: displayName)]
    }
}
