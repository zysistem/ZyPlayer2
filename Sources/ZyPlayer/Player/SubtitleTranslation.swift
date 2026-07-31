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
                                      "Ayarlar'dan OpenRouter motorunu seçin.")
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

/// Z.ai ve OpenRouter aynı OpenAI uyumlu gövdeyi kullanıyor; aradaki tek fark
/// adres, model ve başlıklar. Numaralandırılmış istek/yanıt biçimi de burada:
/// modelden `1|çeviri` satırları isteniyor, böylece model satır atlasa ya da
/// fazladan satır yazsa bile hangi çeviri hangi bloğa ait karışmıyor.
enum LLMTranslator {

    static let maxLinesPerRequest = 40

    struct Endpoint {
        var url: URL
        var apiKey: String
        var models: [String]
        var extraHeaders: [String: String] = [:]
        /// GLM-4.5 ailesi varsayılan olarak "düşünüyor"; kapatılmazsa yanıt
        /// dakikalarca sürüyor ve çıktı yarıda kesilebiliyor.
        var disableThinking: Bool = false
        var label: String
    }

    static func systemPrompt() -> String {
        "Sen usta bir film ve dizi altyazı çevirmenisin. Sadece istenen biçimde " +
        "çıktı verirsin; açıklama, not ya da başlık eklemezsin."
    }

    static func userPrompt(_ texts: [String]) -> String {
        let numbered = texts.enumerated()
            .map { "\($0.offset + 1)|\(TranslationUtil.flatten($0.element))" }
            .joined(separator: "\n")
        return """
        Aşağıdaki numaralı altyazı satırlarını doğal, akıcı ve sinematik bir \
        Türkçe'ye çevir.

        KURALLAR:
        1. Çıktıda tam olarak \(texts.count) satır olmalı.
        2. Her satır "numara|çeviri" biçiminde olmalı. Numaraları değiştirme, \
        atlama, birleştirme.
        3. Satır içindeki ⏎ işareti alt satıra geçişi gösterir; olduğu yerde bırak.
        4. Açıklama, not, başlık ya da kod bloğu yazma. Yalnızca satırları yaz.

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
                // Yalnızca eksikler için kısa bir tur daha atıyoruz — küçük bir
                // istek, gözle görülür bir kazanç.
                let missing = texts.indices.filter { !matched.contains($0) }
                if !missing.isEmpty {
                    let leftovers = missing.map { texts[$0] }
                    if let retry = try? await requestWithBackoff(leftovers, model: model,
                                                                 endpoint: endpoint) {
                        let (retryLines, retryMatched) = align(retry, with: leftovers)
                        for (position, index) in missing.enumerated()
                        where retryMatched.contains(position) {
                            lines[index] = retryLines[position]
                        }
                    }
                }
                return lines
            } catch {
                lastError = error
                let code = (error as NSError).code
                // 429/402/404: model meşgul, kotası dolmuş ya da kalkmış.
                // 422: biçimi bozdu. Hepsinde sıradaki modeli denemek anlamlı.
                // Diğerlerinde (401 gibi) model değiştirmenin faydası yok.
                guard code == 429 || code == 402 || code == 404 || code == 503 || code == 422
                else { throw error }
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
        for attempt in 0..<3 {
            if attempt > 0 {
                try? await Task.sleep(for: .seconds(attempt == 1 ? 6 : 14))
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

        var body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt()],
                ["role": "user", "content": userPrompt(texts)]
            ],
            "temperature": 0.2,
            // Yanıtın ortada kesilmemesi için bolca yer bırakılıyor.
            "max_tokens": 8000
        ]
        if endpoint.disableThinking {
            body["thinking"] = ["type": "disabled"]
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
        // OpenRouter hata gövdesini 200 ile de döndürebiliyor.
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

    /// Yalnızca `glm-4.5-flash`. Denendi: `glm-4.6`, `glm-4.5`, `glm-4.5-air`
    /// ve `glm-4.5-airx` bakiye istiyor (kod 1113), `glm-4-flash` diye bir model
    /// ise Z.ai'de yok (kod 1211). Var olmayan modelleri yedek listesine koymak,
    /// asıl model tökezlediğinde hatayı anlaşılmaz hâle getiriyordu.
    static let models = ["glm-4.5-flash"]

    static func translateBatch(_ texts: [String], apiKey: String) async throws -> [String] {
        try await LLMTranslator.translateBatch(texts, endpoint: LLMTranslator.Endpoint(
            url: endpointURL,
            apiKey: apiKey,
            models: models,
            disableThinking: true,
            label: "Z.ai"
        ))
    }
}

// MARK: - OpenRouter

/// OpenRouter üzerinden ücretsiz modellerle çeviri.
enum OpenRouterTranslator {
    static let endpointURL = URL(string: "https://openrouter.ai/api/v1/chat/completions")!

    /// Ayarlarda seçilebilen ücretsiz modeller. Sıra, Türkçe altyazı çevirisinde
    /// ölçülen kalite/hız dengesine göre: en üstteki hem iyi çeviriyor hem ~10 sn'de
    /// dönüyor. Hepsi OpenRouter'ın `:free` katmanında, yani ücret çıkarmıyor.
    static let freeModels: [(id: String, title: String)] = [
        ("nvidia/nemotron-3-ultra-550b-a55b:free", "Nemotron 3 Ultra 550B (önerilen)"),
        ("nvidia/nemotron-3-super-120b-a12b:free", "Nemotron 3 Super 120B"),
        ("google/gemma-4-31b-it:free", "Gemma 4 31B"),
        ("google/gemma-4-26b-a4b-it:free", "Gemma 4 26B"),
        ("inclusionai/ling-3.0-flash:free", "Ling 3.0 Flash (en hızlı)"),
        ("openai/gpt-oss-20b:free", "GPT-OSS 20B")
    ]

    /// Ayarlardaki "Otomatik" seçeneğinin değeri: listenin tamamı sırayla denenir.
    static let automaticModel = "auto"

    static func models(preferred: String) -> [String] {
        let all = freeModels.map(\.id)
        guard preferred != automaticModel,
              let index = all.firstIndex(of: preferred) else { return all }
        // Seçilen model başa alınır, gerisi yedek olarak arkada kalır: ücretsiz
        // katmanda bir model kotaya takıldığında çeviri durmasın.
        return [all[index]] + all.enumerated().filter { $0.offset != index }.map(\.element)
    }

    static func translateBatch(_ texts: [String], apiKey: String,
                               preferredModel: String) async throws -> [String] {
        try await LLMTranslator.translateBatch(texts, endpoint: LLMTranslator.Endpoint(
            url: endpointURL,
            apiKey: apiKey,
            models: models(preferred: preferredModel),
            // OpenRouter bu iki başlıkla isteği uygulamaya bağlıyor; ücretsiz
            // katmanda istekleri kimin yaptığı böyle görünüyor.
            extraHeaders: [
                "HTTP-Referer": "https://github.com/zyplayer",
                "X-Title": "ZyPlayer"
            ],
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
