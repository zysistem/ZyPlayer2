import Foundation
import WebKit

/// Turns a player embed into a direct media URL.
///
/// Two paths, tried together:
///   1. The current HdFilmCehennemi player is JWPlayer (`/rplayer/…`). Its config
///      holds the resolved `.m3u8` and the subtitle tracks, so once the page's JS
///      has run they are read straight out of `jwplayer().getPlaylist()`. The
///      subtitles live on the Cloudflare-gated site, so they are fetched through
///      the same web view (which has the clearance cookie) and written to temp
///      files mpv can open.
///   2. Fallback: an injected hook wraps `fetch`/`XHR` and reports any `.m3u8`
///      the player requests — for embeds that are not JWPlayer.
///
/// Main-actor bound because `WKWebView` is.
@MainActor
final class StreamResolver: NSObject, WKScriptMessageHandler, WKNavigationDelegate {

    private var webView: WKWebView?
    private var continuation: CheckedContinuation<ResolvedStream, Error>?
    private var timeoutTask: Task<Void, Never>?
    /// Referer the media CDN expects: the embed's site origin.
    private var resultReferer: String = ""
    private var jwAttempted = false
    /// Çözülmekte olan embed'in bayrakları (`tapToStart`, `localizePlaylists`).
    private var embed: StreamEmbed?
    /// Her `resolve` çağrısında artar; asenkron bir bitiş adımı, arada başka bir
    /// çözüm başladıysa eskisinin sonucunu yeni continuation'a yazmasın diye.
    private var session = 0
    /// Playerjs'in `openPlayer` çağrısından yakalanan altyazıların indirilmesi.
    private var trackTask: Task<[StreamSubtitle], Never>?

    /// Sniffer state (fallback path).
    private var mediaURL: URL?
    private var subtitles: [StreamSubtitle] = []
    private var graceTask: Task<Void, Never>?

    private static let hookSource = """
    (function () {
      function report(u) {
        try {
          if (!u) return;
          var abs = new URL(u, location.href).href;
          var media = abs.indexOf('.m3u8') > -1 || abs.indexOf('.mp4') > -1
              || abs.indexOf('master.txt') > -1 || abs.indexOf('/hls/') > -1;
          var sub = abs.indexOf('.vtt') > -1 || abs.indexOf('.srt') > -1;
          if (media || sub) {
            window.webkit.messageHandlers.zystream.postMessage((sub ? 'SUB ' : 'MEDIA ') + abs);
          }
        } catch (e) {}
      }
      var origFetch = window.fetch;
      if (origFetch) {
        window.fetch = function () {
          try { var a = arguments[0]; report(typeof a === 'string' ? a : (a && a.url)); } catch (e) {}
          return origFetch.apply(this, arguments);
        };
      }
      var origOpen = XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open = function (m, u) { report(u); return origOpen.apply(this, arguments); };
      function nudge() {
        try {
          document.querySelectorAll('video').forEach(function (v) {
            report(v.src || v.getAttribute('src'));
            try { v.muted = true; var p = v.play && v.play(); if (p && p.catch) p.catch(function(){}); } catch (e) {}
          });
          document.querySelectorAll('source, track').forEach(function (s) { report(s.src || s.getAttribute('src')); });
        } catch (e) {}
      }
      setInterval(nudge, 600);
    })();
    """

    /// Reads JWPlayer's resolved playlist once the player is up.
    private static let jwReadJS = """
    for (var i = 0; i < 40; i++) {
      try {
        if (typeof jwplayer === 'function') {
          var p = jwplayer();
          var pl = (p && p.getPlaylist && p.getPlaylist()) || [];
          if (pl[0] && pl[0].file) {
            var tracks = (pl[0].tracks || []).map(function (t) {
              return { file: t.file, label: t.label, language: t.language, kind: t.kind };
            });
            return JSON.stringify({ file: pl[0].file, tracks: tracks });
          }
        }
      } catch (e) {}
      await new Promise(function (r) { setTimeout(r, 250); });
    }
    return '';
    """

    /// Embed listesini sırayla dener; biri `perEmbedTimeout` içinde çözülmezse
    /// ya da hata verirse bir sonrakine geçer. HdFilmCehennemi gibi sayfalarda
    /// ilk sunucu ("Close") takılırsa ikinci sunucudan ("Rapidrame") devam etsin
    /// diye. İlk başarılı çözüm döner; hepsi tükenirse son hata fırlatılır.
    func resolveFirstWorking(_ embeds: [StreamEmbed],
                             perEmbedTimeout: Duration = .seconds(8)) async throws -> ResolvedStream {
        guard !embeds.isEmpty else { throw StreamError.noEmbed }
        var lastError: Error = StreamError.resolveFailed
        for embed in embeds {
            do { return try await resolve(embed, timeout: perEmbedTimeout) }
            catch { lastError = error }
        }
        throw lastError
    }

    func resolve(_ embed: StreamEmbed, timeout: Duration = .seconds(25)) async throws -> ResolvedStream {
        teardown(resumingWith: .failure(CancellationError()))
        session += 1
        self.embed = embed
        resultReferer = Self.origin(of: embed.url) ?? embed.url

        return try await withCheckedThrowingContinuation { cont in
            continuation = cont
            start(embed)
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled else { return }
                self?.finish(.failure(StreamError.resolveFailed))
            }
        }
    }

    private func start(_ embed: StreamEmbed) {
        let controller = WKUserContentController()
        controller.add(self, name: "zystream")
        controller.addUserScript(WKUserScript(source: Self.hookSource,
                                               injectionTime: .atDocumentStart, forMainFrameOnly: false))
        let config = WKWebViewConfiguration()
        config.userContentController = controller
        config.mediaTypesRequiringUserActionForPlayback = []

        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 1280, height: 720), configuration: config)
        view.customUserAgent = StreamProviderUserAgent.value
        view.navigationDelegate = self
        webView = view

        guard let url = URL(string: embed.url) else {
            finish(.failure(StreamError.badURL))
            return
        }
        var request = URLRequest(url: url)
        request.setValue(embed.referer ?? "", forHTTPHeaderField: "Referer")
        request.setValue(StreamProviderUserAgent.value, forHTTPHeaderField: "User-Agent")
        view.load(request)
    }

    // MARK: - JWPlayer path

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            self.tapToStartIfNeeded()
            self.attemptJWPlayer()
        }
    }

    // MARK: - Tap-to-start path (Dizipal / Playerjs)

    /// Playerjs'li dplayer sayfası `$("body").click(initP)` ile bekliyor; tıklama
    /// `openPlayer(…, subtitles)`'ı çağırıyor, o da `source2.php` → master.m3u8
    /// istiyor (sniffer yakalar). Tıklamadan önce `openPlayer` sarılır: son
    /// argümanı `[{file,label,kind,lang}]` altyazı listesi, "TRACKS" olarak iletilir.
    private static let tapJS = """
    (function () {
      var original = window.openPlayer;
      if (typeof original === 'function' && !original.__zy) {
        var wrapped = function () {
          try {
            var subs = arguments[arguments.length - 1];
            if (Array.isArray(subs)) {
              window.webkit.messageHandlers.zystream.postMessage('TRACKS ' + JSON.stringify(subs));
            }
          } catch (e) {}
          return original.apply(this, arguments);
        };
        wrapped.__zy = true;
        window.openPlayer = wrapped;
      }
      if (document.body) { document.body.click(); }
    })();
    """

    private func tapToStartIfNeeded() {
        guard embed?.tapToStart == true, continuation != nil, let webView else { return }
        webView.evaluateJavaScript(Self.tapJS, completionHandler: nil)
    }

    /// Playerjs'in altyazı listesini JWPlayer yolunun indiricisine uygun biçime
    /// getirip (`lang` → `language`) arka planda indirmeye başlar.
    private func handleTracks(_ json: String) {
        guard trackTask == nil,
              let data = json.data(using: .utf8),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              !list.isEmpty else { return }
        let tracks = list.map { track -> [String: Any] in
            var track = track
            if track["language"] == nil, let lang = track["lang"] { track["language"] = lang }
            return track
        }
        trackTask = Task { [weak self] in
            await self?.fetchJWSubtitles(tracks) ?? []
        }
    }

    private func attemptJWPlayer() {
        guard !jwAttempted, continuation != nil, let webView else { return }
        jwAttempted = true
        Task { @MainActor in
            guard let raw = try? await webView.callAsyncJavaScript(
                    Self.jwReadJS, arguments: [:], in: nil, contentWorld: .page) as? String,
                  !raw.isEmpty,
                  let data = raw.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let file = object["file"] as? String,
                  let mediaURL = URL(string: file) else { return }

            let trackDicts = object["tracks"] as? [[String: Any]] ?? []
            let subs = await fetchJWSubtitles(trackDicts)
            finish(.success(ResolvedStream(
                url: mediaURL,
                headers: ["Referer": resultReferer, "User-Agent": StreamProviderUserAgent.value],
                subtitles: subs
            )))
        }
    }

    /// Downloads each JWPlayer subtitle into a temp file, and marks the smaller of
    /// two same-language tracks as forced ("… (Zorunlu)").
    ///
    /// Two routes, because the sites split on where the tracks live:
    ///
    ///   * **Same origin as the embed** (HdFilmCehennemi): the files are behind the
    ///     site's Cloudflare gate, so they have to be read on the web view, which
    ///     holds the clearance cookie.
    ///   * **A separate CDN** (Dizipal's player serves its `.vtt` off the media
    ///     host): the web view *cannot* read those — the CDN sends no
    ///     `Access-Control-Allow-Origin`, so the in-page fetch dies on CORS. A
    ///     plain request works instead, but only with the embed's origin as
    ///     `Referer`; without it the CDN answers 403.
    ///
    /// Each route falls back to the other, so a site that moves its subtitles from
    /// one arrangement to the other keeps working.
    private func fetchJWSubtitles(_ tracks: [[String: Any]]) async -> [StreamSubtitle] {
        var collected: [(label: String, url: URL, size: Int)] = []
        for track in tracks {
            let kind = (track["kind"] as? String ?? "captions").lowercased()
            guard kind == "captions" || kind == "subtitles", let file = track["file"] as? String else { continue }
            let absolute = file.hasPrefix("http") ? file : (resultReferer.dropLast() + file)
            guard let text = await fetchSubtitleText(String(absolute)),
                  let tempURL = Self.writeTempVTT(text) else { continue }
            collected.append((Self.label(for: track), tempURL, text.utf8.count))
        }
        return Self.applyForcedFlags(collected)
    }

    private func fetchSubtitleText(_ url: String) async -> String? {
        let sameOrigin = url.hasPrefix(resultReferer)
        let routes: [() async -> String?] = sameOrigin
            ? [{ await self.viaWebView(url) }, { await self.viaDirectRequest(url) }]
            : [{ await self.viaDirectRequest(url) }, { await self.viaWebView(url) }]
        for route in routes {
            if let text = await route(), !text.isEmpty { return text }
        }
        return nil
    }

    private func viaWebView(_ url: String) async -> String? {
        guard let webView else { return nil }
        let js = "const r = await fetch(u, { credentials: 'include' }); if (!r.ok) return ''; return await r.text();"
        return try? await webView.callAsyncJavaScript(
            js, arguments: ["u": url], in: nil, contentWorld: .page) as? String
    }

    private func viaDirectRequest(_ url: String) async -> String? {
        guard let target = URL(string: url) else { return nil }
        var request = URLRequest(url: target)
        request.timeoutInterval = 15
        request.setValue(StreamProviderUserAgent.value, forHTTPHeaderField: "User-Agent")
        request.setValue(resultReferer, forHTTPHeaderField: "Referer")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              !data.isEmpty else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Turkish name for a track: "Turkish" and `tur` both become "Türkçe".
    ///
    /// Players label their tracks in whatever language they please — Dizipal's
    /// sends English names and no `language` field at all — so the label, the
    /// language field and the file name are each tried against the language table
    /// before falling back to the raw text.
    private static func label(for track: [String: Any]) -> String {
        let rawLabel = (track["label"] as? String ?? "")
        let language = track["language"] as? String ?? ""
        let file = track["file"] as? String ?? ""

        // "Türkçe Altyazı" / "English subtitles" / "Turkish (Forced)" all have to
        // reduce to the bare language name before the table can match them.
        let cleanedLabel = Self.stripDecoration(rawLabel)

        var base = "Altyazı"
        if let alpha3 = [language, cleanedLabel].lazy
            .filter({ !$0.isEmpty })
            .compactMap({ SubtitleLanguage.alpha3(forAnyForm: $0) }).first {
            base = SubtitleLanguage.displayName(alpha3: alpha3)
        } else if let fromFile = URL(string: file).flatMap(Self.languageName(fromFileName:)) {
            base = fromFile
        } else if !cleanedLabel.isEmpty {
            base = cleanedLabel
        }

        let forced = rawLabel.localizedCaseInsensitiveContains("zorunlu")
            || rawLabel.localizedCaseInsensitiveContains("forced")
            || language.localizedCaseInsensitiveContains("forced")
            || file.localizedCaseInsensitiveContains("forced")
        return forced ? "\(base) (Zorunlu)" : base
    }

    /// Drops the words that decorate a language name so the table can match it:
    /// "Türkçe Altyazı" → "Türkçe", "English (Forced)" → "English".
    private static func stripDecoration(_ label: String) -> String {
        let noise = ["altyazı", "altyazi", "subtitles", "subtitle", "captions",
                     "caption", "forced", "zorunlu", "dublaj", "dub"]
        var out = label
        for word in noise {
            out = out.replacingOccurrences(of: word, with: " ",
                                           options: [.caseInsensitive, .diacriticInsensitive])
        }
        return out.trimmingCharacters(in: CharacterSet(charactersIn: " ()[]-_.·"))
    }

    /// Language read out of a subtitle file name, e.g. `…_tur.vtt` → "Türkçe".
    private static func languageName(fromFileName url: URL) -> String? {
        let stem = url.deletingPathExtension().lastPathComponent
        for token in stem.components(separatedBy: CharacterSet(charactersIn: "-_. []()")) {
            let candidate = token.trimmingCharacters(in: .whitespaces).lowercased()
            guard candidate.count >= 2, candidate.count <= 12 else { continue }
            if let alpha3 = SubtitleLanguage.alpha3(forAnyForm: candidate) {
                return SubtitleLanguage.displayName(alpha3: alpha3)
            }
        }
        return nil
    }

    /// Marks the smaller of two same-label tracks as forced, when the labels did
    /// not already distinguish them.
    private static func applyForcedFlags(_ items: [(label: String, url: URL, size: Int)]) -> [StreamSubtitle] {
        var result = items
        var groups: [String: [Int]] = [:]
        for (index, item) in items.enumerated() { groups[item.label, default: []].append(index) }
        for (label, indices) in groups where indices.count > 1 && !label.contains("Zorunlu") {
            if let smallest = indices.min(by: { items[$0].size < items[$1].size }) {
                result[smallest].label = "\(label) (Zorunlu)"
            }
        }
        return result.map { StreamSubtitle(url: $0.url, label: $0.label) }
    }

    private static func writeTempVTT(_ text: String) -> URL? {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZyStreamSubs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(UUID().uuidString).vtt")
        do { try text.write(to: url, atomically: true, encoding: .utf8); return url } catch { return nil }
    }

    private static func origin(of urlString: String) -> String? {
        guard let url = URL(string: urlString), let host = url.host else { return nil }
        return "\(url.scheme ?? "https")://\(host)/"
    }

    // MARK: - Sniffer path (fallback)

    nonisolated func userContentController(_ controller: WKUserContentController,
                                           didReceive message: WKScriptMessage) {
        guard let urlString = message.body as? String else { return }
        Task { @MainActor in self.handleCandidate(urlString) }
    }

    private func handleCandidate(_ tagged: String) {
        guard continuation != nil else { return }
        if tagged.hasPrefix("TRACKS ") {
            handleTracks(String(tagged.dropFirst(7)))
            return
        }
        let isSubtitle = tagged.hasPrefix("SUB ")
        let urlString = String(tagged.dropFirst(isSubtitle ? 4 : 6))
        guard let url = URL(string: urlString) else { return }

        if isSubtitle {
            if !subtitles.contains(where: { $0.url == url }) {
                subtitles.append(StreamSubtitle(url: url, label: Self.subtitleLabel(for: url)))
            }
            return
        }
        guard mediaURL == nil else { return }
        mediaURL = url
        graceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1600))
            guard !Task.isCancelled else { return }
            self?.completeWithMedia()
        }
    }

    private func completeWithMedia() {
        guard let url = mediaURL else { return }
        let headers = ["Referer": resultReferer, "User-Agent": StreamProviderUserAgent.value]
        let needsLocalCopy = embed?.localizePlaylists == true
        guard needsLocalCopy || trackTask != nil else {
            finish(.success(ResolvedStream(url: url, headers: headers, subtitles: subtitles)))
            return
        }

        // Adres bulundu; kalan iş (listeleri ve altyazıları indirmek) kendi ağ
        // zaman aşımlarıyla sınırlı. Embed zaman aşımı bunu yarıda kesmesin.
        timeoutTask?.cancel(); timeoutTask = nil
        let current = session
        let tracks = trackTask
        let sniffed = subtitles
        Task { @MainActor [weak self] in
            var playURL = url
            if needsLocalCopy, let local = await HLSPlaylistLocalizer.localize(url, headers: headers) {
                playURL = local
            }
            let fetched = await tracks?.value ?? []
            guard let self, self.session == current else { return }
            self.finish(.success(ResolvedStream(
                url: playURL, headers: headers,
                subtitles: fetched.isEmpty ? sniffed : fetched
            )))
        }
    }

    private static func subtitleLabel(for url: URL) -> String {
        let lowered = url.absoluteString.lowercased()
        let forced = lowered.contains("forced") || lowered.contains("zorunlu")
        let fileName = url.deletingPathExtension().lastPathComponent
        var candidates = [fileName]
        candidates += url.pathComponents
        candidates += fileName.components(separatedBy: CharacterSet(charactersIn: "-_. []()"))
        for candidate in candidates {
            let token = candidate.trimmingCharacters(in: .whitespaces).lowercased()
            guard token.count >= 2, token.count <= 12 else { continue }
            if let alpha3 = SubtitleLanguage.alpha3(forAnyForm: token) {
                let name = SubtitleLanguage.displayName(alpha3: alpha3)
                return forced ? "\(name) (Zorunlu)" : name
            }
        }
        return forced ? "\(fileName) (Zorunlu)" : fileName
    }

    private func finish(_ result: Result<ResolvedStream, Error>) {
        teardown(resumingWith: result)
    }

    private func teardown(resumingWith result: Result<ResolvedStream, Error>) {
        timeoutTask?.cancel(); timeoutTask = nil
        graceTask?.cancel(); graceTask = nil
        mediaURL = nil
        subtitles = []
        jwAttempted = false
        trackTask = nil
        if let view = webView {
            view.navigationDelegate = nil
            view.stopLoading()
            view.configuration.userContentController.removeAllUserScripts()
            view.configuration.userContentController.removeScriptMessageHandler(forName: "zystream")
            webView = nil
        }
        if let cont = continuation {
            continuation = nil
            cont.resume(with: result)
        }
    }
}

/// Shared browser User-Agent for both the scrapers and the resolver, so a CDN
/// that pinned the manifest request to a UA sees the same one on the media fetch.
enum StreamProviderUserAgent {
    static let value =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
        + "(KHTML, like Gecko) Version/17.4 Safari/605.1.15"
}
