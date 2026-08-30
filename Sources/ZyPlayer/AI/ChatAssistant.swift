import Foundation
import Observation

/// Sağ alttaki sohbet asistanının tek bir baloncuğu.
struct ChatMessage: Identifiable {
    enum Role { case user, assistant }
    let id = UUID()
    var role: Role
    var text: String
    /// Asistanın cümle içinde işaret ettiği, tıklanabilir olarak gösterilecek
    /// aday kartlarının kimlikleri (`RecommendationCandidate.id`).
    var referencedCandidateIDs: [String] = []
}

/// Sağ alt köşedeki "fikir sor" sohbet kutusunu besler. Oynatıcı açıkken bu
/// widget hiç gösterilmiyor (bkz. RootView) — yalnızca ana pencerede.
@Observable
final class ChatAssistantStore {
    private(set) var messages: [ChatMessage] = []
    private(set) var isLoading = false
    private(set) var lastError: String?

    func send(_ text: String, watched: [String], candidates: [RecommendationCandidate], apiKey: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isLoading else { return }

        messages.append(ChatMessage(role: .user, text: trimmed))
        isLoading = true
        defer { isLoading = false }

        do {
            let (reply, refs) = try await ChatRecommender.reply(
                history: messages, watched: watched, candidates: candidates, apiKey: apiKey
            )
            messages.append(ChatMessage(role: .assistant, text: reply, referencedCandidateIDs: refs))
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            messages.append(ChatMessage(role: .assistant,
                                         text: "Bir şeyler ters gitti: \(error.localizedDescription)"))
        }
    }

    func clear() {
        messages.removeAll()
        lastError = nil
    }
}

/// NVIDIA NIM ile serbest sohbet — ama önerdiği her başlık yine KAPALI aday
/// listesinden gelmek zorunda (bkz. NvidiaRecommender'daki aynı gerekçe).
/// Model bir adayı önerirken cümle içine `[[N]]` işareti koyuyor; bunu ekranda
/// göstermeden o adayın tıklanabilir kartına çeviriyoruz.
enum ChatRecommender {
    /// Prompt boyutunu makul tutmak için her turda gönderilen aday sayısı.
    static let maxCandidatesInPrompt = 150

    static func reply(history: [ChatMessage], watched: [String], candidates: [RecommendationCandidate],
                       apiKey: String) async throws -> (text: String, referencedIDs: [String]) {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NSError(domain: "NVIDIA NIM", code: 401, userInfo: [
                NSLocalizedDescriptionKey: "NVIDIA NIM API anahtarı boş."
            ])
        }
        guard let lastUser = history.last, lastUser.role == .user else {
            throw NSError(domain: "NVIDIA NIM", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Gönderilecek bir soru yok."
            ])
        }

        let pool = Array(candidates.prefix(maxCandidatesInPrompt))
        let candidateLines = pool.enumerated()
            .map { "\($0.offset + 1)|\($0.element.promptLine)" }
            .joined(separator: "\n")
        let watchedLines = watched.prefix(40).map { "- \($0)" }.joined(separator: "\n")

        let system = """
        ÖNEMLİ: Yanıtının tamamı Türkçe olmalı, tek kelime bile İngilizce yazma.

        Sen ZyPlayer uygulamasının film/dizi öneri asistanısın. Kullanıcıyla \
        sohbet ederek ne izleyeceğine dair fikir veriyorsun. Yalnızca sana \
        verilen KAPALI aday listesindeki içerikleri önerebilirsin — listede \
        olmayan bir başlık asla önermezsin, uydurmazsın. Bir adayı önerdiğinde \
        cümle içinde mutlaka o adayın numarasını "[[N]]" biçiminde ekle \
        (kullanıcı bu işareti görmeyecek, sistem onu tıklanabilir bir karta \
        çevirecek). Önerdiğin HER başlık için bu işareti unutma. Kısa, sıcak, \
        sohbet havasında ve yalnızca Türkçe yanıt ver — madde madde uzun bir \
        liste değil, gerçek bir öneri konuşması.

        Örnek: "Aksiyon istiyorsan Labirent: Ölümcül Kaçış[[7]] tam sana göre, \
        hem de Primat[[11]] farklı bir tempo arıyorsan iyi gider."
        """

        var messages: [[String: String]] = [["role": "system", "content": system]]
        // Önceki turlar yalnızca düz metinle taşınıyor; aday listesi her
        // seferinde son kullanıcı mesajına ekleniyor (bkz. aşağısı), yoksa
        // birkaç tur sonra bağlam devasa büyür.
        for message in history.dropLast() {
            messages.append(["role": message.role == .user ? "user" : "assistant", "content": message.text])
        }

        let finalPrompt = """
        (Hatırlatma: yanıtın tamamı Türkçe olacak, İngilizce tek kelime bile yazma.)

        Kullanıcının daha önce izleyip beğendiği yapımlar:
        \(watchedLines.isEmpty ? "(henüz bilinmiyor)" : watchedLines)

        Önerebileceğin KAPALI aday listesi:
        \(candidateLines)

        Kullanıcının sorusu: \(lastUser.text)
        """
        messages.append(["role": "user", "content": finalPrompt])

        let content = try await NvidiaChatClient.request(messages: messages, apiKey: apiKey,
                                                           temperature: 0.6, maxTokens: 700)
        return parse(content, candidates: pool)
    }

    private static func parse(_ content: String, candidates: [RecommendationCandidate]) -> (String, [String]) {
        guard let pattern = try? NSRegularExpression(pattern: "\\[\\[(\\d+)\\]\\]") else {
            return (content.trimmingCharacters(in: .whitespacesAndNewlines), [])
        }
        let ns = content as NSString
        let fullRange = NSRange(location: 0, length: ns.length)

        var refs: [String] = []
        var seen = Set<Int>()
        for match in pattern.matches(in: content, range: fullRange) {
            guard let numberRange = Range(match.range(at: 1), in: content),
                  let number = Int(content[numberRange]),
                  number >= 1, number <= candidates.count, !seen.contains(number) else { continue }
            seen.insert(number)
            refs.append(candidates[number - 1].id)
        }

        let cleaned = pattern.stringByReplacingMatches(in: content, range: fullRange, withTemplate: "")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Model her zaman "[[N]]" biçimini kullanmayabiliyor — cevapta geçen
        // aday başlıklarını da yakalayarak kartların yine de çıkmasını
        // sağlıyoruz, yoksa kullanıcı yalnızca düz metin görür, tıklayacak
        // bir şey olmaz.
        if refs.isEmpty {
            let lowerContent = cleaned.lowercased()
            for candidate in candidates {
                guard lowerContent.contains(candidate.title.lowercased()) else { continue }
                refs.append(candidate.id)
                if refs.count >= 8 { break }
            }
        }

        return (cleaned, refs)
    }
}
