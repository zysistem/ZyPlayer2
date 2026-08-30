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
            section: nil, selector: "a.poster", langSelector: ".poster-lang", kind: .movie, limit: 10
        )
        async let series = shelf(
            title: "Son Eklenen Bölümler", path: "/yabancidiziizle-5/",
            section: "Son Eklenen Yabancı Dizi Bölümleri", selector: "a.mini-poster",
            langSelector: ".mini-poster-lang", kind: .series, limit: 10
        )
        return await [films, series].filter { !$0.hits.isEmpty }
    }

    @MainActor
    private func shelf(title: String, path: String, section: String?, selector: String,
                       langSelector: String, kind: StreamKind, limit: Int) async -> StreamShelf {
        let js = Self.extractionJS(sectionTitle: section, selector: selector, langSelector: langSelector)
        let raw = (try? await StreamPageRenderer().render(baseURL + path, extractionJS: js)) as? String ?? "[]"
        let hits = Self.hits(fromCardsJSON: raw, kind: kind, providerID: id, providerName: displayName)
        return StreamShelf(title: title, hits: Array(hits.prefix(limit)))
    }

    /// Extraction script for lazy-loaded cards. Scrolls once to force the posters
    /// in, then reads each card's rendered image URL and title (from `title` or the
    /// image `alt`). When `sectionTitle` is given, only the section whose header
    /// contains it is read — so "Son Eklenen Yabancı Dizi Bölümleri" is taken and
    /// "Yakında Gelecek Yabancı Diziler" is left out.
    ///
    /// `langSelector` (`.poster-lang` / `.mini-poster-lang`) is the site's own
    /// dil rozeti: içinde `.tr-flag` varsa Türkçe dublaj var demektir, yoksa
    /// yalnızca altyazı — kart üzerinde "Dublaj"/"Altyazılı" olarak gösteriliyor.
    private static func extractionJS(sectionTitle: String?, selector: String, langSelector: String) -> String {
        let sectionLiteral = sectionTitle.map { "\"\($0)\"" } ?? "null"
        return """
        window.scrollTo(0, document.body.scrollHeight);
        await new Promise(function (r) { setTimeout(r, 1400); });
        function map(cards) {
          return Array.from(cards).map(function (a) {
            var img = a.querySelector('img');
            var langEl = a.querySelector('\(langSelector)');
            var dub = !!(langEl && langEl.querySelector('.tr-flag'));
            return { href: a.href,
                     title: (a.getAttribute('title') || (img && img.getAttribute('alt')) || '').trim(),
                     poster: (img && (img.currentSrc || img.src)) || '',
                     lang: langEl ? (dub ? 'dub' : 'sub') : '' };
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
                pageURL: href,
                audioLabel: Self.audioLabel(fromLangCode: card["lang"])
            )
        }
    }

    /// `"dub"` → "Dublaj", `"sub"` → "Altyazılı", anything else (rozet
    /// bulunamadı) → nil.
    private static func audioLabel(fromLangCode code: String?) -> String? {
        switch code {
        case "dub": "Dublaj"
        case "sub": "Altyazılı"
        default: nil
        }
    }

    // MARK: - Categories (site menu → sidebar Filmler / Diziler)

    /// Dizi görünümünün ilk (varsayılan) sekmesi: sitenin "Yabancı Dizi İzle"
    /// listesi. Kullanıcı Diziler'e girince önce buradakiler açılıyor.
    private static let seriesIndexPath = "/yabancidiziizle-5/"

    /// Dizi görünümüne konacak, en çok kullanılan tür başlıkları (sadeleştirilmiş
    /// hâlleriyle). Site menüsündeki güncel `/tur/` bağlantılarından bu başlığa
    /// sahip olanlar seçiliyor — böylece slug'lar sürüm alsa da (ör.
    /// "aksiyon-filmleri-izleyin-8") kırılmıyor.
    private static let popularSeriesGenres = [
        "Aksiyon", "Dram", "Komedi", "Gerilim", "Bilim Kurgu",
        "Korku", "Suç", "Fantastik", "Romantik", "Macera"
    ]

    /// Sitenin menüsündeki kategoriler.
    ///
    /// - **Filmler**: anasayfadaki "Türlerine Göre Filmler" (tüm `/tur/` türleri)
    ///   ve altındaki "Özel Kategoriler" (DC/Marvel/Amazon/1080p gibi `/category/`
    ///   koleksiyonları) — ikisi de bölüm başlığından ayıklanıyor, uydurma
    ///   kategori eklenmiyor.
    /// - **Diziler**: ilk sırada "Diziler" (yabancı dizi listesi), ardından en çok
    ///   kullanılan 10 tür.
    ///
    /// Saklanan `pageURL` mutlak değil **yol**: kartlar çekilirken sağlayıcının o
    /// anki `baseURL`'iyle birleştiriliyor, böylece site adresi değişse
    /// (ayarlardan güncellense) bağlantılar kendiliğinden takip ediyor.
    /// İstenmeyen kategoriler — yolunda bu parçalardan biri geçen bağlantılar
    /// listeye alınmıyor.
    private static let excludedCategoryPaths = ["action-adventure", "reality-tv", "1080p"]

    private static func isExcluded(_ path: String) -> Bool {
        excludedCategoryPaths.contains { path.contains($0) }
    }

    func categories(for kind: StreamKind) async throws -> [StreamCategory] {
        let html = try await load(baseURL)
        // Başlıklardaki HTML varlıkları çözülüyor ("Sci-Fi &amp; Fantasy" → "Sci-Fi
        // & Fantasy"). İstenmeyen türler (Action & Adventure, Reality-TV) eleniyor.
        let genres = Self.sectionLinks(in: html, heading: "Türlerine Göre Filmler", pathContains: "/tur/")
            .filter { !Self.isExcluded($0.path) }
            .map { (title: Self.cleanGenreTitle(decodeEntities($0.title)), path: $0.path) }

        if kind == .series {
            var out = [StreamCategory(providerID: id, title: "Diziler", pageURL: Self.seriesIndexPath)]
            for name in Self.popularSeriesGenres {
                if let g = genres.first(where: { $0.title.caseInsensitiveCompare(name) == .orderedSame }) {
                    out.append(StreamCategory(providerID: id, title: g.title, pageURL: g.path))
                }
            }
            return out
        }

        // Filmler: türler + özel kategoriler. Özel kategoriler yalnızca
        // `/category/` değil; menüde `/ulke/` (Japonya/Kore/Hint/Türk) ve
        // `/serifilmlerim…` de var — bu yüzden bölümdeki **tüm** bağlantılar
        // alınıyor (1080p elenir).
        var out = genres.map { StreamCategory(providerID: id, title: $0.title, pageURL: $0.path) }
        let special = Self.sectionLinks(in: html, heading: "Özel Kategoriler", pathContains: "")
            .filter { !Self.isExcluded($0.path) }
        out += special.map { StreamCategory(providerID: id, title: decodeEntities($0.title), pageURL: $0.path) }
        return out
    }

    /// Belirli bir başlıktan sonraki, `pathContains` içeren bağlantıları (metin +
    /// yol) döndürür — bir sonraki `<h...>`/`<h2>` başlığına kadar. Böylece
    /// "Türlerine Göre Filmler" ile "Özel Kategoriler" bölümleri birbirine
    /// karışmıyor.
    private static func sectionLinks(in html: String, heading: String,
                                     pathContains: String) -> [(title: String, path: String)] {
        let ns = html as NSString
        let headRange = ns.range(of: heading)
        guard headRange.location != NSNotFound else { return [] }
        let start = headRange.location + headRange.length
        // Bölümün sonu: sonraki başlık etiketi (<h1..h4) ya da belgenin sonu.
        var end = ns.length
        if let nextHead = try? NSRegularExpression(pattern: "<h[1-4][\\s>]", options: [.caseInsensitive]),
           let m = nextHead.firstMatch(in: html, range: NSRange(location: start, length: ns.length - start)) {
            end = m.range.location
        }
        let segment = ns.substring(with: NSRange(location: start, length: end - start))
        // Boş `pathContains`: bölümdeki her bağlantı (özel kategoriler farklı yol
        // önekleri taşıyor). Doluysa yalnızca o yolu içerenler.
        let pattern = pathContains.isEmpty
            ? "<a[^>]+href=\"([^\"]+)\"[^>]*>([^<]+)</a>"
            : "<a[^>]+href=\"([^\"]*?\(NSRegularExpression.escapedPattern(for: pathContains))[^\"]*?)\"[^>]*>([^<]+)</a>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let sns = segment as NSString
        var seen = Set<String>()
        var out: [(String, String)] = []
        for m in regex.matches(in: segment, range: NSRange(location: 0, length: sns.length)) {
            let href = sns.substring(with: m.range(at: 1))
            let path = URL(string: href)?.path ?? href
            guard seen.insert(path).inserted else { continue }
            let title = sns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            out.append((title, path))
        }
        return out
    }

    /// "Aksiyon Filmleri" → "Aksiyon"; " Film…" ekini atar.
    private static func cleanGenreTitle(_ raw: String) -> String {
        var t = raw
        if let r = t.range(of: " Film") { t = String(t[..<r.lowerBound]) }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Bir kategori sayfasındaki kartların **tamamı** (sayfalama izlenerek).
    ///
    /// Sayfa Cloudflare arkasında ve sayfalama sitenin kendi AJAX'ıyla yapılıyor:
    /// numaralı sayfalar `GET /load/page/{N}/{action}/` uç noktasından JSON olarak
    /// (`{html, meta}`) geliyor; `action`, ilk sayfadaki
    /// `.pagination-container[data-page-action]`'da yazılı (tür sayfasında
    /// `genres/…`, dizi listesinde `home-series`, ülke sayfasında `countries/…`).
    /// Bu yüzden sayfa bir kez gerçek tarayıcıda render edilip, aynı bağlam içinden
    /// sonraki sayfalar `fetch` ile çekiliyor (Cloudflare çerezi taşındığı için
    /// çalışıyor) ve tüm kartlar birleştiriliyor. Hepsi tek çağrıda geldiği için
    /// yalnızca `page == 1` iş yapar; sonrası boş döner (çağıran durur).
    ///
    /// Kart üzerindeki yıl ve IMDb puanı da okunuyor (`.poster-meta`). Kind
    /// href'ten çıkarılıyor — dizi bağlantıları `/dizi/` taşır — böylece aynı sayfa
    /// hem "Filmler" hem "Diziler" görünümünü besleyebiliyor.
    @MainActor
    func categoryHits(_ pageURL: String, page: Int) async throws -> [StreamHit] {
        guard page == 1 else { return [] }
        let raw = (try? await StreamPageRenderer().render(
            absolute(pageURL),
            extractionJS: Self.categoryExtractionJS(maxPages: 20),
            settle: .seconds(2), timeout: .seconds(90)
        )) as? String ?? "[]"
        guard let data = raw.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] else { return [] }
        var seen = Set<String>()
        return array.compactMap { card in
            guard let href = card["href"], !href.isEmpty, seen.insert(href).inserted,
                  let title = card["title"], !title.isEmpty else { return nil }
            let poster = card["poster"]?.replacingOccurrences(of: "/thumb/", with: "/list/")
            return StreamHit(
                providerID: id, providerName: displayName,
                kind: href.contains("/dizi/") ? .series : .movie,
                title: title,
                year: card["year"].flatMap { Int($0.prefix(4)) },
                posterURL: poster.flatMap { URL(string: $0) },
                pageURL: href,
                imdbRating: card["imdb"].flatMap(Double.init),
                audioLabel: Self.audioLabel(fromLangCode: card["lang"])
            )
        }
    }

    /// Kategori sayfası için çıkarma betiği: ilk sayfanın kartlarını DOM'dan okur,
    /// ardından `.pagination-container`'daki `data-page-action`/`data-pages`'i alıp
    /// `/load/page/{N}/{action}/` uç noktasından sonraki sayfaları JSON olarak
    /// çeker (en çok `maxPages`), her kartın href/başlık/afiş/yıl/IMDb'sini toplar.
    /// Yalnızca ana grid'in `a.poster`'ları alınır — kenar çubuğundaki
    /// `.mini-poster` öneriler dışarıda kalır. `data-src` gerçek afiş adresidir
    /// (hem render edilmiş sayfada hem AJAX parçasında dolu).
    private static func categoryExtractionJS(maxPages: Int) -> String {
        """
        function harvest(root, map){
          root.querySelectorAll('a.poster').forEach(function(a){
            var img = a.querySelector('img');
            var poster = img ? (img.getAttribute('data-src') || img.currentSrc || img.getAttribute('src') || '') : '';
            if (poster.indexOf('data:') === 0) poster = (img && img.currentSrc) || '';
            var href = a.href || a.getAttribute('href');
            if (!href || !poster || poster.indexOf('data:') === 0 || map.has(href)) return;
            var meta = a.querySelector('.poster-meta');
            var year = '', imdb = '';
            if (meta) {
              var spans = meta.querySelectorAll('span');
              if (spans.length) year = (spans[0].textContent || '').replace(/[^0-9]/g,'');
              var im = meta.querySelector('.imdb');
              if (im) imdb = (im.textContent || '').replace(/[^0-9.]/g,'');
            }
            var langEl = a.querySelector('.poster-lang');
            var dub = !!(langEl && langEl.querySelector('.tr-flag'));
            map.set(href, {
              href: href,
              title: (a.getAttribute('title') || (img && img.getAttribute('alt')) || '').trim(),
              poster: poster, year: year, imdb: imdb,
              lang: langEl ? (dub ? 'dub' : 'sub') : ''
            });
          });
        }
        var map = new Map();
        harvest(document, map);
        var pag = document.querySelector('.pagination-container');
        var action = pag ? pag.getAttribute('data-page-action') : null;
        var pages = pag ? (parseInt(pag.getAttribute('data-pages')) || \(maxPages)) : \(maxPages);
        var start = 2;
        if (!action) {
          // `/category/{slug}/` koleksiyon sayfalarında pagination yok ve ilk
          // sayfa da AJAX'tan geliyor (DOM'da tek örnek kart var). Action buradan
          // türetilir: `categories/{slug}`; toplama ilk sayfadan başlar.
          var parts = location.pathname.split('/').filter(Boolean);
          if (parts[0] === 'category' && parts[1]) { action = 'categories/' + parts[1]; start = 1; }
        }
        if (action) {
          var last = Math.min(pages, \(maxPages));
          for (var n = start; n <= last; n++) {
            try {
              var r = await fetch('/load/page/' + n + '/' + action + '/', { headers: { 'X-Requested-With': 'fetch' } });
              var j = await r.json();
              var d = new DOMParser().parseFromString(j.html || '', 'text/html');
              var before = map.size;
              harvest(d, map);
              if (map.size === before) break;
            } catch (e) { break; }
          }
        }
        return JSON.stringify(Array.from(map.values()));
        """
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
        var embeds: [StreamEmbed] = []
        for raw in iframes {
            let url = absolute(raw.replacingOccurrences(of: "&amp;", with: "&"))
            guard seen.insert(url).inserted else { continue }
            embeds.append(StreamEmbed(url: url, referer: pageURL, label: displayName))
        }

        // İkinci sunucu ("Rapidrame") için AJAX'a gerek yok: varsayılan ("Close")
        // embed'in URL'sinde `?rapidrame_id=XXX` zaten var ve Rapidrame sunucusu
        // basitçe `{base}/rplayer/XXX/` adresi. Onu da listeye ekliyoruz ki Close
        // 8 sn'de çözülmezse çözümleyici buna geçsin. `/rplayer/` sayfası zaten
        // StreamResolver'ın JWPlayer yolunun tam beklediği biçim.
        if let rid = firstMatch("rapidrame_id=([A-Za-z0-9]+)", in: html) {
            let rapidrame = absolute("/rplayer/\(rid)/")
            if seen.insert(rapidrame).inserted {
                embeds.append(StreamEmbed(url: rapidrame, referer: pageURL, label: "Rapidrame"))
            }
        }

        guard !embeds.isEmpty else { throw StreamError.noEmbed }
        return embeds
    }
}
