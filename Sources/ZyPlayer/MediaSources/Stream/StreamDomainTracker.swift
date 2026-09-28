import Foundation

/// Akış sitelerinin taşıdığı alan adını kendiliğinden takip eder.
///
/// Bu siteler birkaç günde bir alan adı değiştiriyor ve yenisini kapanmadan
/// önce ana sayfadaki duyuru şeridinde ilan ediyor ("Sonraki adresimiz
/// Dizipal2109.com olacaktır"). Elle güncellemek unutulduğunda kaynak tamamen
/// kayboluyor — eski adres öldüğünde yenisinin ne olduğunu söyleyecek bir yer
/// kalmıyor. Bu yüzden duyuru site *ayaktayken* okunup saklanır.
///
/// Adres üç kademede bulunur, sırayla:
///
///   1. **Kayıtlı adres** hâlâ ayaktaysa hiçbir şey değişmez; yalnızca duyuru
///      tazelenir.
///   2. **Önceden saklanan duyuru** — sitenin kendi söylediği adres.
///   3. **Sayısal tahmin** — duyuru hiç yakalanamamışsa: bu siteler adlarının
///      sonundaki sayıyı birer birer artırıyor (`dizipal2108` → `dizipal2109`),
///      dolayısıyla birkaç ardıl denenerek bulunabiliyor.
enum StreamDomainTracker {

    struct Outcome {
        var baseURL: String
        /// Sitenin duyurduğu bir sonraki adres, biliniyorsa.
        var announcedNext: String?
        /// Adres bu denetimde gerçekten değişti mi.
        var didMove: Bool
    }

    /// Kaç ardıl sayı denenecek. Site iki günde bir taşınıyor; bu, uygulama
    /// haftalarca açılmamış olsa bile yetişecek kadar geniş, kör bir taramaya
    /// dönüşmeyecek kadar dar.
    private static let probeDepth = 10

    // MARK: - Denetim

    static func refresh(baseURL: String, announcedNext: String?) async -> Outcome {
        // 1. Kayıtlı adresi getir — yönlendirmeleri izleyerek indiği *son* adrese
        //    bak. Bu siteler eski adresten yenisine 301 ile yönlendiriyor
        //    (dizipal2108 → dizipal2109); son adresin konağı değişmişse taşınma
        //    budur, en güçlü ve en doğrudan sinyal.
        if let result = await fetch(baseURL), isLive(result.html) {
            let landed = origin(of: result.finalURL) ?? baseURL
            if landed != baseURL {
                return Outcome(baseURL: landed,
                               announcedNext: announced(in: result.html, current: landed),
                               didMove: true)
            }
            return Outcome(baseURL: baseURL,
                           announcedNext: announced(in: result.html, current: baseURL) ?? announcedNext,
                           didMove: false)
        }

        // 2/3. Kapanmış (ya da yönlendirmesiz ölmüş): sitenin duyurduğu adres,
        //      sonra sayısal ardıllar.
        for candidate in candidates(from: baseURL, announced: announcedNext) {
            guard let result = await fetch(candidate), isLive(result.html) else { continue }
            let landed = origin(of: result.finalURL) ?? candidate
            return Outcome(baseURL: landed,
                           announcedNext: announced(in: result.html, current: landed),
                           didMove: true)
        }

        // Hiçbiri tutmadı: kayıtlı adres olduğu gibi kalır. Geçici bir ağ
        // arızasında adresi bozmamak, taşınmayı bir sonraki denetime bırakmaktan
        // daha güvenli.
        return Outcome(baseURL: baseURL, announcedNext: announcedNext, didMove: false)
    }

    /// "https://dizipal2109.com/dizi/…" → "https://dizipal2109.com". Yolu ve
    /// sorguyu atıp yalnızca şema+konağı bırakır; adres olarak saklanan biçim bu.
    private static func origin(of url: URL) -> String? {
        guard let scheme = url.scheme, let host = url.host else { return nil }
        return "\(scheme)://\(host)"
    }

    /// Bütün akış kaynaklarını denetler ve değişeni ayarlara yazar.
    /// Dönen liste, adresi değişen kaynakların görünen adları.
    @MainActor
    @discardableResult
    static func refreshAll(settings: AppSettings) async -> [String] {
        var sources = settings.streamSources
        var moved: [String] = []
        var changed = false

        for index in sources.indices {
            let source = sources[index]
            let outcome = await refresh(baseURL: source.baseURL,
                                        announcedNext: source.nextBaseURL.isEmpty ? nil : source.nextBaseURL)
            if outcome.baseURL != source.baseURL {
                sources[index].baseURL = outcome.baseURL
                changed = true
                moved.append(StreamRegistry.info(id: source.id)?.displayName ?? source.id)
            }
            let next = outcome.announcedNext ?? ""
            if next != source.nextBaseURL {
                sources[index].nextBaseURL = next
                changed = true
            }
        }

        if changed { settings.streamSources = sources }
        return moved
    }

    // MARK: - Adres çözümleme

    /// "https://dizipal2108.com" → ("dizipal", 2108, "com")
    /// Sayı ile bitmeyen bir ad (ör. "hdfilmcehennemi.nl") için nil.
    static func parts(of baseURL: String) -> (stem: String, number: Int, suffix: String)? {
        guard var host = URL(string: baseURL)?.host?.lowercased() else { return nil }
        if host.hasPrefix("www.") { host = String(host.dropFirst(4)) }

        // İlk nokta adı uzantıdan ayırır: "dizipal2108" + "com"
        guard let dot = host.firstIndex(of: ".") else { return nil }
        let name = String(host[host.startIndex..<dot])
        let suffix = String(host[host.index(after: dot)...])

        let digits = name.suffix(while: \.isNumber)
        guard !digits.isEmpty, let number = Int(digits) else { return nil }
        let stem = String(name.dropLast(digits.count))
        guard !stem.isEmpty else { return nil }
        return (stem, number, suffix)
    }

    /// Denenecek adresler: önce sitenin duyurduğu, sonra sayısal ardıllar.
    private static func candidates(from baseURL: String, announced: String?) -> [String] {
        var list: [String] = []
        if let announced, !announced.isEmpty, announced != baseURL { list.append(announced) }

        if let (stem, number, suffix) = parts(of: baseURL) {
            for step in 1...probeDepth {
                let candidate = "https://\(stem)\(number + step).\(suffix)"
                if !list.contains(candidate) { list.append(candidate) }
            }
        }
        return list
    }

    /// Sayfadaki duyurudan bir sonraki adresi okur.
    ///
    /// Duyuru cümlesinin sözlerine değil, alan adının kendi biçimine bakılır:
    /// sayfada geçen, aynı köke sahip ve numarası şimdikinden büyük olan en
    /// küçük adres alınır. Site duyuru metnini değiştirse de bu tutar.
    static func announced(in html: String, current: String) -> String? {
        guard let (stem, number, suffix) = parts(of: current) else { return nil }

        let pattern = "\(NSRegularExpression.escapedPattern(for: stem))([0-9]{1,6})\\.\(NSRegularExpression.escapedPattern(for: suffix))"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }

        let range = NSRange(html.startIndex..., in: html)
        var best: Int?
        for match in regex.matches(in: html, range: range) {
            guard match.numberOfRanges > 1,
                  let digits = Range(match.range(at: 1), in: html),
                  let found = Int(html[digits]), found > number
            else { continue }
            if best == nil || found < best! { best = found }
        }

        guard let next = best else { return nil }
        return "https://\(stem)\(next).\(suffix)"
    }

    // MARK: - Canlılık

    /// Sayfanın gerçek bir içerik sayfası olup olmadığı. Yalnızca HTTP 200'e
    /// bakmak yetmez: satılığa çıkmış ya da park edilmiş bir alan adı da 200
    /// döner.
    ///
    /// Eskiden sayfanın alan adının kökünü ("dizipal") içermesi şart koşuluyordu;
    /// ama bu siteler kendi adlarını HTML içinde hiç geçirmiyor, dolayısıyla
    /// canlı sayfa bile "ölü" sayılıp adres güncellenemiyordu. Artık kök
    /// aranmıyor: yeterince dolu bir HTML belgesi olması ve bilinen park/satılık
    /// imzalarını taşımaması yetiyor.
    private static func isLive(_ html: String) -> Bool {
        guard html.count > 2000 else { return false }
        let lower = html.lowercased()
        let parked = ["domain for sale", "buy this domain", "satılık alan adı",
                      "this domain is parked", "sedoparking", "domain parking",
                      "godaddy.com/domainfind"]
        return !parked.contains(where: lower.contains)
    }

    /// Önce düz bir istek; sayfa Cloudflare arkasındaysa sitenin kendi
    /// tarayıcı tabanlı getiricisine düşülür. Dönen `finalURL`, yönlendirmeler
    /// izlendikten sonra inilen adrestir — taşınmayı yakalamanın anahtarı bu.
    @MainActor
    private static func fetch(_ baseURL: String) async -> (html: String, finalURL: URL)? {
        if let result = await plainFetch(baseURL), result.html.count > 1500 { return result }
        if let html = try? await WebFetcherPool.fetcher(for: baseURL).text(baseURL),
           let url = URL(string: baseURL) {
            return (html, url)
        }
        return nil
    }

    private static func plainFetch(_ baseURL: String) async -> (html: String, finalURL: URL)? {
        guard let url = URL(string: baseURL) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
            + "(KHTML, like Gecko) Chrome/120.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        // URLSession yönlendirmeleri kendiliğinden izler; `response.url` inilen
        // son adrestir (301 dizipal2108 → dizipal2109 burada 2109'a döner).
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode)
        else { return nil }
        guard let html = String(data: data, encoding: .utf8) else { return nil }
        return (html, http.url ?? url)
    }
}

private extension StringProtocol {
    /// Sondan başlayarak koşulu sağlayan parça — "dizipal2108" → "2108".
    func suffix(while predicate: (Character) -> Bool) -> String {
        String(reversed().prefix(while: predicate).reversed())
    }
}
