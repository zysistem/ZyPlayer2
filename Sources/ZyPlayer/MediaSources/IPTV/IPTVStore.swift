import Foundation
import Observation

/// IPTV kataloğunu tutar: kanallar, filmler, diziler ve kategorileri.
///
/// Katalog diske yazılıyor. Sebebi boyut: sağlayıcının film listesi tek başına
/// ~15 MB ve üç liste birlikte on binlerce kayıt; her açılışta yeniden indirmek
/// bölümün açılmasını dakikalarca bekletirdi. Saklanan katalog yaşlandığında
/// arka planda tazeleniyor, kullanıcı beklemiyor.
@MainActor
@Observable
final class IPTVStore {

    private(set) var catalog = IPTVCatalog()
    private(set) var isLoading = false
    private(set) var statusMessage = ""
    /// Abonelik durumu — bitmiş bir hesapta liste boş kalır, sebebi söylenmeli.
    private(set) var accountLine = ""

    @ObservationIgnored private let file = LocalStore(
        fileName: "iptv-catalog.json", defaultValue: IPTVCatalog()
    )
    @ObservationIgnored private var settings: AppSettings
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    /// Bir dizinin bölümleri ilk açılışta çekilip burada tutuluyor.
    @ObservationIgnored private var episodeCache: [Int: [Int: [IPTVEpisode]]] = [:]

    /// Bu yaştan sonra katalog kendiliğinden tazeleniyor. Sağlayıcı içeriği
    /// gün içinde de değiştirdiği için Ayarlar'da elle yenileme düğmesi var.
    private static let maxAge: TimeInterval = 12 * 60 * 60

    init(settings: AppSettings) {
        self.settings = settings
        catalog = file.value
    }

    var credentials: IPTVCredentials { settings.iptvCredentials }
    var isConfigured: Bool { credentials.isConfigured }
    private var client: IPTVClient { IPTVClient(credentials: credentials) }

    var lastUpdated: Date? { catalog.updatedAt }

    // MARK: - Yükleme

    /// Katalog yoksa ya da yaşlandıysa indirir. `force` ile yaş gözetilmez —
    /// Ayarlar'daki "İçerikleri Güncelle" bunu kullanıyor.
    func load(force: Bool = false) async {
        guard isConfigured else {
            statusMessage = "IPTV bilgileri girilmemiş. Ayarlar → IP Tv bölümünden ekleyin."
            return
        }
        if !force, !catalog.isEmpty, let updated = catalog.updatedAt,
           Date().timeIntervalSince(updated) < Self.maxAge {
            return
        }
        // Aynı anda iki indirme başlamasın: bölüm açılırken ve elle yenilenirken
        // ikisi birden tetiklenebiliyor ve sağlayıcı eşzamanlı bağlantıyı
        // sınırlıyor.
        if let loadTask {
            await loadTask.value
            return
        }
        let task = Task { await performLoad() }
        loadTask = task
        await task.value
        loadTask = nil
    }

    private func performLoad() async {
        isLoading = true
        statusMessage = ""
        defer { isLoading = false }

        let client = self.client
        do {
            let account = try await client.account()
            if let message = account.message {
                accountLine = message
                statusMessage = message
                return
            }
            accountLine = Self.accountLine(account)

            // Sırayla: sağlayıcı eşzamanlı isteklerde bağlantı sınırına takılıp
            // yarıda kesebiliyor.
            let liveCategories = (try? await client.categories(for: .live)) ?? []
            let movieCategories = (try? await client.categories(for: .movies)) ?? []
            let seriesCategories = (try? await client.categories(for: .series)) ?? []
            let channels = (try? await client.channels()) ?? []
            let movies = (try? await client.movies()) ?? []
            let series = (try? await client.series()) ?? []

            guard !channels.isEmpty || !movies.isEmpty || !series.isEmpty else {
                statusMessage = "Sunucudan içerik alınamadı."
                return
            }

            var fresh = IPTVCatalog()
            fresh.channels = channels
            fresh.movies = movies
            fresh.series = series
            fresh.liveCategories = liveCategories
            fresh.movieCategories = movieCategories
            fresh.seriesCategories = seriesCategories
            fresh.updatedAt = Date()

            catalog = fresh
            file.replace(with: fresh)
            episodeCache.removeAll()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private static func accountLine(_ account: IPTVClient.Account) -> String {
        var parts = ["Abonelik etkin"]
        if let expires = account.expiresAt {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            parts.append("bitiş \(formatter.string(from: expires))")
        }
        if let max = account.maxConnections {
            parts.append("\(max) eşzamanlı bağlantı")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Kategoriler ve listeler

    /// Ülke süzgeci. Sağlayıcı kataloğunda onlarca ülkenin yayını var; ayar
    /// açıkken yalnızca TR olanlar listeleniyor.
    ///
    /// Karar kategoriye bakarak veriliyor: kanal adları ülkeyi taşıyor
    /// ("TR: TRT 1") ama film ve dizi adları taşımıyor ("O da Bir Şey mi?"),
    /// onların ülkesi ancak kategorisinden ("|TR| 2026 FiLMLERi") anlaşılıyor.
    /// Ülkesi hiç belirtilmemiş kategoriler eleniyormuş gibi davranılmıyor —
    /// belirsizlik yüzünden içerik gizlemek, fazladan içerik göstermekten kötü.
    private func isAllowed(categoryID: String?, in section: IPTVSection) -> Bool {
        guard settings.iptvOnlyTurkish else { return true }
        guard let categoryID,
              let category = allCategories(for: section).first(where: { $0.id == categoryID }),
              let code = IPTVNaming.split(category.name).code
        else { return true }
        return code == "TR"
    }

    private func isAllowed(name: String, categoryID: String?, in section: IPTVSection) -> Bool {
        guard settings.iptvOnlyTurkish else { return true }
        // Adın kendi öneki varsa doğrudan karar veriyor: "FR: TF1" kategorisi
        // ne olursa olsun Fransız.
        if let code = IPTVNaming.split(name).code, code.count == 2 || code.count == 3 {
            return code == "TR"
        }
        return isAllowed(categoryID: categoryID, in: section)
    }

    private func allCategories(for section: IPTVSection) -> [IPTVCategory] {
        switch section {
        case .live: catalog.liveCategories
        case .movies: catalog.movieCategories
        case .series: catalog.seriesCategories
        }
    }

    func categories(for section: IPTVSection) -> [IPTVCategory] {
        allCategories(for: section).filter { isAllowed(categoryID: $0.id, in: section) }
    }

    func channels(categoryID: String?) -> [IPTVChannel] {
        catalog.channels.filter { channel in
            if let categoryID, channel.categoryID != categoryID { return false }
            return isAllowed(name: channel.name, categoryID: channel.categoryID, in: .live)
        }
    }

    func movies(categoryID: String?) -> [IPTVMovie] {
        catalog.movies.filter { movie in
            if let categoryID, movie.categoryID != categoryID { return false }
            return isAllowed(name: movie.name, categoryID: movie.categoryID, in: .movies)
        }
    }

    func series(categoryID: String?) -> [IPTVSeries] {
        catalog.series.filter { item in
            if let categoryID, item.categoryID != categoryID { return false }
            return isAllowed(name: item.name, categoryID: item.categoryID, in: .series)
        }
    }

    /// Bir dizinin bölümleri; ilk istekte sunucudan çekilip saklanıyor.
    func episodes(for series: IPTVSeries) async -> [Int: [IPTVEpisode]] {
        if let cached = episodeCache[series.id] { return cached }
        let fetched = (try? await client.episodes(seriesID: series.id)) ?? [:]
        episodeCache[series.id] = fetched
        return fetched
    }

    // MARK: - Arama

    /// Genel aramaya karışan IPTV sonuçları. Her tür için ayrı sınır: tek bir
    /// tür bütün listeyi doldurmasın.
    func search(_ query: String, limitPerSection: Int = 8)
    -> (channels: [IPTVChannel], movies: [IPTVMovie], series: [IPTVSeries]) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return ([], [], []) }
        let needle = trimmed.folding(options: [.diacriticInsensitive, .caseInsensitive],
                                     locale: Locale(identifier: "tr_TR"))

        func matches(_ name: String) -> Bool {
            name.folding(options: [.diacriticInsensitive, .caseInsensitive],
                         locale: Locale(identifier: "tr_TR")).contains(needle)
        }

        // Ülke süzgeci burada da geçerli: aramada gizlenen bir içeriğin
        // çıkması, listede olmayan bir şeyi oynatmak demek olurdu.
        return (
            Array(channels(categoryID: nil).filter { matches($0.name) }.prefix(limitPerSection)),
            Array(movies(categoryID: nil).filter { matches($0.name) }.prefix(limitPerSection)),
            Array(series(categoryID: nil).filter { matches($0.name) }.prefix(limitPerSection))
        )
    }

    // MARK: - Oynatma adresleri

    func url(for channel: IPTVChannel) -> URL? { client.liveURL(channel) }
    func url(for movie: IPTVMovie) -> URL? { client.movieURL(movie) }
    func url(for episode: IPTVEpisode) -> URL? { client.episodeURL(episode) }
}
