import Foundation

/// Bir altyazı bloğu: sıra numarası, zaman kodu ve metin.
struct SubtitleCue {
    var index: String
    var timecode: String
    var text: String
}

// MARK: - Ortak yardımcılar

/// Çeviri motorlarının paylaştığı küçük araçlar.
enum TranslationUtil {
    /// Bir altyazı bloğu birden çok satır olabilir ("- Geliyor musun?\n- Hayır").
    /// Toplu çeviride satır sonu aynı zamanda blokları ayıran işaret olduğu için,
    /// blok içindeki satır sonlarını bu göze batmayan işaretle değiştirip çeviri
    /// dönünce geri koyuyoruz. İşaret kaybolursa tek satır olur, veri kaybolmaz.
    static let lineBreakMarker = " ⏎ "

    static func flatten(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: lineBreakMarker)
    }

    static func restore(_ text: String) -> String {
        text.replacingOccurrences(of: lineBreakMarker, with: "\n")
            .replacingOccurrences(of: "⏎", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Google'ın HTML uçları `<i>` gibi etiketleri kaçırılmış olarak döndürür.
    static func decodeHTMLEntities(_ text: String) -> String {
        var out = text
        let map = [
            ("&quot;", "\""), ("&#34;", "\""), ("&#39;", "'"), ("&#x27;", "'"),
            ("&apos;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " "),
            ("&#160;", " "), ("&amp;", "&")   // &amp; en sonda: çift çözmeyi önler
        ]
        for (entity, char) in map {
            out = out.replacingOccurrences(of: entity, with: char)
        }
        return out
    }

    /// Kullanıcının Ayarlar'dan seçtiği modeli başa alıp, geri kalan bilinen
    /// modelleri (tekrarsız) arkasına ekler. `LLMTranslator.translateBatch`
    /// zaten kota/limit hatasında bir sonraki modele geçiyor — bu sıralama
    /// sayesinde kullanıcının seçimi her zaman ilk denenen olur, ama seçtiği
    /// model o an meşgulse/bakiyesizse çeviri yine de sessizce sürer.
    static func fallbackChain(preferred: String, pool: [String]) -> [String] {
        let trimmed = preferred.trimmingCharacters(in: .whitespacesAndNewlines)
        var chain = trimmed.isEmpty ? [] : [trimmed]
        chain.append(contentsOf: pool.filter { $0 != trimmed })
        return chain
    }

    /// Metinleri hem satır sayısına hem de toplam karakter sayısına göre paketler.
    /// Uçların ikisi de tek istekte alabilecekleri metin miktarında sınırlı.
    static func chunks(_ texts: [String], maxLines: Int, maxChars: Int) -> [Range<Int>] {
        var result: [Range<Int>] = []
        var start = 0
        var chars = 0
        for i in texts.indices {
            let next = chars + texts[i].count + 1
            if i > start, next > maxChars || (i - start) >= maxLines {
                result.append(start..<i)
                start = i
                chars = texts[i].count + 1
            } else {
                chars = next
            }
        }
        if start < texts.count { result.append(start..<texts.count) }
        return result
    }
}

// MARK: - Altyazı ayrıştırma

enum SubtitleTranslator {

    /// SRT ya da WebVTT metnini bloklara ayırır.
    static func parse(_ content: String) -> [SubtitleCue] {
        let normalized = content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        let blocks = normalized.components(separatedBy: "\n\n")
        var cues: [SubtitleCue] = []

        for block in blocks {
            let lines = block.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }

            guard let timecodeIndex = lines.firstIndex(where: { $0.contains("-->") }) else {
                continue
            }

            let index = timecodeIndex > 0 ? lines[0] : ""
            let timecode = lines[timecodeIndex]
            let textLines = lines[(timecodeIndex + 1)...]
            let text = textLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

            if !text.isEmpty {
                cues.append(SubtitleCue(index: index, timecode: timecode, text: text))
            }
        }

        return cues
    }

    /// Blokları WebVTT olarak yeniden yazar; mpv bu biçimi sorunsuz açıyor.
    static func buildWebVTT(cues: [SubtitleCue]) -> String {
        var output = "WEBVTT\n\n"
        for cue in cues {
            if !cue.index.isEmpty {
                output += "\(cue.index)\n"
            }
            // SRT'nin virgüllü zaman kodunu WebVTT'nin noktalısına çevir
            let normalizedTimecode = cue.timecode.replacingOccurrences(of: ",", with: ".")
            output += "\(normalizedTimecode)\n"
            output += "\(cue.text)\n\n"
        }
        return output
    }

    /// Bir cue'nun başlangıç saniyesi — `"00:12:34,560 --> 00:12:36,000"` ya
    /// da noktalı VTT biçimi. Çeviriye kullanıcının şu an olduğu zamandan
    /// başlamak için kullanılıyor: baştan çevirmenin, izlenmiş kısmı önce
    /// bitirmenin kullanıcıya bir faydası yok, önemli olan az sonra göreceği
    /// satırlar.
    static func startSeconds(ofTimecode timecode: String) -> Double? {
        guard let arrowRange = timecode.range(of: "-->") else { return nil }
        let start = timecode[..<arrowRange.lowerBound]
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: ".")
        let parts = start.split(separator: ":")
        guard parts.count == 3,
              let hours = Double(parts[0]), let minutes = Double(parts[1]),
              let seconds = Double(parts[2]) else { return nil }
        return hours * 3600 + minutes * 60 + seconds
    }
}

// MARK: - Google (ücretsiz)

/// Google'ın anahtarsız uçlarıyla çeviri.
///
/// İki ayrı uç var ve ikisi de resmî değil:
///   1. `translate.google.com/m` — mobil HTML sayfası. Yavaş IP'lerde bile
///      çalışmayı sürdürüyor, sonuç HTML içinde geliyor.
///   2. `translate_a/single` — JSON döndüren eski uç. Daha temiz ama Google
///      bir IP'den çok istek görünce onu "sorry" sayfasına (HTTP 429)
///      yönlendirip kapatıyor; kullanıcının IP'sinde olan tam olarak buydu.
///
/// Bu yüzden sıra HTML ucundan başlıyor, o düşerse JSON ucu deneniyor. Hangisi
/// çalıştıysa iş boyunca o tercih ediliyor.
enum GoogleTranslator {
    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 " +
        "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

    /// Tek istekte gönderilen üst sınırlar. Uç bunların üzerinde sessizce
    /// kırpabiliyor ya da hata veriyor.
    static let maxLinesPerRequest = 60
    static let maxCharsPerRequest = 2500

    enum Transport { case mobileHTML, jsonAPI }

    /// Çalıştığı görülen uç. Partiler paralel gittiği için ortak tutuluyor:
    /// biri hangi ucun ayakta olduğunu öğrenince diğerleri boşuna denemesin.
    private static let transportLock = NSLock()
    private static var preferredTransport = Transport.mobileHTML

    private static var transport: Transport {
        get { transportLock.lock(); defer { transportLock.unlock() }; return preferredTransport }
        set { transportLock.lock(); preferredTransport = newValue; transportLock.unlock() }
    }

    static func translateBatch(_ texts: [String]) async throws -> [String] {
        guard !texts.isEmpty else { return [] }
        let payload = texts.map(TranslationUtil.flatten)

        let order: [Transport] = transport == .mobileHTML
            ? [.mobileHTML, .jsonAPI]
            : [.jsonAPI, .mobileHTML]

        var lastError: Error?
        for candidate in order {
            do {
                let lines: [String]
                switch candidate {
                case .mobileHTML: lines = try await requestMobile(payload)
                case .jsonAPI:    lines = try await requestJSON(payload)
                }
                transport = candidate
                return align(lines, with: texts)
            } catch {
                lastError = error
            }
        }
        throw lastError ?? NSError(
            domain: "GoogleTranslator", code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Google çeviri yanıt vermedi."]
        )
    }

    /// Satır sayısı beklenenden farklıysa eksik kalanlar özgün metinle doldurulur.
    /// Boş satır bırakmak altyazıyı görünmez yapardı — kullanıcı için en kötü sonuç.
    private static func align(_ lines: [String], with texts: [String]) -> [String] {
        var out = lines.map { TranslationUtil.restore(TranslationUtil.decodeHTMLEntities($0)) }
        if out.count > texts.count {
            out = Array(out.prefix(texts.count))
        }
        while out.count < texts.count {
            out.append(texts[out.count])
        }
        for i in out.indices where out[i].isEmpty {
            out[i] = texts[i]
        }
        return out
    }

    // MARK: Mobil HTML ucu

    private static func requestMobile(_ texts: [String]) async throws -> [String] {
        let combined = texts.joined(separator: "\n")
        var components = URLComponents(string: "https://translate.google.com/m")!
        components.queryItems = [
            URLQueryItem(name: "sl", value: "auto"),
            URLQueryItem(name: "tl", value: "tr"),
            URLQueryItem(name: "hl", value: "tr"),
            URLQueryItem(name: "q", value: combined)
        ]
        guard let url = components.url else {
            throw error(400, "Çeviri adresi kurulamadı.")
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("tr,en;q=0.9", forHTTPHeaderField: "Accept-Language")

        let data = try await send(request)
        guard let html = String(data: data, encoding: .utf8) else {
            throw error(500, "Google yanıtı okunamadı.")
        }
        guard let result = extract(divClass: "result-container", from: html) else {
            throw error(500, "Google yanıtında çeviri bulunamadı.")
        }
        return result.components(separatedBy: "\n")
    }

    /// `<div class="result-container">…</div>` içeriğini alır.
    private static func extract(divClass: String, from html: String) -> String? {
        guard let open = html.range(of: "<div class=\"\(divClass)\">") else { return nil }
        let rest = html[open.upperBound...]
        guard let close = rest.range(of: "</div>") else { return nil }
        return String(rest[..<close.lowerBound])
    }

    // MARK: JSON ucu

    private static func requestJSON(_ texts: [String]) async throws -> [String] {
        // Bu uçta satır sonu güvenilir biçimde korunmuyor, o yüzden blokları
        // çevrilmeyen bir işaretle ayırıyoruz.
        let separator = "\n@@@\n"
        let combined = texts.joined(separator: separator)

        var components = URLComponents(string: "https://translate.googleapis.com/translate_a/single")!
        components.queryItems = [
            URLQueryItem(name: "client", value: "gtx"),
            URLQueryItem(name: "sl", value: "auto"),
            URLQueryItem(name: "tl", value: "tr"),
            URLQueryItem(name: "dt", value: "t")
        ]
        guard let url = components.url else {
            throw error(400, "Çeviri adresi kurulamadı.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let body = "q=" + (combined.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? "")
        request.httpBody = body.data(using: .utf8)

        let data = try await send(request)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
              let segments = json.first as? [[Any]] else {
            throw error(500, "Google yanıtı çözülemedi.")
        }

        var translated = ""
        for segment in segments {
            if let text = segment.first as? String { translated += text }
        }
        return translated.components(separatedBy: "@@@")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    // MARK: Ağ

    /// 429 ("çok fazla istek") geçici olabildiği için artan aralıklarla yeniden
    /// dener. Hata metni kullanıcıya olduğu gibi gösteriliyor, "veriler doğru
    /// değil" gibi anlamsız bir mesaj yerine sebebi yazsın diye.
    private static func send(_ request: URLRequest) async throws -> Data {
        var delay: UInt64 = 1_500_000_000
        var lastError: Error = error(-1, "Google'a ulaşılamadı.")

        for attempt in 0..<3 {
            if attempt > 0 {
                try? await Task.sleep(nanoseconds: delay)
                delay *= 2
            }
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    lastError = error(500, "Google'dan geçersiz yanıt geldi.")
                    continue
                }
                switch http.statusCode {
                case 200:
                    return data
                case 429, 503:
                    lastError = error(http.statusCode,
                                      "Google ücretsiz çeviri servisi bu IP'yi geçici olarak " +
                                      "engelledi (kod \(http.statusCode)). Bir süre bekleyin ya da " +
                                      "Ayarlar'dan NVIDIA NIM motorunu seçin.")
                default:
                    lastError = error(http.statusCode, "Google hatası (kod \(http.statusCode)).")
                }
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private static func error(_ code: Int, _ message: String) -> NSError {
        NSError(domain: "GoogleTranslator", code: code,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}

// MARK: - Yapay zeka motorları için ortak protokol

/// Z.ai ve NVIDIA NIM aynı OpenAI uyumlu gövdeyi kullanıyor; aradaki tek fark
/// adres, model ve başlıklar. Numaralandırılmış istek/yanıt biçimi de burada:
/// modelden `1|çeviri` satırları isteniyor, böylece model satır atlasa ya da
/// fazladan satır yazsa bile hangi çeviri hangi bloğa ait karışmıyor.
enum LLMTranslator {

    struct Endpoint {
        var url: URL
        var apiKey: String
        var models: [String]
        var extraHeaders: [String: String] = [:]
        /// GLM ailesi varsayılan olarak "düşünüyor"; kapatılmazsa yanıt
        /// dakikalarca sürüyor ve çıktı yarıda kesilebiliyor. Z.ai'ye özgü
        /// gövde biçimi (`thinking: {type: disabled}`).
        var disableThinking: Bool = false
        /// OpenRouter'ın motorlar arası ortak "düşünmeyi kapat" alanı
        /// (`reasoning: {enabled: false}`) — çoğu ücretsiz model varsayılan
        /// olarak gizli düşünme yapıp `max_tokens`'ı tüketiyor.
        var disableReasoning: Bool = false
        var label: String
    }

    static func systemPrompt() -> String {
        "Sen bir dağıtım şirketinin sinema ve dizi altyazı çevirmenisin; " +
        "yıllardır beyazperdeye giden filmlerin Türkçe altyazısını yazıyorsun. " +
        "İşin literal çeviri değil, yerelleştirme (localization): repliği " +
        "kelimesi kelimesine değil, sahnedeki duyguyu, niyeti ve o karakterin " +
        "ağzına yakışan sesi Türkçede yeniden kurarsın. Sana verilen satırlar " +
        "aynı sahneden ardışık repliklerdir — art arda gelen satırların bir " +
        "diyalog olduğunu, aralarında konuşmacı değişebileceğini unutma ve " +
        "her repliği kendinden önceki/sonraki satırla tutarlı bir sahnenin " +
        "parçası gibi çevir, aralarındaki bağlamı ve ritmi koru. " +
        "Deyim, argo, küfür ve kültürel göndermeleri birebir çevirmek yerine " +
        "Türkçe izleyicinin doğal bulacağı karşılığını bul; komik bir replik " +
        "Türkçede de komik kalsın, gergin bir replik gergin kalsın. Yapmacık, " +
        "kitabi ya da çeviri kokan cümlelerden kaçın — sanki repliği bir " +
        "Türk senarist yazmış gibi doğal aksın. Sadece istenen biçimde çıktı " +
        "verirsin; açıklama, yorum, dipnot ya da başlık eklemezsin."
    }

    static func userPrompt(_ texts: [String]) -> String {
        let numbered = texts.enumerated()
            .map { "\($0.offset + 1)|\(TranslationUtil.flatten($0.element))" }
            .joined(separator: "\n")
        return """
        Aşağıdaki numaralı satırlar bir filmin/dizinin aynı sahnesinden ardışık \
        diyaloglardır — teknik metin ya da birbirinden bağımsız cümleler değil. \
        Önce hepsini oku, sahnede neler olduğunu, kaç kişinin konuştuğunu ve \
        tonun ne olduğunu (samimi/resmi, şakacı/gergin, sakin/öfkeli) kendi \
        içinde anla; sonra bu bütünlüğü koruyarak doğal, akıcı ve sinema \
        tadında bir Türkçeye çevir.

        ÇEVİRİ KURALLARI:
        1. Kelime kelime değil, anlamı ve tonu Türkçede doğal konuşma diliyle ver;
        deyim, argo ve küfürün birebir karşılığını değil Türkçede gerçekten
        kullanılan karşılığını yaz.
        2. Replikler arasındaki bağlamı gözet: bir soru-cevap ya da yarım kalan
        cümle varsa çeviride de o akış bozulmasın; her satırı diğerlerinden
        kopuk, tek başına bir cümleymiş gibi çevirme.
        3. Replik kısaysa çeviri de kısa kalsın — altyazı hızlıca okunur, gereksiz
        ekleme, açıklama ya da parantez içi yorum yapma.
        4. Karakterin tonunu ve kayıt düzeyini koru: bağırma, şaka, kabalık,
        resmiyet, tereddüt neyse çeviride de aynısı hissedilsin. Sokak ağzı
        konuşan biri Türkçede de sokak ağzıyla, resmi konuşan resmi kalsın.
        5. Özel isimleri (kişi, yer, marka adları) olduğu gibi bırak, çevirme.

        BİÇİM KURALLARI (kesinlikle uy):
        6. Çıktıda tam olarak \(texts.count) satır olmalı, ne eksik ne fazla.
        7. Her satır "numara|çeviri" biçiminde olmalı. Numaraları değiştirme, \
        atlama. İKİ SATIRI TEK NUMARADA BİRLEŞTİRME (ör. "5-6|..." yazma) — \
        anlamca bağlı olsalar bile her replik kendi numarasıyla ayrı satırda kalsın.
        8. Satır içindeki ⏎ işareti alt satıra geçişi gösterir; olduğu yerde bırak.
        9. Açıklama, not, başlık ya da kod bloğu yazma. Yalnızca satırları yaz.

        SATIRLAR:
        \(numbered)
        """
    }

    /// Modelleri sırayla dener: biri kota/limit hatası verirse (ücretsiz
    /// modellerde sık) bir sonrakine geçer. Hepsi düşerse son hatayı fırlatır.
    static func translateBatch(_ texts: [String], endpoint: Endpoint) async throws -> [String] {
        guard !texts.isEmpty else { return [] }
        guard !endpoint.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NSError(domain: endpoint.label, code: 401, userInfo: [
                NSLocalizedDescriptionKey: "\(endpoint.label) API anahtarı boş. Ayarlar > Çeviri'den girin."
            ])
        }

        var lastError: Error = NSError(domain: endpoint.label, code: -1, userInfo: [
            NSLocalizedDescriptionKey: "\(endpoint.label) yanıt vermedi."
        ])

        for model in endpoint.models {
            do {
                let content = try await requestWithBackoff(texts, model: model, endpoint: endpoint)
                var (lines, matched) = align(content, with: texts)
                // Model biçimi tutturamadıysa elimizde özgün metnin kopyası kalır.
                // Bunu "çeviri" diye geri vermek, ilerleme %100'e varsa da ekranda
                // hiçbir şeyin değişmemesi demek — sessiz başarısızlığın ta kendisi.
                // Hata sayıp sıradaki modele geçiyoruz.
                guard matched.count * 10 >= texts.count * 7 else {
                    throw NSError(domain: endpoint.label, code: 422, userInfo: [
                        NSLocalizedDescriptionKey:
                            "\(endpoint.label) (\(model)) istenen biçimde yanıt vermedi " +
                            "(\(texts.count) satırdan \(matched.count) tanesi eşleşti)."
                    ])
                }

                // Modeller kırk satırın birkaçını atlayabiliyor; atlananlar özgün
                // hâlleriyle kalınca izlerken araya İngilizce satırlar karışıyor.
                // Yalnızca eksikler için birkaç kısa tur daha atıyoruz — GLM
                // (Z.ai) tek turda bile satır atlamaya devam edebiliyor, bu
                // yüzden tamamı gelene kadar (ya da tur hakkı bitene kadar) ısrar
                // ediyoruz; her tur küçük bir istek, kazanç gözle görülür.
                var missing = texts.indices.filter { !matched.contains($0) }
                var round = 0
                while !missing.isEmpty, round < 4 {
                    round += 1
                    let leftovers = missing.map { texts[$0] }
                    guard let retry = try? await requestWithBackoff(leftovers, model: model,
                                                                    endpoint: endpoint) else {
                        break
                    }
                    let (retryLines, retryMatched) = align(retry, with: leftovers)
                    var stillMissing: [Int] = []
                    for (position, index) in missing.enumerated() {
                        if retryMatched.contains(position) {
                            lines[index] = retryLines[position]
                        } else {
                            stillMissing.append(index)
                        }
                    }
                    // İlerleme yoksa (aynı satırlar yine atlandıysa) yeniden
                    // denemek zaman kaybı — döngüden çık.
                    if stillMissing.count == missing.count { break }
                    missing = stillMissing
                }
                return lines
            } catch {
                lastError = error
                let code = (error as NSError).code
                // 401 dışında her şeyde sıradaki modeli dene: 429/402/404/503
                // standart "meşgul/kotasız/yok" durumları, 422 biçim hatası,
                // ama Z.ai gibi uçlar bakiye/model hatalarını da kendi
                // numaralı kodlarıyla (1113, 1211...) dönebiliyor — bunlar
                // HTTP durum kodu değil ama aynı şekilde "bu modeli bu
                // anahtarla kullanamıyorsun" anlamına geliyor. 401 tek
                // istisna: anahtarın kendisi geçersizse hiçbir model
                // çalışmaz, yeniden denemek zaman kaybı.
                guard code != 401 else { throw error }
            }
        }
        throw lastError
    }

    /// Hız sınırına takılan isteği aynı modelle yeniden dener.
    ///
    /// Z.ai'nin ücretsiz katmanı aynı anda birkaç istekten fazlasını kabul
    /// etmiyor ve "hız sınırı" diyip 429 döndürüyor. Bunu doğrudan hata saymak,
    /// paralel giden partilerin bir kısmını çevrilmeden bırakıyordu; kısa bir
    /// bekleme çoğunu kurtarıyor.
    private static func requestWithBackoff(_ texts: [String], model: String,
                                           endpoint: Endpoint) async throws -> String {
        var lastError: Error?
        // 3 denemeden 4'e çıkarıldı — ücretsiz katmanlarda yoğun anlarda 3
        // deneme (6+14 sn bekleme) hâlâ 429'a takılıp partiyi tamamen
        // kaybettiriyordu; dördüncü, daha uzun bir bekleme (26 sn) ekstra bir
        // şans daha veriyor.
        for attempt in 0..<4 {
            if attempt > 0 {
                try? await Task.sleep(for: .seconds([0, 6, 14, 26][attempt]))
            }
            do {
                return try await request(texts, model: model, endpoint: endpoint)
            } catch {
                let code = (error as NSError).code
                guard code == 429 || code == 503 else { throw error }
                lastError = error
            }
        }
        throw lastError ?? NSError(domain: endpoint.label, code: 429, userInfo: [
            NSLocalizedDescriptionKey: "\(endpoint.label) hız sınırı aşıldı."
        ])
    }

    private static func request(_ texts: [String], model: String,
                                endpoint: Endpoint) async throws -> String {
        var request = URLRequest(url: endpoint.url)
        request.httpMethod = "POST"
        // Ücretsiz modeller sıraya girebiliyor; 120 saniye kısa kalıyordu.
        request.timeoutInterval = 300
        request.setValue("Bearer \(endpoint.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (key, value) in endpoint.extraHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let systemContent = systemPrompt()

        var body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemContent],
                ["role": "user", "content": userPrompt(texts)]
            ],
            // 0.2 çok düşüktü: model repliği neredeyse birebir/kelime kelime
            // çeviriyordu ("çok kötü çeviriyor" şikayeti). 0.3, biçim kurallarını
            // (numaralama) bozacak kadar değil ama daha doğal cümle kurmasına
            // yetecek kadar serbestlik veriyor.
            "temperature": 0.3,
            // Yanıtın ortada kesilmemesi için bolca yer bırakılıyor.
            "max_tokens": 8000
        ]
        // Nemotron ailesinde düşünme modu sistem mesajına metin ekleyerek DEĞİL,
        // bu alanla kapanıyor — denendi: sistem mesajına "detailed thinking off"
        // yazmak modeli hiç etkilemiyor, gizli bir "reasoning_content" bloğu
        // üretmeye devam ediyor ve bu blok `max_tokens`'ın büyük kısmını tüketip
        // görünür yanıtı (numaralı satırlar) yarıda kesiyor ya da tamamen boş
        // bırakıyor. `chat_template_kwargs.thinking: false` gerçekten kapatıyor.
        if model.contains("nemotron") {
            body["chat_template_kwargs"] = ["thinking": false]
        }
        if endpoint.disableThinking {
            body["thinking"] = ["type": "disabled"]
        }
        if endpoint.disableReasoning {
            body["reasoning"] = ["enabled": false]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: endpoint.label, code: 500, userInfo: [
                NSLocalizedDescriptionKey: "\(endpoint.label)'den geçersiz yanıt alındı."
            ])
        }
        guard http.statusCode == 200 else {
            throw NSError(domain: endpoint.label, code: http.statusCode, userInfo: [
                NSLocalizedDescriptionKey:
                    "\(endpoint.label) hatası (\(model), kod \(http.statusCode)): \(errorMessage(data))"
            ])
        }

        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        // Bazı OpenAI-uyumlu uçlar hata gövdesini HTTP 200 ile de döndürebiliyor.
        if let error = json?["error"] as? [String: Any] {
            let message = error["message"] as? String ?? "bilinmeyen hata"
            let code = error["code"] as? Int ?? 500
            throw NSError(domain: endpoint.label, code: code, userInfo: [
                NSLocalizedDescriptionKey: "\(endpoint.label) hatası (\(model)): \(message)"
            ])
        }
        guard let choices = json?["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NSError(domain: endpoint.label, code: 500, userInfo: [
                NSLocalizedDescriptionKey: "\(endpoint.label) yanıt yapısı geçersiz (\(model))."
            ])
        }
        return content
    }

    private static func errorMessage(_ data: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = json["error"] as? [String: Any],
           let message = error["message"] as? String {
            return message
        }
        let raw = String(data: data, encoding: .utf8) ?? "bilinmeyen hata"
        return String(raw.prefix(300))
    }

    /// Bir çıktı satırının başındaki sıra numarasını ve kalan metni ayırır.
    ///
    /// Modeller istenen `1|metin` biçiminde başlayıp yol boyunca kendiliğinden
    /// `1. metin`, `1) metin` ya da yalnızca `1 metin` biçimine kayıyor —
    /// GLM-4.5-flash 40 satırın 29'unda boruyu düşürüyordu ve katı ayrıştırma
    /// yüzünden bütün parti çöpe gidiyordu. Bu yüzden ayraç konusunda hoşgörülü.
    ///
    /// Numaranın parti sınırları içinde olması şartı, çeviri metninin kendisiyle
    /// başlayan sayıları ("1999 yılında...") yanlışlıkla numara saymayı önlüyor.
    private static func numbered(_ line: String, upTo count: Int) -> (Int, String)? {
        var digits = ""
        var cursor = line.startIndex
        while cursor < line.endIndex, line[cursor].isNumber {
            digits.append(line[cursor])
            cursor = line.index(after: cursor)
        }
        guard let number = Int(digits), number >= 1, number <= count,
              cursor < line.endIndex else { return nil }

        // Numaradan sonra tek bir ayraç yenir, ardından yalnızca boşluk kırpılır.
        // Hepsi birden kırpılsaydı diyalog çizgisi ("1|- Hayır") yok olurdu.
        let separators: Set<Character> = ["|", ".", ")", ":", "-", "–", ">", "]", "、"]
        if separators.contains(line[cursor]) {
            cursor = line.index(after: cursor)
        } else if !line[cursor].isWhitespace {
            return nil   // "1abc" bir numaralı satır değil
        }
        let body = line[cursor...].drop { $0.isWhitespace }
        return body.isEmpty ? nil : (number, String(body))
    }

    /// GLM ve diğer modeller bazen iki bitişik repliği tek satırda birleştirip
    /// `5-6|metin` yazıyor. `numbered(_:upTo:)` bunu "numara 5, gövde '6|metin'"
    /// diye yanlış ayrıştırır: 5. satır çöp metinle dolar, 6. satır hiç
    /// eşleşmeden özgün (yabancı) hâliyle kalır — izlerken replik aniden
    /// İngilizce kalıyor ya da anlamsız bir parça görünüyor, sanki çeviri
    /// zamanlaması kaymış gibi hissettiriyor. Bunu önce yakalayıp aralığın
    /// tamamına aynı çeviriyi uyguluyoruz: ikisi de aynı Türkçe metni gösterir,
    /// hiçbiri boş ya da bozuk kalmaz.
    private static func numberedRange(_ line: String, upTo count: Int) -> (ClosedRange<Int>, String)? {
        var cursor = line.startIndex
        var firstDigits = ""
        while cursor < line.endIndex, line[cursor].isNumber {
            firstDigits.append(line[cursor])
            cursor = line.index(after: cursor)
        }
        guard let first = Int(firstDigits), first >= 1, first <= count,
              cursor < line.endIndex, line[cursor] == "-" || line[cursor] == "–" else { return nil }
        cursor = line.index(after: cursor)

        var secondDigits = ""
        while cursor < line.endIndex, line[cursor].isNumber {
            secondDigits.append(line[cursor])
            cursor = line.index(after: cursor)
        }
        guard !secondDigits.isEmpty, let second = Int(secondDigits),
              second > first, second <= count, second - first <= 4,
              cursor < line.endIndex else { return nil }

        // Aralıktan sonra tireyi tekrar kabul etmiyoruz — "5-6-7" gibi bir
        // gövde belirsiz; net bir ayraç ya da boşluk istiyoruz.
        let separators: Set<Character> = ["|", ".", ")", ":", ">", "]", "、"]
        if separators.contains(line[cursor]) {
            cursor = line.index(after: cursor)
        } else if !line[cursor].isWhitespace {
            return nil
        }
        let body = line[cursor...].drop { $0.isWhitespace }
        return body.isEmpty ? nil : (first...second, String(body))
    }

    /// `1|çeviri` satırlarını numaralarına göre yerleştirir. Numarası olmayan ya
    /// da hiç gelmeyen satırlar özgün metinle kalır — boş altyazı üretmektense
    /// çevrilmemiş satır bırakmak yeğdir.
    ///
    /// Hangi satırların gerçekten eşleştiğini de döndürüyor: çağıran buna bakıp
    /// modelin biçimi tutturup tutturmadığına karar veriyor ve eksik kalanları
    /// ikinci bir turda tamamlıyor.
    static func align(_ content: String, with texts: [String]) -> (lines: [String], matched: Set<Int>) {
        var result = texts
        var matched = Set<Int>()
        var unnumbered: [String] = []

        for rawLine in content.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("```") else { continue }

            // Birleşmiş "5-6|metin" satırları tek numaralı ayrıştırıcıdan önce
            // yakalanmalı, yoksa 5. satır bozuk metin alır, 6. hiç eşleşmez.
            if let (range, body) = numberedRange(line, upTo: texts.count) {
                let text = TranslationUtil.restore(body)
                if !text.isEmpty {
                    for index in (range.lowerBound - 1)...(range.upperBound - 1) {
                        result[index] = text
                        matched.insert(index)
                    }
                }
                continue
            }

            guard let (number, body) = numbered(line, upTo: texts.count) else {
                unnumbered.append(line)
                continue
            }
            let text = TranslationUtil.restore(body)
            if !text.isEmpty {
                result[number - 1] = text
                matched.insert(number - 1)
            }
        }

        // Model biçimi tümden görmezden geldiyse (numarasız düz satırlar) ve satır
        // sayısı tutuyorsa, sırayla eşleştir.
        if matched.isEmpty, unnumbered.count == texts.count {
            return (unnumbered.map { TranslationUtil.restore($0) }, Set(texts.indices))
        }
        return (result, matched)
    }
}

// MARK: - Z.ai

/// Z.ai (GLM) ile sinematik çeviri.
enum ZaiTranslator {
    static let endpointURL = URL(string: "https://api.z.ai/api/paas/v4/chat/completions")!

    /// Kullanıcı Ayarlar'dan model seçebiliyor; `glm-5.3-flash` en güncel ve
    /// en kaliteli seçenek olduğu için varsayılan bu. Ücretsiz katmanda
    /// yalnızca `glm-4.7-flash`/`glm-4.5-flash` çalışıyor (diğer GLM-4.5
    /// varyantları bakiye istiyor, kod 1113) — bunlar seçilen model
    /// tökezlerse otomatik denenen yedekler.
    static let defaultModel = "glm-5.3-flash"
    static let freeModels = ["glm-4.7-flash", "glm-4.5-flash"]

    /// GLM ailesi uzun partilerde (40 satır) satır atlama oranı belirgin
    /// artıyor; daha kısa partiler ("eksik çeviri" şikayetinin kaynağı) bu
    /// oranı düşürüyor.
    static let maxLinesPerRequest = 20

    static func translateBatch(_ texts: [String], apiKey: String, model: String) async throws -> [String] {
        try await LLMTranslator.translateBatch(texts, endpoint: LLMTranslator.Endpoint(
            url: endpointURL,
            apiKey: apiKey,
            models: TranslationUtil.fallbackChain(preferred: model, pool: freeModels),
            disableThinking: true,
            label: "Z.ai"
        ))
    }
}

// MARK: - NVIDIA NIM

/// build.nvidia.com (NIM) üzerinden tek, sabit modelle çeviri.
///
/// OpenRouter'ın aksine burada bir model listesi/seçimi yok: kullanıcı
/// "en iyisi hangisiyse sadece o çalışsın" dedi. `nemotron-3-ultra-550b-a55b`
/// NVIDIA'nın kendi kataloğundaki en güçlü, ücretsiz erişilebilen modeli
/// (bkz. OpenRouter tarafında da aynı model en yüksek kalite puanına
/// sahipti — [[zyplayer-subtitle-translation]]). Reasoning modu
/// `LLMTranslator.request`'teki genel "model adı nemotron içeriyorsa
/// 'detailed thinking off'" kuralıyla zaten kapatılıyor.
enum NvidiaTranslator {
    static let endpointURL = URL(string: "https://integrate.api.nvidia.com/v1/chat/completions")!

    /// `nemotron-3-ultra-550b-a55b` NVIDIA'nın kendi kataloğundaki en güçlü,
    /// ücretsiz erişilebilen model — varsayılan bu. Kullanıcı Ayarlar'dan
    /// başka bir NIM modeli de seçebiliyor; buradaki ikisi seçilen model
    /// tökezlerse (kota/kaldırılmış model) otomatik denenen yedekler.
    static let defaultModel = "nvidia/nemotron-3-ultra-550b-a55b"
    static let fallbackModels = ["meta/llama-3.1-405b-instruct", "qwen/qwen2.5-72b-instruct"]

    /// OpenRouter'ın küçük/zayıf ücretsiz modelleri 10 satırda bile satır
    /// atlıyordu; bu, NVIDIA'nın kendi bünyesinde barındırdığı büyük
    /// modeller — hem daha güvenilir hem de ücretsiz katman kredi sınırlı
    /// olduğundan büyük parti = daha az istek = kredi tasarrufu.
    static let maxLinesPerRequest = 30

    static func translateBatch(_ texts: [String], apiKey: String, model: String) async throws -> [String] {
        try await LLMTranslator.translateBatch(texts, endpoint: LLMTranslator.Endpoint(
            url: endpointURL,
            apiKey: apiKey,
            models: TranslationUtil.fallbackChain(preferred: model, pool: fallbackModels),
            label: "NVIDIA NIM"
        ))
    }
}

// MARK: - OpenRouter

/// openrouter.ai üzerinden birden çok sağlayıcının ücretsiz modellerine tek
/// anahtarla erişim. Daha önce (2026-08-16) güvenilmezliği nedeniyle
/// kaldırılmıştı — kullanıcı isteğiyle yeniden eklendi. Ücretsiz modeller sık
/// 429 verdiği ve zaman zaman kataloktan kalktığı için model listesi sırayla
/// denenir; kullanıcının Ayarlar'dan seçtiği model her zaman ilk sırada.
enum OpenRouterTranslator {
    static let endpointURL = URL(string: "https://openrouter.ai/api/v1/chat/completions")!

    static let defaultModel = "nvidia/nemotron-3.5-lightning:free"
    /// costgoat.com / openrouter.ai katalogunda doğrulanan güncel ücretsiz
    /// genel amaçlı modeller (2026-08). Yalnızca kod/görsel odaklı olanlar
    /// dışarıda bırakıldı.
    static let freeModels = [
        "nvidia/nemotron-3.5-lightning:free",
        "inclusionai/ling-3.0-flash-fin:free",
        "thinkingmachines/inkling:free",
        "liquid/lfm-2.5-2.6b:free"
    ]

    /// Ücretsiz modellerin çoğu küçük/zayıf, büyük partilerde satır atlıyor.
    static let maxLinesPerRequest = 10

    static func translateBatch(_ texts: [String], apiKey: String, model: String) async throws -> [String] {
        try await LLMTranslator.translateBatch(texts, endpoint: LLMTranslator.Endpoint(
            url: endpointURL,
            apiKey: apiKey,
            models: TranslationUtil.fallbackChain(preferred: model, pool: freeModels),
            extraHeaders: [
                "HTTP-Referer": "https://github.com/zyplayer/zyplayer",
                "X-Title": "ZyPlayer"
            ],
            disableReasoning: true,
            label: "OpenRouter"
        ))
    }
}

extension CharacterSet {
    static let urlQueryValueAllowed: CharacterSet = {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=")
        return allowed
    }()
}
