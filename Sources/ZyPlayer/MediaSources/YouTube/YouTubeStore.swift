import Foundation
import Observation

/// Genel aramanın YouTube bölümünü besleyen depo.
///
/// Yalnızca arama sonuçlarında çalışır: gezinme sayfalarında YouTube'a hiç istek
/// gitmez. Ayarlardaki anahtar kapalıyken `search` hemen boş döner ve elde
/// kalmış sonuçlar temizlenir.
@MainActor
@Observable
final class YouTubeStore {

    private(set) var query = ""
    private(set) var videos: [YouTubeVideo] = []
    private(set) var isSearching = false
    private(set) var message: String?

    @ObservationIgnored private let client = YouTubeClient()
    /// Her aramada artıyor: yavaş kalan eski bir istek, yenisinin sonuçlarının
    /// üstüne yazamıyor.
    @ObservationIgnored private var searchToken = 0

    func search(_ raw: String, isEnabled: Bool) async {
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        self.query = query

        guard isEnabled, query.count >= 2 else {
            clear()
            return
        }

        searchToken += 1
        let token = searchToken
        isSearching = true
        message = nil

        do {
            let found = try await client.search(query)
            guard token == searchToken else { return }
            videos = found
            message = nil
        } catch {
            guard token == searchToken else { return }
            videos = []
            message = (error as? LocalizedError)?.errorDescription ?? "YouTube araması başarısız."
        }
        isSearching = false
    }

    func clear() {
        videos = []
        message = nil
        isSearching = false
    }

    /// Devam noktası anahtarı: video kimliği kalıcı, oynatılan akış adresi ise
    /// yt-dlp her seferinde yeniden çözdüğü için geçici.
    static func resumeKey(for video: YouTubeVideo) -> String { "youtube:\(video.videoID)" }
}
