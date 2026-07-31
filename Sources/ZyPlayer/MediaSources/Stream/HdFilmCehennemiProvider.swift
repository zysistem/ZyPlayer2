import Foundation

/// HdFilmCehennemi — a Turkish film (and some series) streaming site.
///
/// The site sits behind Cloudflare and answers its search endpoint with
/// HTML-typed JSON, so both go through `WebFetcher` (a warmed, hidden web view)
/// via an in-page `fetch`, which returns the raw body. The video itself is not
/// unpacked here: the film page carries a lazy `data-src` iframe pointing at the
/// player embed, and handing *that* to `StreamResolver` lets its player run and
/// be caught fetching the HLS manifest.
struct HdFilmCehennemiProvider: StreamProvider {
    static let defaultBaseURL = "https://www.hdfilmcehennemi.nl"

    let id = "hdfilmcehennemi"
    let displayName = "HdFilmCehennemi"
    let kind: StreamKind = .movie
    /// Injected from settings so the domain can be changed when the site moves.
    var baseURL: String

    init(baseURL: String = HdFilmCehennemiProvider.defaultBaseURL) {
        self.baseURL = baseURL
    }

    @MainActor
    private func load(_ url: String, headers: [String: String] = [:]) async throws -> String {
        try await WebFetcherPool.fetcher(for: baseURL).text(url, headers: headers)
    }

    // MARK: - Search

    func search(_ query: String) async throws -> [StreamHit] {
        let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        // Same-origin fetch of the site's search API. Returns
        // `{ "results": ["<a href=…><img …><h4 …>", …] }`.
        let raw = try await load("\(baseURL)/search?q=\(q)",
                                 headers: ["X-Requested-With": "fetch"])

        return Self.resultFragments(fromJSON: raw).compactMap { fragment in
            guard let href = firstMatch("<a[^>]+href=\"([^\"]+)\"", in: fragment) else { return nil }
            // The title is on the poster's `alt`; the `h4` is a good fallback.
            let title = firstMatch("<img[^>]+alt=\"([^\"]+)\"", in: fragment)
                ?? firstMatch("<h4[^>]*>([^<]+)</h4>", in: fragment)
                ?? ""
            // Bigger artwork lives under /list/; search returns /thumb/.
            let poster = (firstMatch("<img[^>]+src=\"([^\"]+)\"", in: fragment)
                          ?? firstMatch("data-src=\"([^\"]+)\"", in: fragment))?
                .replacingOccurrences(of: "/thumb/", with: "/list/")
            let year = firstMatch("class=\"year\"[^>]*>(\\d{4})", in: fragment).flatMap(Int.init)

            guard !title.isEmpty else { return nil }
            return StreamHit(
                providerID: id,
                providerName: displayName,
                kind: .movie,
                title: decodeEntities(title),
                year: year,
                posterURL: poster.flatMap { URL(string: absolute($0)) },
                pageURL: absolute(href)
            )
        }
    }

    /// Pulls the `results` array out of the search JSON. Falls back to walking
    /// every string value in case the key is ever renamed.
    private static func resultFragments(fromJSON raw: String) -> [String] {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else { return [] }
        if let dict = object as? [String: Any],
           let results = dict["results"] as? [String] {
            return results
        }
        var out: [String] = []
        func walk(_ value: Any) {
            switch value {
            case let s as String where s.contains("<a ") && s.contains("href"):
                out.append(s)
            case let array as [Any]: array.forEach(walk)
            case let dict as [String: Any]: dict.values.forEach(walk)
            default: break
            }
        }
        walk(object)
        return out
    }

    // MARK: - Discover (landing page)

    func discover() async throws -> [StreamShelf] {
        // Films: the category grid, newest first. Series: only the "Son Eklenen
        // Yabancı Dizi Bölümleri" section (recently added episodes), never the
        // "Yakında Gelecek" (upcoming) rows, which are not playable.
        // Ten each — one full row per shelf, matching ZySeries.
        async let films = shelf(
            title: "Son Eklenen Filmler", path: "/category/film-izle-2/",
            section: nil, selector: "a.poster", kind: .movie, limit: 10
        )
        async let series = shelf(
            title: "Son Eklenen Bölümler", path: "/yabancidiziizle-5/",
            section: "Son Eklenen Yabancı Dizi Bölümleri", selector: "a.mini-poster",
            kind: .series, limit: 10
        )
        return await [films, series].filter { !$0.hits.isEmpty }
    }

    @MainActor
    private func shelf(title: String, path: String, section: String?, selector: String,
                       kind: StreamKind, limit: Int) async -> StreamShelf {
        let js = Self.extractionJS(sectionTitle: section, selector: selector)
        let raw = (try? await StreamPageRenderer().render(baseURL + path, extractionJS: js)) as? String ?? "[]"
        let hits = Self.hits(fromCardsJSON: raw, kind: kind, providerID: id, providerName: displayName)
        return StreamShelf(title: title, hits: Array(hits.prefix(limit)))
    }

    /// Extraction script for lazy-loaded cards. Scrolls once to force the posters
    /// in, then reads each card's rendered image URL and title (from `title` or the
    /// image `alt`). When `sectionTitle` is given, only the section whose header
    /// contains it is read — so "Son Eklenen Yabancı Dizi Bölümleri" is taken and
    /// "Yakında Gelecek Yabancı Diziler" is left out.
    private static func extractionJS(sectionTitle: String?, selector: String) -> String {
        let sectionLiteral = sectionTitle.map { "\"\($0)\"" } ?? "null"
        return """
        window.scrollTo(0, document.body.scrollHeight);
        await new Promise(function (r) { setTimeout(r, 1400); });
        function map(cards) {
          return Array.from(cards).map(function (a) {
            var img = a.querySelector('img');
            return { href: a.href,
                     title: (a.getAttribute('title') || (img && img.getAttribute('alt')) || '').trim(),
                     poster: (img && (img.currentSrc || img.src)) || '' };
          }).filter(function (x) { return x.href && x.poster && x.poster.indexOf('data:') !== 0; });
        }
        var section = \(sectionLiteral);
        if (section) {
          var secs = document.querySelectorAll('section, .common-section');
          for (var i = 0; i < secs.length; i++) {
            var h = secs[i].querySelector('h1, h2, .section-title');
            if (h && h.textContent.indexOf(section) > -1) {
              return JSON.stringify(map(secs[i].querySelectorAll('\(selector)')));
            }
          }
          return '[]';
        }
        return JSON.stringify(map(document.querySelectorAll('\(selector)')));
        """
    }

    private static func hits(fromCardsJSON json: String, kind: StreamKind,
                             providerID: String, providerName: String) -> [StreamHit] {
        guard let data = json.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] else { return [] }
        var seen = Set<String>()
        return array.compactMap { card in
            guard let href = card["href"], !href.isEmpty, seen.insert(href).inserted,
                  let title = card["title"], !title.isEmpty else { return nil }
            // Episode cards use the small `/thumb/` poster; the full-size `/list/`
            // one is the same artwork at a usable resolution.
            let poster = card["poster"]?.replacingOccurrences(of: "/thumb/", with: "/list/")
            return StreamHit(
                providerID: providerID, providerName: providerName, kind: kind,
                title: title, year: nil,
                posterURL: poster.flatMap { URL(string: $0) },
                pageURL: href
            )
        }
    }

    // MARK: - Details (series)

    func details(_ hit: StreamHit) async throws -> StreamDetails {
        let html = try await load(hit.pageURL)
        let title = firstMatch("<h1[^>]*class=\"[^\"]*section-title[^\"]*\"[^>]*>([^<]+)</h1>", in: html)
            .map { decodeEntities($0).replacingOccurrences(of: " izle", with: "") } ?? hit.title
        let overview = firstMatch("<meta[^>]+name=\"description\"[^>]+content=\"([^\"]+)\"", in: html)
            .map(decodeEntities)
        // The IMDb link on the page gives an exact TMDB match, far better than a
        // title search.
        let imdbID = firstMatch("imdb\\.com/title/(tt\\d+)", in: html)
            ?? firstMatch("(tt\\d{7,})", in: html)

        var hit = hit
        hit.title = title

        let episodes = Self.parseEpisodes(html: html, absolutize: absolute)
        if episodes.isEmpty {
            return StreamDetails(hit: hit, overview: overview, imdbID: imdbID,
                                 episodes: [], moviePageURL: hit.pageURL)
        }
        return StreamDetails(hit: hit, overview: overview, imdbID: imdbID,
                             episodes: episodes, moviePageURL: nil)
    }

    /// Episode links look like `…/dizi/{slug}/sezon-1/bolum-3/`, so the season and
    /// episode come from the URL — reliable regardless of the link's label markup.
    private static func parseEpisodes(html: String, absolutize: (String) -> String) -> [StreamEpisode] {
        guard html.contains("seasons-tab-content") else { return [] }
        guard let regex = try? NSRegularExpression(
            pattern: "href=\"([^\"]*?/sezon-(\\d+)/bolum-(\\d+)/?[^\"]*)\"",
            options: [.caseInsensitive]
        ) else { return [] }
        let ns = html as NSString
        var seen = Set<String>()
        var episodes: [StreamEpisode] = []
        for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let href = ns.substring(with: match.range(at: 1))
            guard seen.insert(href).inserted else { continue }
            let season = Int(ns.substring(with: match.range(at: 2))) ?? 1
            let episode = Int(ns.substring(with: match.range(at: 3))) ?? 0
            episodes.append(StreamEpisode(
                season: season, episode: episode, title: nil, pageURL: absolutize(href)
            ))
        }
        return episodes.sorted { ($0.season, $0.episode) < ($1.season, $1.episode) }
    }

    // MARK: - Embeds

    /// The film/episode page carries a lazy `data-src` iframe to the player embed.
    /// The current site uses `/rplayer/{id}/` on the main domain (a JWPlayer page);
    /// older pages used `hdfilmcehennemi.mobi/video/embed/{id}`. Either is handed to
    /// `StreamResolver`, which reads the real `.m3u8` out of the player.
    func embeds(forPage pageURL: String) async throws -> [StreamEmbed] {
        let html = try await load(pageURL)
        let iframes = allMatches("data-src=\"([^\"]*/rplayer/[^\"]+)\"", in: html)
            + allMatches("data-src=\"([^\"]*/video/embed/[^\"]+)\"", in: html)
            + allMatches("<iframe[^>]+src=\"([^\"]*/(?:rplayer|video/embed)/[^\"]+)\"", in: html)

        var seen = Set<String>()
        let embeds = iframes.compactMap { raw -> StreamEmbed? in
            let url = absolute(raw.replacingOccurrences(of: "&amp;", with: "&"))
            guard seen.insert(url).inserted else { return nil }
            return StreamEmbed(url: url, referer: pageURL, label: displayName)
        }
        guard !embeds.isEmpty else { throw StreamError.noEmbed }
        return embeds
    }
}
