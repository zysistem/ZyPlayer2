import SwiftUI
import WebKit

// MARK: - Embedded Web Tabs (Müzik / Oyunlar)

/// Sol menüdeki gömülü-web sekmelerinin (Müzik, Oyunlar) ortak altyapısı.
///
/// Her sekme tek bir `WKWebView`'i bir `@Observable` store üzerinden yönetir:
///
///   * **Kalıcı oturum:** `WKWebsiteDataStore.default()` sayesinde Google /
///     Boosteroid çerezleri uygulama kapanıp açılsa bile korunur — bir kez
///     giriş yapılır ve "kendi müziklerim / kütüphanem" her açılışta hazır gelir.
///   * **Masaüstü Safari user agent:** YouTube Music mobil arayüze düşmesin,
///     Google girişi gömülü webview'i reddetmesin diye zorlanıyor.
///   * **Tek webview örneği:** Store, `makeNSView`'da bir kez oluşturulan
///     webview'i tutar; SwiftUI yeniden çizse bile her defasında sıfırdan
///     yüklenmez, dolayısıyla oturum/çalma listesi bozulmaz.
///
/// `TrailerWebView` ile aynı `NSViewRepresentable` kabuğunu kullanır, ama tek
/// bir video yerine tam sayfayı yükler ve geri/ileri/yenile sunar.
@Observable
final class EmbeddedWebStore {
    /// Bu sekmenin yüklediği site.
    let url: URL
    /// Geri/ileri/yenile gibi komutlar bu zayıf referans üzerinden webview'e iletilir.
    weak var webView: WKWebView?

    /// Gezinme durumu — araç çubuğundaki düğmeleri etkinleştirip devre dışı bırakır.
    var canGoBack = false
    var canGoForward = false
    var isLoading = false

    init(url: URL) {
        self.url = url
    }

    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }
    func reload() { webView?.reload() }
    func goHome() { webView?.load(URLRequest(url: url)) }

    /// Webview'den gelen geri aramalarla gezinme durumunu tazele.
    func syncNavState(from webView: WKWebView) {
        let back = webView.canGoBack
        let fwd = webView.canGoForward
        // observe + ana thread dışı geldiğinde SwiftUI'nin güncellemesi için.
        if canGoBack != back { canGoBack = back }
        if canGoForward != fwd { canGoForward = fwd }
    }
}

// MARK: - Container view

/// Bir gömülü-web sekmesinin tamamı: üstte araç çubuğu, altta webview.
struct EmbeddedWebViewTab: View {
    @Bindable var store: EmbeddedWebStore
    var title: String

    var body: some View {
        VStack(spacing: 0) {
            EmbeddedWebToolbar(store: store, title: title)
            Divider()
            EmbeddedWebView(store: store)
        }
        .background(AppTheme.background(.dark).ignoresSafeArea())
    }
}

private struct EmbeddedWebToolbar: View {
    @Bindable var store: EmbeddedWebStore
    let title: String

    var body: some View {
        HStack(spacing: 6) {
            toolbarButton(symbol: "chevron.backward",
                          enabled: store.canGoBack,
                          help: "Geri",
                          action: { store.goBack() })
            toolbarButton(symbol: "chevron.forward",
                          enabled: store.canGoForward,
                          help: "İleri",
                          action: { store.goForward() })
            toolbarButton(symbol: store.isLoading ? "xmark" : "arrow.clockwise",
                          enabled: true,
                          help: store.isLoading ? "Durdur" : "Yenile",
                          action: { store.reload() })

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func toolbarButton(symbol: String, enabled: Bool, help: String,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 26, height: 26)
                .foregroundStyle(enabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary.opacity(0.4)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
    }
}

// MARK: - WebView (NSViewRepresentable)

struct EmbeddedWebView: NSViewRepresentable {
    @Bindable var store: EmbeddedWebStore

    func makeCoordinator() -> Coordinator {
        Coordinator(store: store)
    }

    func makeNSView(context: Context) -> WKWebView {
        // Store halihazırda bir webview tutuyorsa onu yeniden kullan — böylece
        // SwiftUI yeniden çizse bile oturum ve çalma listesi korunur.
        if let existing = store.webView {
            return existing
        }

        let config = WKWebViewConfiguration()
        // Kalıcı veri deposu: çerezler uygulama kapanıp açılsa bile korunur.
        config.websiteDataStore = .default()
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsAirPlayForMediaPlayback = true
        config.preferences.setValue(true, forKey: "allowsInlineMediaPlayback")

        let webView = WKWebView(frame: .zero, configuration: config)
        // Masaüstü Safari user agent: mobil arayüze düşmeyi ve bazı giriş
        // akışlarının webview'i reddetmesini engeller.
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsBackForwardNavigationGestures = true
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator

        store.webView = webView
        webView.load(URLRequest(url: store.url))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        context.coordinator.store = store
        store.syncNavState(from: nsView)
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
    }

    // MARK: Coordinator

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var store: EmbeddedWebStore

        init(store: EmbeddedWebStore) {
            self.store = store
        }

        private func onMain(_ block: @escaping () -> Void) {
            if Thread.isMainThread { block() } else { DispatchQueue.main.async(execute: block) }
        }

        // MARK: WKNavigationDelegate

        func webView(_ webView: WKWebView,
                     didStartProvisionalNavigation navigation: WKNavigation!) {
            onMain { self.store.isLoading = true }
        }

        func webView(_ webView: WKWebView,
                     didCommit navigation: WKNavigation!) {
            store.syncNavState(from: webView)
        }

        func webView(_ webView: WKWebView,
                     didFinish navigation: WKNavigation!) {
            onMain {
                self.store.isLoading = false
                self.store.syncNavState(from: webView)
            }
        }

        func webView(_ webView: WKWebView,
                     didFail navigation: WKNavigation!,
                     withError error: Error) {
            onMain { self.store.isLoading = false }
        }

        func webView(_ webView: WKWebView,
                     didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            onMain { self.store.isLoading = false }
        }

        // MARK: WKUIDelegate

        /// "Yeni pencerede aç" isteklerini (Google / Boosteroid giriş pop-up'ları)
        /// aynı webview içinde aç; aksi halde açılır pencere hiç açılmaz ve giriş
        /// takılı kalır.
        func webView(_ webView: WKWebView,
                     createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = navigationAction.request.url {
                webView.load(URLRequest(url: url))
            }
            return nil
        }
    }
}

// MARK: - Concrete tabs

/// Müzik sekmesi — YouTube Music.
struct MusicView: View {
    @State private var store = EmbeddedWebStore(
        url: URL(string: "https://music.youtube.com/")!
    )

    var body: some View {
        EmbeddedWebViewTab(store: store, title: "Müzik")
    }
}

/// Oyunlar sekmesi — Boosteroid Cloud Gaming.
struct GamesView: View {
    @State private var store = EmbeddedWebStore(
        url: URL(string: "https://cloud.boosteroid.com/")!
    )

    var body: some View {
        EmbeddedWebViewTab(store: store, title: "Oyunlar")
    }
}
