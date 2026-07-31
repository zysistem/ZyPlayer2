import AppKit

/// Loads streaming-site poster images.
///
/// Two routes, because the sites differ:
///
///   * **Same host as the site** (HdFilmCehennemi): the posters sit behind the
///     same Cloudflare gate as the pages, so a plain `AsyncImage` (URLSession, no
///     clearance cookie) just gets a 403. Fetching them on the warmed, same-origin
///     web view carries the cookie and succeeds.
///   * **A separate image host** (Dizipal serves its posters off its own CDN):
///     the web view route *cannot* work — the CDN sends no
///     `Access-Control-Allow-Origin`, so reading the bytes cross-origin is
///     blocked. Those hosts are open, so a plain request is both correct and
///     faster.
///
/// The host comparison picks the route, and each falls back to the other so a
/// site that changes how it serves posters keeps working. Results are cached in
/// memory for the session.
@MainActor
final class StreamImageLoader {
    static let shared = StreamImageLoader()

    private var cache: [String: NSImage] = [:]

    /// Cached image, or fetches it once. nil when the poster can't be loaded.
    func image(for url: URL, baseURL: String) async -> NSImage? {
        let key = url.absoluteString
        if let hit = cache[key] { return hit }

        let sameHost = url.host != nil && url.host == URL(string: baseURL)?.host
        let routes = sameHost
            ? [{ await Self.viaWebView(key, baseURL: baseURL) }, { await Self.direct(url) }]
            : [{ await Self.direct(url) }, { await Self.viaWebView(key, baseURL: baseURL) }]

        for route in routes {
            if let data = await route(), let image = NSImage(data: data) {
                cache[key] = image
                return image
            }
        }
        return nil
    }

    private static func viaWebView(_ url: String, baseURL: String) async -> Data? {
        try? await WebFetcherPool.fetcher(for: baseURL).data(url)
    }

    /// A plain request with a browser User-Agent — enough for an open image CDN.
    private static func direct(_ url: URL) async -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue(StreamProviderUserAgent.value, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              !data.isEmpty else { return nil }
        return data
    }
}
