import Foundation
import Observation

/// Bir öneri, TMDB'den gelen tam başlık verisiyle birlikte saklanıyor —
/// eskiden yalnızca kimlik tutulup yerel katalogda aranıyordu, ama TMDB'nin
/// önerdiği başlık kütüphanede/ZyStream'de hiç bulunmayabilir.
struct RecommendationCacheEntry: Codable {
    var title: RemoteTitle
    var imdbRating: Double?
}

struct RecommendationCache: Codable {
    var fingerprint: String
    var computedAt: Date
    var entries: [RecommendationCacheEntry]
}

/// Ana ekranın "Sizin İçin Öneriler" rafını besler — TMDB'nin izlenmiş bir
/// film/diziyi tohum alan `/recommendations` uç noktasından.
///
/// Her açılışta yeniden sormuyoruz — izleme geçmişi (fingerprint) değişmediği
/// ve önbellek 12 saatten taze olduğu sürece son öneriler aynen kullanılıyor.
/// Değişmişse (yeni bir şey izlendi) ya da önbellek eskiyse TMDB'ye yeniden
/// soruluyor.
@Observable
final class RecommendationStore {
    private let file = LocalStore<RecommendationCache?>(fileName: "recommendations-cache.json",
                                                          defaultValue: nil)
    private(set) var cache: RecommendationCache?
    private(set) var isLoading = false
    private(set) var lastError: String?

    /// Önbellekteki (en fazla 20) seçimin ana ekranda hangi sırayla
    /// gösterileceği — her uygulama açılışında yeniden karılıyor ki aynı
    /// önbellek geçerliyken bile raf hep aynı sırada görünmesin.
    private(set) var displayIDs: [String] = []

    private static let refreshInterval: TimeInterval = 12 * 3600

    init() {
        cache = file.value
        if let cache { displayIDs = Self.shuffledIDs(from: cache) }
    }

    private static func shuffledIDs(from cache: RecommendationCache) -> [String] {
        cache.entries.map(\.title.id).shuffled()
    }

    func refreshIfNeeded(seeds: [TMDBRecommendationSeedBuilder.Seed], excluded: Set<String>,
                          settings: AppSettings) async {
        guard !isLoading, !seeds.isEmpty else { return }

        let fingerprint = Self.fingerprint(for: seeds)
        if let cache, cache.fingerprint == fingerprint,
           Date().timeIntervalSince(cache.computedAt) < Self.refreshInterval {
            return
        }

        isLoading = true
        defer { isLoading = false }

        let picks = await TMDBRecommender.recommend(seeds: seeds, excluded: excluded, settings: settings)
        guard !picks.isEmpty else { return }
        let entries = picks.map { RecommendationCacheEntry(title: $0.title, imdbRating: $0.imdbRating) }
        let newCache = RecommendationCache(fingerprint: fingerprint, computedAt: Date(), entries: entries)
        cache = newCache
        displayIDs = Self.shuffledIDs(from: newCache)
        file.replace(with: newCache)
        lastError = nil
    }

    /// Ana ekran rafı için: önbellekteki (en fazla 20) seçimin tamamı,
    /// açılışta karılmış sırayla. Aynı önbellek geçerli olsa bile her
    /// açılışta farklı bir sıralama gösterilsin diye önbellek sırası yerine
    /// `displayIDs`'i kullanır.
    func displayItems(limit: Int = TMDBRecommender.maxPicks) -> [(candidate: RecommendationCandidate, imdbRating: Double?)] {
        guard let cache else { return [] }
        let byID = Dictionary(uniqueKeysWithValues: cache.entries.map { ($0.title.id, $0) })
        let ordered = displayIDs.compactMap { id in
            byID[id].map { (candidate: RecommendationCandidate.remote($0.title), imdbRating: $0.imdbRating) }
        }
        return Array(ordered.prefix(limit))
    }

    private static func fingerprint(for seeds: [TMDBRecommendationSeedBuilder.Seed]) -> String {
        seeds.map { "\($0.kind.rawValue)-\($0.tmdbID)" }.sorted().joined(separator: "|")
    }
}
