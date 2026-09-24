import Foundation
import CommonCrypto

/// Dizipal — a Turkish series-first streaming site, shown in the app as
/// "ZySeries". Built against the site's "bg" generation (`dizipal1583.com`):
///
///   1. **Search is a form POST.** `/bg/searchcontent` answers with JSON
///      (`data.result[]`: slug, ad, yıl, IMDb puanı, poster) rather than an
///      HTML page, so hits come straight out of the payload — with year,
///      rating and audio label already filled in.
///   2. **The player is on the page but encrypted.** A watch page carries a
///      hidden `data-rm-k` div holding `{"ciphertext","iv","salt"}`; the
///      site's own JS (PBKDF2-SHA512, 999 tur, AES-256-CBC) decrypts it to
///      the embed URL. We run the same routine with CommonCrypto.
///   3. **No IMDb id on the pages.** Only the search payload carries one
///      (as a rating); `details` returns `imdbID: nil`, which sends
///      `StreamDetailLoader` down its title-search path for the TMDB match.
struct DizipalProvider: StreamProvider {
    static let defaultBaseURL = "https://dizipal1583.com"

    let id = "dizipal"
    let displayName = "ZySeries"
    let kind: StreamKind = .series
    /// Injected from settings so the address can be changed by hand.
    var baseURL: String

    init(baseURL: String = DizipalProvider.defaultBaseURL) {
        self.baseURL = baseURL
    }

    @MainActor
    private func load(_ url: String) async throws -> String {
        try await WebFetcherPool.fetcher(for: baseURL).text(url)
    }

    @MainActor
    private func post(_ url: String, form: [String: String]) async throws -> String {
        try await WebFetcherPool.fetcher(for: baseURL).post(url, form: form)
    }

    // MARK: - Search

    func search(_ query: String) async throws -> [StreamHit] {
        let raw = try await post("\(baseURL)/bg/searchcontent", form: ["searchterm": query])
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = object["data"] as? [String: Any],
              (payload["state"] as? Bool) ?? false,
              let results = payload["result"] as? [[String: Any]] else { return [] }

        var seen = Set<String>()
        var hits: [StreamHit] = []
        for row in results {
            guard let slug = row["used_slug"] as? String else { continue }
            let url = absolute("/" + slug)
            guard seen.insert(url).inserted else { continue }
            guard let name = row["object_name"] as? String,
                  !name.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            hits.append(StreamHit(
                providerID: id,
                providerName: displayName,
                kind: url.contains("/series/") ? .series : .movie,
                title: decodeEntities(name),
                year: (row["object_release_year"] as? Int) ?? Int((row["object_release_year"] as? String) ?? ""),
                posterURL: (row["object_poster_url"] as? String)
                    .map(Self.directImageURL)
                    .flatMap(URL.init(string:)),
                pageURL: url,
                imdbRating: (row["object_related_imdb_point"] as? Double)
                    ?? ((row["object_related_imdb_point"] as? NSNumber)?.doubleValue),
                audioLabel: Self.audioLabel(fromLanguage: row["object_language"] as? String)
            ))
        }
        return hits
    }

    /// Arama yanıtındaki poster adresleri AMP vekilinden geçer
    /// ("https://images-cdnhipter-xyz.cdn.ampproject.org/i/s/images.cdnhipter.xyz/…").
    /// Doğrudan kaynak adrese çevrilir — vekil yavaş ve taşınabilir değil.
    private static func directImageURL(_ url: String) -> String {
        guard let range = url.range(of: "/i/s/") else { return url }
        return "https://" + String(url[range.upperBound...])
    }

    /// "Türkçe Dublaj" → "Dublaj", "Türkçe Altyazı" → "Altyazılı" — HdFilmCehennemi
    /// tarafındaki rozet söz dağarcığıyla aynı tutuldu.
    private static func audioLabel(fromLanguage text: String?) -> String? {
        guard let text else { return nil }
        if text.localizedCaseInsensitiveContains("dublaj") { return "Dublaj" }
        if text.localizedCaseInsensitiveContains("altyaz") { return "Altyazılı" }
        return nil
    }

    // MARK: - Discover (landing rows)

    func discover() async throws -> [StreamShelf] {
        // Ana sayfada yalnızca iki raf: son eklenen filmler ve son eklenen
        // diziler — sitenin ana listelerinden onar kart.
        async let films = shelf(title: "ZySeries · Son Eklenen Filmler", path: "/hd-film-izle", limit: 10)
        async let series = shelf(title: "ZySeries · Son Eklenen Diziler", path: "/yabanci-dizi-izle", limit: 10)
        return await [films, series].filter { !$0.hits.isEmpty }
    }

    private func shelf(title: String, path: String, limit: Int) async -> StreamShelf {
        let html = (try? await load(baseURL + path)) ?? ""
        let hits = Self.hits(fromCards: html, providerID: id, providerName: displayName,
                             absolutize: absolute, decode: decodeEntities)
        return StreamShelf(title: title, hits: Array(hits.prefix(limit)))
    }

    /// Liste sayfalarının kartları `<a data-dizipal-pageloader
    /// href="/movies|/series/{slug}" title="… izle">` biçiminde: afiş
    /// `data-src`te (lazy-load, `src` base64 piksel), dil rozeti `bg-fl`
    /// sınıflı `<span>`da. Kartların başında bölünüp tek tek okunur; tür
    /// href'ten gelir ("/series/" ya da "/movies/").
    private static func hits(fromCards html: String, providerID: String, providerName: String,
                             absolutize: (String) -> String, decode: (String) -> String) -> [StreamHit] {
        var seen = Set<String>()
        return html.components(separatedBy: "data-dizipal-pageloader").dropFirst().compactMap { fragment in
            // Stop at the card's end so a regex can't reach into the next one.
            let card = fragment.components(separatedBy: "</a>").first ?? fragment
            guard let href = match("href=\"([^\"]+/(?:movies|series)/[^\"]+)\"", in: card) else { return nil }
            let url = absolutize(href)
            guard seen.insert(url).inserted else { return nil }

            let title = match("title=\"([^\"]+?)\\s*izle\"", in: card)
                ?? match("<h2[^>]*>([^<]+)</h2>", in: card)
                ?? match("alt=\"([^\"]+)\"", in: card).map { $0.replacingOccurrences(of: " izle", with: "") }
            guard let title, !title.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }

            let poster = match("data-src=\"(https?://[^\"]+)\"", in: card)
            let badge = match("class=\"bg-fl[^\"]*\"[^>]*>\\s*([^<]+?)\\s*<", in: card)

            return StreamHit(
                providerID: providerID,
                providerName: providerName,
                kind: url.contains("/series/") ? .series : .movie,
                title: decode(title),
                year: nil,
                posterURL: poster.flatMap { URL(string: $0) },
                pageURL: url,
                audioLabel: badge.map { $0.localizedCaseInsensitiveContains("dublaj") ? "Dublaj" : "Altyazılı" }
            )
        }
    }

    /// Free function so the card parser can stay `static` (it runs off one HTML
    /// blob and needs nothing from the instance but `absolute`/`decodeEntities`).
    private static func match(_ pattern: String, in text: String,
                              options: NSRegularExpression.Options = [.caseInsensitive]) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let m = regex.firstMatch(in: text, range: range), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Categories (site menu)

    /// Sitenin üst menüsü: Diziler `/yabanci-dizi-izle`, Hd Film
    /// `/hd-film-izle`, Anime `/anime`; platform rafları `/kanal/{slug}`.
    /// Listelerde klasik sayfalama yok, menü de kararlı olduğu için sabit
    /// yazıldı — her görünüm kendi kümesini döner.
    func categories(for kind: StreamKind) async throws -> [StreamCategory] {
        func category(_ title: String, _ path: String) -> StreamCategory {
            StreamCategory(providerID: id, title: title, pageURL: absolute(path))
        }
        switch kind {
        case .movie:
            return [category("Filmler", "/hd-film-izle")]
        default:
            return [
                category("Diziler", "/yabanci-dizi-izle"),
                category("Anime", "/anime"),
                category("Exxen Dizileri", "/kanal/exxen"),
                category("Disney+ Dizileri", "/kanal/disney"),
                category("Netflix Dizileri", "/kanal/netflix")
            ]
        }
    }

    func categoryHits(_ pageURL: String, page: Int) async throws -> [StreamHit] {
        // Bu listelerde sayfalama sunucu tarafında yok (sonsuz kaydırma AJAX'la
        // besleniyor); yalnızca ilk sayfa döner.
        guard page == 1 else { return [] }
        let html = try await load(absolute(pageURL))
        return Self.hits(fromCards: html, providerID: id, providerName: displayName,
                         absolutize: absolute, decode: decodeEntities)
    }

    // MARK: - Details

    func details(_ hit: StreamHit) async throws -> StreamDetails {
        let html = try await load(hit.pageURL)
        let title = firstMatch("<h1[^>]*>([^<]+)</h1>", in: html).map(decodeEntities) ?? hit.title
        let overview = firstMatch("<meta[^>]+name=\"description\"[^>]+content=\"([^\"]+)\"", in: html)
            .map(decodeEntities)

        var hit = hit
        hit.title = title

        // No IMDb id on this site — the TMDB match has to come from the title.
        if hit.kind == .movie {
            return StreamDetails(hit: hit, overview: overview, imdbID: nil,
                                 episodes: [], moviePageURL: hit.pageURL)
        }
        return StreamDetails(hit: hit, overview: overview, imdbID: nil,
                             episodes: Self.parseEpisodes(html: html, absolutize: absolute),
                             moviePageURL: nil)
    }

    /// Episode links are `/bolum/{slug}-{season}x{episode}`, optionally with a
    /// `-cNN` sürüm eki; sayılar URL'den, etiket işaretlemesinden değil okunur.
    /// Aynı bölümün dublaj/altyazı kartları URL'de tekrar edebildiği için
    /// sezon+bölüm üzerinden tekillenir. Bu sayfada bölüm afişleri yok.
    private static func parseEpisodes(html: String, absolutize: (String) -> String) -> [StreamEpisode] {
        guard let regex = try? NSRegularExpression(
            pattern: "href=\"([^\"]*/bolum/[^\"]*?-(\\d+)x(\\d+)(?:-c\\d+)?/?)\"",
            options: [.caseInsensitive]
        ) else { return [] }

        let ns = html as NSString
        var seen = Set<String>()
        var episodes: [StreamEpisode] = []
        for m in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let href = ns.substring(with: m.range(at: 1))
            let key = href.replacingOccurrences(
                of: "-c\\d+(/?)$", with: "$1", options: [.regularExpression, .caseInsensitive])
            guard seen.insert(key).inserted else { continue }
            episodes.append(StreamEpisode(
                season: Int(ns.substring(with: m.range(at: 2))) ?? 1,
                episode: Int(ns.substring(with: m.range(at: 3))) ?? 0,
                title: nil,
                thumbnailURL: nil,
                pageURL: absolutize(href)
            ))
        }
        return episodes.sorted { ($0.season, $0.episode) < ($1.season, $1.episode) }
    }

    // MARK: - Embeds

    /// A film or episode page carries a hidden `<div data-rm-k="true">` holding
    /// `{"ciphertext": base64, "iv": hex, "salt": hex}` — the embed URL in
    /// CryptoJS's package format. The site's own JS (`app-dizipals.js`,
    /// `oyunculistdc`) opens it with PBKDF2-SHA512 (999 tur, 256 bitlik
    /// anahtar) + AES-256-CBC and drops the plaintext into `#cstk iframe`'s
    /// `src` ("//host/iframe.php?v=…"). Same routine, CommonCrypto ile.
    func embeds(forPage pageURL: String) async throws -> [StreamEmbed] {
        let html = try await load(pageURL)
        guard let blob = Self.match("data-rm-k=\"true\"[^>]*>(.*?)</div>", in: html,
                                    options: [.caseInsensitive, .dotMatchesLineSeparators]),
              let url = Self.decryptPlayerBlob(blob), !url.isEmpty else { throw StreamError.noEmbed }
        // Oynatıcı (dplayer) artık Playerjs: tıklanmadan `source2.php`'yi
        // istemiyor, alt listeleri (`l.php`/`ld.php`) de mpv'ye 403 veriyor.
        return [StreamEmbed(url: url, referer: pageURL, label: displayName,
                            tapToStart: true, localizePlaylists: true)]
    }

    /// `oyunculistdc`'nin paket açan anahtarı — sitenin kendi JS'inden
    /// çözülmüş, uygulamanın siteyle birlikte güncellenmesi gereken bir sabit.
    private static let playerKey = "3hPn4uCjTVtfYWcjIcoJQ4cL1WWk1qxXI39egLYOmNv6IblA7eKJz68uU3eLzux1biZLCms0quEjTYniGv5z1JcKbNIsDQFSeIZOBZJz4is6pD7UyWDggWWzTLBQbHcQFpBQdClnuQaMNUHtLHTpzCvZy33p6I7wFBvL4fnXBYH84aUIyWGTRvM2G5cfoNf4705tO2kv"

    private static func decryptPlayerBlob(_ escapedJSON: String) -> String? {
        // Div'in içeriği HTML-öncelenmiş JSON gelir ("&quot;"): önce düzelt.
        let json = escapedJSON
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#039;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cipherB64 = object["ciphertext"] as? String,
              let ivHex = object["iv"] as? String,
              let saltHex = object["salt"] as? String,
              let ciphertext = Data(base64Encoded: cipherB64),
              let iv = hexData(ivHex), let salt = hexData(saltHex),
              let key = pbkdf2Key(password: playerKey, salt: salt, iterations: 999, length: 32),
              let plain = aesCBCDecrypt(ciphertext, key: key, iv: iv) else { return nil }
        return normalizeEmbedURL(plain)
    }

    /// Paketten çıkan adres protokolsüz olabilir ("//host/path"); https'e bağlanır.
    private static func normalizeEmbedURL(_ url: String) -> String? {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("//") { return "https:" + trimmed }
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") { return trimmed }
        guard !trimmed.isEmpty, trimmed.contains(".") else { return nil }
        return "https://" + trimmed
    }

    private static func hexData(_ hex: String) -> Data? {
        guard hex.count % 2 == 0 else { return nil }
        var out = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            out.append(byte)
            index = next
        }
        return out
    }

    /// CCKeyDerivationPBKDF — HMAC-SHA512 ile 256 bitlik anahtar.
    private static func pbkdf2Key(password: String, salt: Data, iterations: Int, length: Int) -> Data? {
        let passwordData = Data(password.utf8)
        var out = Data(count: length)
        let status = out.withUnsafeMutableBytes { (outBuffer: UnsafeMutableRawBufferPointer) -> Int32 in
            passwordData.withUnsafeBytes { (passwordBuffer: UnsafeRawBufferPointer) -> Int32 in
                salt.withUnsafeBytes { (saltBuffer: UnsafeRawBufferPointer) -> Int32 in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        passwordData.count,
                        saltBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512),
                        UInt32(iterations),
                        outBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        length
                    )
                }
            }
        }
        return status == kCCSuccess ? out : nil
    }

    /// AES-256-CBC, PKCS7 dolgulu — CryptoJS `AES.decrypt`'in varsayılanı.
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
