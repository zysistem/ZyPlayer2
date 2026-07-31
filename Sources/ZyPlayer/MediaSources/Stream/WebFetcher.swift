import Foundation
import WebKit

/// Fetches pages from a Cloudflare-gated streaming site through a hidden
/// `WKWebView`.
///
/// Two things a plain `URLSession` cannot do, both needed here:
///   1. Pass Cloudflare's JS challenge — a real web view runs the script and
///      earns the `cf_clearance` cookie (`warmUp`, done once).
///   2. Read a raw response *as bytes*. The sites' search endpoint answers with
///      HTML-typed JSON; loading it as a navigation makes WebKit parse it and
///      throw the tag attributes (hrefs, poster URLs) away. So requests go
///      through an in-page `fetch()` on the warmed, same-origin view, which hands
///      back the untouched body.
///
/// One instance per site, kept warm and reused — see `WebFetcherPool`.
@MainActor
final class WebFetcher: NSObject, WKNavigationDelegate {

    private let baseURL: String
    private var webView: WKWebView!

    private var warmContinuation: CheckedContinuation<Void, Error>?
    private var settleTask: Task<Void, Never>?
    private var warmTimeout: Task<Void, Never>?
    private var warmTask: Task<Void, Error>?
    private var isWarm = false

    init(baseURL: String) {
        self.baseURL = baseURL
        super.init()
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 1280, height: 800),
                             configuration: WKWebViewConfiguration())
        view.customUserAgent = StreamProviderUserAgent.value
        view.navigationDelegate = self
        webView = view
    }

    /// Geçici hatalardan sonra beklenen süreler. HdFilmCehennemi'nin kaynağı
    /// isteklerin çoğuna rastgele 503 döndürüyor: aynı adres arka arkaya dört kez
    /// 503, beşincide 200 verebiliyor. Tek denemede pes etmek kullanıcıya
    /// "sonuç bulunamadı" demekle aynı şey olduğu için geçici hatalar artan
    /// beklemeyle birkaç kez tekrarlanıyor.
    private static let retryDelays: [Duration] = [
        .milliseconds(400), .milliseconds(900), .milliseconds(1800),
        .milliseconds(3000), .milliseconds(4500)
    ]

    /// Her istekte gönderilen varsayılan başlıklar; çağıran bunları ezebiliyor.
    private static let defaultHeaders = [
        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        "Accept-Language": "tr-TR,tr;q=0.9,en;q=0.8"
    ]

    /// Raw body of `url`, fetched same-origin so the CF cookie and cookies ride
    /// along. `url` may be absolute or site-relative.
    ///
    /// Geçici sunucu hatalarında (503/429/5xx ve ağ kopmaları) yeniden deniyor,
    /// Cloudflare izni düşmüşse görünümü yeniden ısıtıyor. Kalıcı hatada boş dize
    /// yerine fırlatıyor — böylece çağıran "içerik yok" ile "siteye ulaşılamadı"yı
    /// ayırt edebiliyor.
    func text(_ url: String, headers: [String: String] = [:]) async throws -> String {
        try await warmUp()
        var merged = Self.defaultHeaders
        for (key, value) in headers { merged[key] = value }

        var lastStatus = 0
        var didReheat = false

        for attempt in 0...Self.retryDelays.count {
            let (status, body) = await fetchOnce(url, headers: merged)
            lastStatus = status

            // Ara sayfa kontrolü başarı kontrolünden önce: Cloudflare meydan
            // okumayı 200 ile de servis edebiliyor, o gövdeyi sayfa sanıp
            // döndürmek ayrıştırmayı sessizce boşa çıkarır.
            let isChallenge = Self.isChallenge(body)
            if !isChallenge, (200..<300).contains(status), !body.isEmpty { return body }

            // Cloudflare izni düşmüş: görünümü bir kez yeniden ısıtıp devam et.
            if !didReheat, status == 403 || isChallenge {
                didReheat = true
                try? await reheat()
                continue
            }
            // İzin zaten bir kez tazelendiyse ara sayfa geçici sayılıp beklenir.
            if isChallenge, attempt < Self.retryDelays.count {
                try? await Task.sleep(for: Self.retryDelays[attempt])
                continue
            }
            // 404 gibi kalıcı hatalar tekrarlamayla düzelmez; sadece geçici
            // olanlar için beklemeye değer.
            guard Self.isTransient(status) else { break }
            if attempt < Self.retryDelays.count {
                try? await Task.sleep(for: Self.retryDelays[attempt])
            }
        }
        throw StreamError.http(lastStatus == 0 ? 503 : lastStatus)
    }

    /// Tek bir `fetch` denemesi. Ağ hatası fırlatmak yerine `0` durumu döndürüyor
    /// ki yeniden deneme döngüsü onu da geçici hata sayabilsin.
    private func fetchOnce(_ url: String, headers: [String: String]) async -> (status: Int, body: String) {
        let js = """
        try {
            const r = await fetch(u, { headers: h, credentials: 'include' });
            return { status: r.status, body: await r.text() };
        } catch (e) {
            return { status: 0, body: '' };
        }
        """
        guard let result = try? await webView.callAsyncJavaScript(
            js, arguments: ["u": url, "h": headers], in: nil, contentWorld: .page
        ), let dict = result as? [String: Any] else { return (0, "") }
        return ((dict["status"] as? Int) ?? 0, (dict["body"] as? String) ?? "")
    }

    /// Yeniden denemeye değer durumlar: ağ kopması (0), hız sınırı ve sunucu
    /// tarafı hataları.
    private static func isTransient(_ status: Int) -> Bool {
        status == 0 || status == 408 || status == 429 || status >= 500
    }

    /// Gövde, sayfanın kendisi değil Cloudflare'in ara sayfası mı?
    private static func isChallenge(_ body: String) -> Bool {
        body.contains("challenges.cloudflare.com") || body.contains("Just a moment")
    }

    /// Cloudflare izni düşünce görünümü sıfırdan ısıtır.
    private func reheat() async throws {
        isWarm = false
        warmTask = nil
        try await warmUp()
    }

    /// Raw body of a form POST, sent same-origin so the site's session cookie rides
    /// along. Dizipal's player-config endpoint hands back the embed only when the
    /// POST carries the very session that was served the page, which an out-of-band
    /// `URLSession` request cannot guarantee.
    func post(_ url: String, form: [String: String],
              headers: [String: String] = [:]) async throws -> String {
        try await warmUp()
        let body = form.map { key, value in
            let encoded = value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value
            return "\(key)=\(encoded)"
        }.joined(separator: "&")
        let js = """
        try {
            const r = await fetch(u, { method: 'POST', credentials: 'include',
                headers: Object.assign({ 'Content-Type': 'application/x-www-form-urlencoded',
                                         'X-Requested-With': 'XMLHttpRequest' }, h),
                body: b });
            return { status: r.status, body: await r.text() };
        } catch (e) {
            return { status: 0, body: '' };
        }
        """
        // Bu POST bir sorgu — yan etkisi yok, o yüzden geçici hatada tekrarlanabilir.
        var lastStatus = 0
        for attempt in 0...Self.retryDelays.count {
            let result = try? await webView.callAsyncJavaScript(
                js, arguments: ["u": url, "h": headers, "b": body], in: nil, contentWorld: .page
            )
            let dict = result as? [String: Any]
            lastStatus = (dict?["status"] as? Int) ?? 0
            if (200..<300).contains(lastStatus), let text = dict?["body"] as? String, !text.isEmpty {
                return text
            }
            guard Self.isTransient(lastStatus) else { break }
            if attempt < Self.retryDelays.count {
                try? await Task.sleep(for: Self.retryDelays[attempt])
            }
        }
        throw StreamError.http(lastStatus == 0 ? 503 : lastStatus)
    }

    /// Raw bytes of `url` (a poster, say), fetched through the cleared, same-origin
    /// view. The images are Cloudflare-gated too, so a plain `AsyncImage` gets a
    /// 403 — only a request carrying the `cf_clearance` cookie succeeds.
    func data(_ url: String) async throws -> Data {
        try await warmUp()
        // arrayBuffer → base64, chunked so a big poster does not blow the call
        // stack in `String.fromCharCode`.
        let js = """
        try {
            const r = await fetch(u, { credentials: 'include' });
            if (!r.ok) return { status: r.status, body: '' };
            const bytes = new Uint8Array(await r.arrayBuffer());
            let s = ''; const chunk = 0x8000;
            for (let i = 0; i < bytes.length; i += chunk) {
                s += String.fromCharCode.apply(null, bytes.subarray(i, i + chunk));
            }
            return { status: r.status, body: btoa(s) };
        } catch (e) {
            return { status: 0, body: '' };
        }
        """
        // Afişler de aynı 503'lere yakalanıyor; boş poster yerine tekrar denenir.
        var lastStatus = 0
        for attempt in 0...Self.retryDelays.count {
            let result = try? await webView.callAsyncJavaScript(
                js, arguments: ["u": url], in: nil, contentWorld: .page
            )
            let dict = result as? [String: Any]
            lastStatus = (dict?["status"] as? Int) ?? 0
            if let base64 = dict?["body"] as? String, !base64.isEmpty,
               let data = Data(base64Encoded: base64) {
                return data
            }
            guard Self.isTransient(lastStatus) else { break }
            if attempt < Self.retryDelays.count {
                try? await Task.sleep(for: Self.retryDelays[attempt])
            }
        }
        throw StreamError.http(lastStatus == 0 ? 404 : lastStatus)
    }

    // MARK: - Warmup (Cloudflare)

    func warmUp() async throws {
        if isWarm { return }
        if let warmTask { return try await warmTask.value }
        let task = Task { try await performWarmup() }
        warmTask = task
        do {
            try await task.value
            isWarm = true
        } catch {
            warmTask = nil
            throw error
        }
    }

    private func performWarmup() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            warmContinuation = cont
            webView.load(URLRequest(url: URL(string: baseURL)!))
            warmTimeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                self?.finishWarm(.failure(StreamError.http(403)))
            }
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in self.scheduleWarmCheck() }
    }

    /// After each navigation, wait a beat and check the title. Cloudflare's
    /// interstitial is titled "Just a moment…"; the real page is not. If it is
    /// still the challenge, do nothing — CF auto-reloads and this runs again.
    private func scheduleWarmCheck() {
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            self?.webView.evaluateJavaScript("document.title") { title, _ in
                guard let self, self.warmContinuation != nil else { return }
                let title = (title as? String) ?? ""
                if !title.isEmpty, !title.contains("Just a moment") {
                    self.finishWarm(.success(()))
                }
            }
        }
    }

    private func finishWarm(_ result: Result<Void, Error>) {
        settleTask?.cancel(); settleTask = nil
        warmTimeout?.cancel(); warmTimeout = nil
        if let cont = warmContinuation {
            warmContinuation = nil
            cont.resume(with: result)
        }
    }
}

/// One warm `WebFetcher` per site, so the Cloudflare clearance and the on-origin
/// context are paid for once and reused across search / details / embeds.
@MainActor
enum WebFetcherPool {
    private static var pool: [String: WebFetcher] = [:]

    static func fetcher(for baseURL: String) -> WebFetcher {
        if let existing = pool[baseURL] { return existing }
        let fetcher = WebFetcher(baseURL: baseURL)
        pool[baseURL] = fetcher
        return fetcher
    }
}
