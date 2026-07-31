import Foundation
import WebKit

/// Navigates a throwaway web view to a page, lets its JavaScript run, and returns
/// the value of an extraction script.
///
/// Needed for listing pages whose posters are lazy-loaded by JS from a
/// `data-token` — they are simply not in the server HTML, so `WebFetcher.text`
/// (a raw fetch) can't see them, but a rendered page can. Cloudflare is passed the
/// same way `WebFetcher` does: a real navigation runs the challenge script and
/// reuses the shared clearance cookie.
@MainActor
final class StreamPageRenderer: NSObject, WKNavigationDelegate {

    private var webView: WKWebView?
    private var continuation: CheckedContinuation<Any?, Error>?
    private var settleTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var extractionJS = ""
    private var settle: Duration = .seconds(3)
    private var extracted = false

    /// Sunucu geçici olarak hata sayfası döndürdüğünde beklenen süreler.
    /// `WebFetcher` ile aynı gerekçe: site isteklerin çoğuna rastgele 503 veriyor,
    /// tek denemede pes etmek rafı boş bırakıyor.
    private static let retryDelays: [Duration] = [
        .milliseconds(600), .milliseconds(1400), .milliseconds(2600), .milliseconds(4000)
    ]

    /// Loads `url`, waits `settle` for scripts (lazy images) to run, then returns
    /// `extractionJS`'s result (which may await inside).
    ///
    /// Sayfa yerine bir sunucu hata sayfası geldiyse gezinme yeniden deneniyor.
    func render(_ url: String, extractionJS: String,
                settle: Duration = .seconds(3), timeout: Duration = .seconds(30)) async throws -> Any? {
        var lastError: Error = StreamError.http(503)
        for attempt in 0...Self.retryDelays.count {
            do {
                return try await attemptRender(url, extractionJS: extractionJS,
                                               settle: settle, timeout: timeout)
            } catch {
                lastError = error
                // Adres bozuksa tekrarlamanın anlamı yok.
                if case StreamError.badURL = error { throw error }
            }
            if attempt < Self.retryDelays.count {
                try? await Task.sleep(for: Self.retryDelays[attempt])
            }
        }
        throw lastError
    }

    private func attemptRender(_ url: String, extractionJS: String,
                               settle: Duration, timeout: Duration) async throws -> Any? {
        self.extractionJS = extractionJS
        self.settle = settle
        self.extracted = false

        guard let target = URL(string: url) else { throw StreamError.badURL }

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Any?, Error>) in
            continuation = cont
            let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 1400, height: 2400),
                                 configuration: WKWebViewConfiguration())
            view.customUserAgent = StreamProviderUserAgent.value
            view.navigationDelegate = self
            webView = view
            view.load(URLRequest(url: target))

            timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled else { return }
                self?.finish(.failure(StreamError.http(403)))
            }
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in self.afterLoad() }
    }

    private func afterLoad() {
        guard continuation != nil, !extracted else { return }
        webView?.evaluateJavaScript("document.title") { [weak self] title, _ in
            guard let self, self.continuation != nil, !self.extracted else { return }
            let title = (title as? String) ?? ""
            // Still the Cloudflare interstitial — wait for its auto-reload.
            guard !title.isEmpty, !title.contains("Just a moment") else { return }
            // Sayfa değil, sunucunun geçici hata sayfası geldi: kazımaya çalışmak
            // boş bir raf üretir. Hata olarak bitir ki `render` tekrar denesin.
            if Self.isServerErrorPage(title) {
                self.extracted = true
                self.finish(.failure(StreamError.http(503)))
                return
            }
            self.extracted = true
            self.settleTask = Task { [weak self] in
                try? await Task.sleep(for: self?.settle ?? .seconds(3))
                guard !Task.isCancelled else { return }
                self?.extract()
            }
        }
    }

    /// Sunucunun ürettiği hata sayfaları başlıklarını durum koduyla açıyor
    /// ("503 Service Unavailable", "502 Bad Gateway" gibi).
    private static func isServerErrorPage(_ title: String) -> Bool {
        let lowered = title.lowercased()
        if lowered.contains("service unavailable") || lowered.contains("bad gateway")
            || lowered.contains("gateway time") { return true }
        // Başlığın başındaki 5xx/429 durum kodu.
        let leading = title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(3)
        return ["500", "502", "503", "504", "429"].contains(String(leading))
    }

    private func extract() {
        Task { @MainActor in
            do {
                let value = try await webView?.callAsyncJavaScript(
                    extractionJS, arguments: [:], in: nil, contentWorld: .page)
                finish(.success(value ?? nil))
            } catch {
                finish(.failure(error))
            }
        }
    }

    private func finish(_ result: Result<Any?, Error>) {
        settleTask?.cancel(); settleTask = nil
        timeoutTask?.cancel(); timeoutTask = nil
        if let view = webView {
            view.stopLoading()
            view.navigationDelegate = nil
            webView = nil
        }
        if let cont = continuation {
            continuation = nil
            cont.resume(with: result)
        }
    }
}
