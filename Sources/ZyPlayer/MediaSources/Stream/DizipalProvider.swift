import Foundation
import CommonCrypto

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
    static let defaultBaseURL = "https://dizipal2134.com"

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

    // MARK: - Categories (site menu)

    /// Sitenin menüsündeki `/kategori/{slug}` bağlantıları. Başlık, bağlantı
    /// metninden alınıyor; boşsa slug'dan türetiliyor ("aksiyon-macera" →
    /// "Aksiyon Macera"). Aynı slug birden çok yerde geçebildiği için tekilleniyor
    /// ve menüdeki sıra korunuyor.
    func categories(for kind: StreamKind) async throws -> [StreamCategory] {
        let html = try await load(baseURL)
        let pattern = "href=\"([^\"]*?/kategori/([^\"/]+)/?)\"[^>]*>([^<]*)<"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let ns = html as NSString
        var seen = Set<String>()
        var out: [StreamCategory] = []
        for m in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let href = absolute(ns.substring(with: m.range(at: 1)))
            let slug = ns.substring(with: m.range(at: 2))
            guard seen.insert(slug).inserted else { continue }
            let label = ns.substring(with: m.range(at: 3)).trimmingCharacters(in: .whitespacesAndNewlines)
            let title = label.isEmpty ? Self.titleize(slug) : decodeEntities(label)
            out.append(StreamCategory(providerID: id, title: title, pageURL: href))
        }
        return out
    }

    func categoryHits(_ pageURL: String, page: Int) async throws -> [StreamHit] {
        // Dizipal kategori listelerinde sayfalama bu görünümde kullanılmıyor;
        // yalnızca ilk sayfa döner.
        guard page == 1 else { return [] }
        let html = try await load(absolute(pageURL))
        return Self.hits(fromCards: html, providerID: id, providerName: displayName,
                         absolutize: absolute, decode: decodeEntities)
    }

    /// "bilim-kurgu-fantastik" → "Bilim Kurgu Fantastik".
    private static func titleize(_ slug: String) -> String {
        slug.split(separator: "-")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
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

    /// A film or episode page carries a `data-cfg` token on `#videoContainer`.
    ///
    /// 2026-09 itibarıyla token yine sunucuya POST ediliyor
    /// (`/ajax-player-config`) ama yanıtın içindeki embed adresi artık şifreli:
    /// `{"success":true,"config":{"v":"","t":…,"p":…},"enc":{"k1","k2","iv","c"}}`
    /// — anahtar `k1 ⊕ k2`, AES-CBC + PKCS7. Sitenin kendi JS'i (main.js →
    /// PatchedXHR/decryptEnc) XHR yanıtını yakalayıp açtığı için sayfa
    /// kaynağında adres hiç görünmez. POST, sayfayı yükleyen aynı ısınmış
    /// `WebFetcher` oturumuyla gitmek zorunda: yabancı bir oturum
    /// "Invalid token" alıyor.
    ///
    /// Eski günlerden kalan base64-JSON `data-cfg` gelirse öncelik o yolda.
    ///
    /// A series landing page has no `data-cfg` at all, so it throws `.noEmbed`
    /// and the store falls through to the episode list — the same shape
    /// `HdFilmCehennemiProvider` relies on.
    func embeds(forPage pageURL: String) async throws -> [StreamEmbed] {
        let html = try await load(pageURL)
        guard let cfg = firstMatch("data-cfg=\"([^\"]+)\"", in: html) else { throw StreamError.noEmbed }

        var value = Self.decodeCfg(cfg).flatMap(Self.embedValue)
        if value == nil {
            let raw = try await WebFetcherPool.fetcher(for: baseURL)
                .post("\(baseURL)/ajax-player-config", form: ["cfg": cfg])
            if let data = raw.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let enc = object["enc"] as? [String: Any] {
                    value = Self.decryptEnc(enc)
                } else if let config = object["config"] as? [String: Any] {
                    value = Self.embedValue(in: config)
                }
            }
        }
        guard var url = value, !url.isEmpty else { throw StreamError.noEmbed }
        if url.hasPrefix("//") { url = "https:" + url }
        return [StreamEmbed(url: absolute(url), referer: pageURL, label: displayName)]
    }

    /// `v` is normally the embed URL outright; when the site returns a whole
    /// iframe tag instead, the src is what we want out of it.
    private static func embedValue(in config: [String: Any]) -> String? {
        guard let raw = config["v"] as? String, !raw.isEmpty else { return nil }
        let url = raw.contains("<iframe")
            ? (match("src=\"([^\"]+)\"", in: raw) ?? "")
            : raw
        return url.isEmpty ? nil : url
    }

    /// `data-cfg` is standard base64 (the site's own JS never decodes it with
    /// `-`/`_` URL-safe substitutes, but a defensive swap costs nothing) of a
    /// JSON object; padding is sometimes stripped from the HTML attribute so
    /// it's restored before decoding. Bugün token opak bir hash olduğu için
    /// bu yol genelde nil döner ve POST'a düşülür.
    private static func decodeCfg(_ cfg: String) -> [String: Any]? {
        var base64 = cfg.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// `enc` paketini açar: `k1 ⊕ k2` 32 baytlık anahtar, AES-CBC + PKCS7.
    /// Birebir `main.js` → `decryptEnc` karşılığı.
    private static func decryptEnc(_ enc: [String: Any]) -> String? {
        func b64(_ key: String) -> Data? {
            guard let text = enc[key] as? String else { return nil }
            return Data(base64Encoded: text)
        }
        guard let k1 = b64("k1"), let k2 = b64("k2"),
              let iv = b64("iv"), let ct = b64("c"), k1.count == k2.count else { return nil }
        let key = Data((0..<k1.count).map { k1[k1.startIndex + $0] ^ k2[k2.startIndex + $0] })
        guard let plain = aesCBCDecrypt(ct, key: key, iv: iv), !plain.isEmpty else { return nil }
        return plain
    }

    /// AES-CBC, PKCS7 dolgulu; anahtar uzunluğu veriden gelir (16/24/32 bayt).
    private static func aesCBCDecrypt(_ data: Data, key: Data, iv: Data) -> String? {
        guard data.count % kCCBlockSizeAES128 == 0 else { return nil }
        var out = Data(count: data.count + kCCBlockSizeAES128)
        var outLength = 0
        let status = out.withUnsafeMutableBytes { (outBuffer: UnsafeMutableRawBufferPointer) -> Int32 in
            data.withUnsafeBytes { (inBuffer: UnsafeRawBufferPointer) -> Int32 in
                CCCrypt(
                    CCOperation(kCCDecrypt),
                    CCAlgorithm(kCCAlgorithmAES),
                    CCOptions(kCCOptionPKCS7Padding),
                    key.withUnsafeBytes { $0.baseAddress },
                    key.count,
                    iv.withUnsafeBytes { $0.baseAddress },
                    inBuffer.baseAddress,
                    data.count,
                    outBuffer.baseAddress,
                    outBuffer.count,
                    &outLength
                )
            }
        }
        guard status == kCCSuccess else { return nil }
        out.removeSubrange(outLength...)
        return String(data: out, encoding: .utf8)
    }
}
