import Foundation

/// A single streaming site, reimplemented natively.
///
/// The CloudStream plugins these mirror are compiled Kotlin for Android and can
/// not run here, so each site is scraped directly: `search` and `details` read
/// HTML over `URLSession`, and `embeds` finds the player iframe(s) on a watch
/// page. Turning an embed into a playable URL is the one shared step — it needs a
/// real JS engine — and lives in `StreamResolver`.
protocol StreamProvider {
    /// Stable id stored in settings, e.g. `"hdfilmcehennemi"`.
    var id: String { get }
    var displayName: String { get }
    var kind: StreamKind { get }
    /// Current site root. A property because these domains move often.
    var baseURL: String { get }

    func search(_ query: String) async throws -> [StreamHit]
    func details(_ hit: StreamHit) async throws -> StreamDetails
    /// Player embeds on a movie or episode page, best option first.
    func embeds(forPage pageURL: String) async throws -> [StreamEmbed]
    /// The landing-page rows (recently added, etc.), refreshed on each visit.
    /// Providers with nothing to show return an empty array.
    func discover() async throws -> [StreamShelf]

    /// Sitenin kendi menüsündeki kategoriler. `kind` istenen görünümü söyler:
    /// "Filmler" (.movie) ile "Diziler" (.series) farklı kategori kümeleri
    /// isteyebiliyor. Desteklemeyen kaynak boş dizi döner.
    func categories(for kind: StreamKind) async throws -> [StreamCategory]
    /// Bir kategori liste sayfasının `page`. sayfasındaki kartlar (1'den başlar).
    /// Film ve dizi karışık gelebilir; görünüm bunları `hit.kind` ile ayırıyor.
    /// Sayfa yoksa boş döner — çağıran boş sayfada durur.
    func categoryHits(_ pageURL: String, page: Int) async throws -> [StreamHit]
}

extension StreamProvider {
    func discover() async throws -> [StreamShelf] { [] }
    func categories(for kind: StreamKind) async throws -> [StreamCategory] { [] }
    func categoryHits(_ pageURL: String, page: Int) async throws -> [StreamHit] { [] }
}

/// Shared HTTP + HTML helpers so each provider stays small.
extension StreamProvider {
    /// A browser-like GET. Streaming sites reject the default URLSession agent and
    /// several gate on a matching `Referer`.
    func fetchHTML(_ urlString: String, referer: String? = nil) async throws -> String {
        guard let url = URL(string: urlString) else { throw StreamError.badURL }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
                         forHTTPHeaderField: "Accept")
        request.setValue(referer ?? baseURL, forHTTPHeaderField: "Referer")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw StreamError.http(http.statusCode)
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// A realistic desktop Safari agent, shared with `StreamResolver` so the
    /// manifest and the media fetch present the same UA.
    static var userAgent: String { StreamProviderUserAgent.value }

    /// First capture group of `pattern` in `text`, or nil.
    func firstMatch(_ pattern: String, in text: String,
                    options: NSRegularExpression.Options = [.caseInsensitive]) -> String? {
        allMatches(pattern, in: text, options: options).first
    }

    /// Every first-group capture of `pattern` in `text`, in document order.
    func allMatches(_ pattern: String, in text: String,
                    options: NSRegularExpression.Options = [.caseInsensitive]) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges > 1, let r = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[r])
        }
    }

    /// Turns a site-relative href into an absolute URL string.
    func absolute(_ href: String) -> String {
        if href.hasPrefix("http://") || href.hasPrefix("https://") { return href }
        let root = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        return href.hasPrefix("/") ? root + href : root + "/" + href
    }

    /// Decodes the handful of HTML entities that show up in scraped titles.
    func decodeEntities(_ s: String) -> String {
        var out = s
        let map = ["&amp;": "&", "&#039;": "'", "&#39;": "'", "&quot;": "\"",
                   "&lt;": "<", "&gt;": ">", "&ndash;": "–", "&hellip;": "…",
                   "&uuml;": "ü", "&ouml;": "ö", "&ccedil;": "ç", "&#8217;": "'"]
        for (k, v) in map { out = out.replacingOccurrences(of: k, with: v) }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
