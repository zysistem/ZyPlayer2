import Foundation

/// build.nvidia.com (NIM) üzerinden düşük seviyeli, OpenAI-uyumlu chat isteği.
///
/// Hem ana ekranın "Sizin İçin Öneriler" rafı (`NvidiaRecommender`) hem de
/// sohbet asistanı (`ChatRecommender`) bu tek noktadan geçiyor — istek
/// gövdesi, "detailed thinking off" kuralı ve 429/503 backoff'u tek yerde.
enum NvidiaChatClient {
    static func request(messages: [[String: String]], apiKey: String,
                        temperature: Double = 0.4, maxTokens: Int = 1200) async throws -> String {
        var request = URLRequest(url: NvidiaTranslator.endpointURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Nemotron ailesi düşünme modunu sistem mesajına metin ekleyerek DEĞİL bu
        // alanla kapatıyor: sistem mesajına "detailed thinking off" yazmak hiç
        // işe yaramıyor (denendi — model yine uzun bir "reasoning_content" bloğu
        // üretip yanıtı yavaşlatıyor, hatta max_tokens'ı tüketip kesiyor), ama
        // `chat_template_kwargs.thinking: false` gerçekten kapatıyor ve çıktı
        // doğrudan istenen dilde (Türkçe) ve hızlı geliyor.
        let body: [String: Any] = [
            "model": NvidiaTranslator.defaultModel,
            "messages": messages,
            "temperature": temperature,
            "max_tokens": maxTokens,
            "chat_template_kwargs": ["thinking": false]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        var lastError: Error = NSError(domain: "NVIDIA NIM", code: -1, userInfo: [
            NSLocalizedDescriptionKey: "NVIDIA NIM yanıt vermedi."
        ])
        for attempt in 0..<3 {
            if attempt > 0 {
                try? await Task.sleep(for: .seconds(attempt == 1 ? 6 : 14))
            }
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    lastError = NSError(domain: "NVIDIA NIM", code: 500, userInfo: [
                        NSLocalizedDescriptionKey: "NVIDIA NIM'den geçersiz yanıt alındı."
                    ])
                    continue
                }
                guard http.statusCode == 200 else {
                    if http.statusCode == 429 || http.statusCode == 503 {
                        lastError = NSError(domain: "NVIDIA NIM", code: http.statusCode, userInfo: [
                            NSLocalizedDescriptionKey: "NVIDIA NIM hız sınırı (kod \(http.statusCode))."
                        ])
                        continue
                    }
                    throw NSError(domain: "NVIDIA NIM", code: http.statusCode, userInfo: [
                        NSLocalizedDescriptionKey: "NVIDIA NIM hatası (kod \(http.statusCode))."
                    ])
                }
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                guard let choices = json?["choices"] as? [[String: Any]],
                      let message = choices.first?["message"] as? [String: Any],
                      let text = message["content"] as? String,
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw NSError(domain: "NVIDIA NIM", code: 500, userInfo: [
                        NSLocalizedDescriptionKey: "NVIDIA NIM yanıt yapısı geçersiz."
                    ])
                }
                return text
            } catch {
                lastError = error
                let code = (error as NSError).code
                guard code == 429 || code == 503 else { throw error }
            }
        }
        throw lastError
    }
}
