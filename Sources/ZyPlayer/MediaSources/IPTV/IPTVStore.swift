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
    private(set) var favorites: [IPTVFavorite] = []

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
        favorites = favoritesFile.value.items
        rebuildIndex()
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
            rebuildIndex()
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

    // MARK: - Dizin
    //
    // Ülke kararı ve arama için ad normalizasyonu düzenli ifade ve Unicode
    // katlama çalıştırıyor. Yirmi binden fazla kayıt üzerinde her tuş
    // vuruşunda yeniden hesaplanınca arama kutusu kilitleniyordu; ikisi de
    // katalog yüklendiğinde bir kez hesaplanıp burada tutuluyor.

    /// Bir kaydın süzme için gereken, önceden çıkarılmış bilgileri.
    private struct Indexed<Item> {
        let item: Item
        /// Aramada karşılaştırılan ad: harf ve şapka duyarsız.
        let folded: String
        /// Adın kendi ülke öneki ("TR: TRT 1" → "TR"), varsa.
        let code: String?
        let categoryID: String?
    }

    @ObservationIgnored private var indexedChannels: [Indexed<IPTVChannel>] = []
    @ObservationIgnored private var indexedMovies: [Indexed<IPTVMovie>] = []
    @ObservationIgnored private var indexedSeries: [Indexed<IPTVSeries>] = []
    /// Ülkesi TR olan (ya da hiç belirtilmemiş) kategorilerin kimlikleri.
    @ObservationIgnored private var allowedCategoryIDs: [IPTVSection: Set<String>] = [:]

    private static let searchLocale = Locale(identifier: "tr_TR")

    private static func fold(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: searchLocale)
    }

    private func rebuildIndex() {
        indexedChannels = catalog.channels.map {
            Indexed(item: $0, folded: Self.fold($0.name),
                    code: IPTVNaming.split($0.name).code, categoryID: $0.categoryID)
        }
        indexedMovies = catalog.movies.map {
            Indexed(item: $0, folded: Self.fold($0.name),
                    code: IPTVNaming.split($0.name).code, categoryID: $0.categoryID)
        }
        indexedSeries = catalog.series.map {
            Indexed(item: $0, folded: Self.fold($0.name),
                    code: IPTVNaming.split($0.name).code, categoryID: $0.categoryID)
        }
        for section in IPTVSection.allCases {
            allowedCategoryIDs[section] = Set(
                allCategories(for: section)
                    .filter { category in
                        // Ülkesi hiç belirtilmemiş kategori eleniyormuş gibi
                        // davranılmıyor: belirsizlik yüzünden içerik gizlemek,
                        // fazladan içerik göstermekten kötü.
                        guard let code = IPTVNaming.split(category.name).code else { return true }
                        return code == "TR"
                    }
                    .map(\.id)
            )
        }
    }

    /// Ülke süzgeci. Kanal adları ülkeyi taşıyor ("TR: TRT 1") ama film ve dizi
    /// adları taşımıyor ("O da Bir Şey mi?"); onların ülkesi ancak
    /// kategorisinden ("|TR| 2026 FiLMLERi") anlaşılıyor.
    private func isAllowed<Item>(_ entry: Indexed<Item>, in section: IPTVSection) -> Bool {
        guard settings.iptvOnlyTurkish else { return true }
        // Adın kendi öneki varsa doğrudan karar veriyor: "FR: TF1" kategorisi
        // ne olursa olsun Fransız.
        if let code = entry.code, code.count == 2 || code.count == 3 {
            return code == "TR"
        }
        guard let categoryID = entry.categoryID else { return true }
        return allowedCategoryIDs[section]?.contains(categoryID) ?? true
    }

    private func allCategories(for section: IPTVSection) -> [IPTVCategory] {
        switch section {
        case .live: catalog.liveCategories
        case .movies: catalog.movieCategories
        case .series: catalog.seriesCategories
        }
    }

    func categories(for section: IPTVSection) -> [IPTVCategory] {
        guard settings.iptvOnlyTurkish else { return allCategories(for: section) }
        let allowed = allowedCategoryIDs[section] ?? []
        return allCategories(for: section).filter { allowed.contains($0.id) }
    }

    func channels(categoryID: String?) -> [IPTVChannel] {
        indexedChannels.filter {
            (categoryID == nil || $0.categoryID == categoryID) && isAllowed($0, in: .live)
        }.map(\.item)
    }

    func movies(categoryID: String?) -> [IPTVMovie] {
        indexedMovies.filter {
            (categoryID == nil || $0.categoryID == categoryID) && isAllowed($0, in: .movies)
        }.map(\.item)
    }

    func series(categoryID: String?) -> [IPTVSeries] {
        indexedSeries.filter {
            (categoryID == nil || $0.categoryID == categoryID) && isAllowed($0, in: .series)
        }.map(\.item)
    }

    // MARK: - Ayrıntılar

    @ObservationIgnored private var detailCache: [String: IPTVDetail] = [:]

    /// Bir filmin ayrıntıları. Sağlayıcı özet, oyuncu ve türü Türkçe veriyor;
    /// afiş ve arka plan ise düşük çözünürlüklü ve kendi sunucusundan geliyor,
    /// bu yüzden bildirdiği TMDB kimliğiyle oradan tazeleniyor.
    func detail(for movie: IPTVMovie) async -> IPTVDetail? {
        let key = "movie:\(movie.id)"
        if let cached = detailCache[key] { return cached }
        guard var detail = try? await client.movieDetail(vodID: movie.id) else { return nil }
        await enrich(&detail, kind: .movie)
        detailCache[key] = detail
        return detail
    }

    /// Bir dizinin ayrıntıları ve bölümleri; tek istekte geliyor.
    func detail(for series: IPTVSeries) async -> (detail: IPTVDetail, episodes: [Int: [IPTVEpisode]])? {
        let key = "series:\(series.id)"
        guard var result = try? await client.seriesDetail(seriesID: series.id) else { return nil }
        if let cached = detailCache[key] {
            return (cached, result.episodes)
        }
        await enrich(&result.detail, kind: .tv)
        detailCache[key] = result.detail
        episodeCache[series.id] = result.episodes
        return (result.detail, result.episodes)
    }

    /// TMDB'den yalnızca görseller alınıyor: metinler zaten Türkçe geliyor ve
    /// sağlayıcının kendi özeti çoğu zaman daha eksiksiz.
    private func enrich(_ detail: inout IPTVDetail, kind: RemoteKind) async {
        guard let tmdbID = detail.tmdbID, settings.hasTMDBToken else { return }
        let client = TMDBClient(token: settings.tmdbToken, language: settings.metadataLanguage)
        switch kind {
        case .movie:
            guard let found = try? await client.movieDetail(id: tmdbID) else { return }
            detail.tmdbPosterPath = found.posterPath
            detail.tmdbBackdropPath = found.backdropPath
            if detail.plot?.isEmpty ?? true { detail.plot = found.overview }
        case .tv:
            guard let found = try? await client.tvDetail(id: tmdbID) else { return }
            detail.tmdbPosterPath = found.posterPath
            detail.tmdbBackdropPath = found.backdropPath
            if detail.plot?.isEmpty ?? true { detail.plot = found.overview }
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
        let needle = Self.fold(trimmed)

        /// Aranan sayıya ulaşınca duruyor: tüm katalogda eşleşme toplayıp
        /// sonunda kırpmak, ilk birkaç sonuç için yirmi bin kaydı taramak
        /// demekti.
        func take<Item>(_ entries: [Indexed<Item>], _ section: IPTVSection) -> [Item] {
            var result: [Item] = []
            for entry in entries where entry.folded.contains(needle) {
                // Ülke süzgeci burada da geçerli: aramada gizlenen bir içeriğin
                // çıkması, listede olmayan bir şeyi oynatmak demek olurdu.
                guard isAllowed(entry, in: section) else { continue }
                result.append(entry.item)
                if result.count == limitPerSection { break }
            }
            return result
        }

        return (take(indexedChannels, .live),
                take(indexedMovies, .movies),
                take(indexedSeries, .series))
    }

    // MARK: - Favoriler

    /// Favoriler kendi dosyasında: katalog 12 saatte bir baştan yazılıyor,
    /// içine konsa her tazelemede silinirdi.
    @ObservationIgnored private let favoritesFile = LocalStore(
        fileName: "iptv-favorites.json", defaultValue: IPTVFavoritesData()
    )

    func isFavorite(_ favorite: IPTVFavorite) -> Bool {
        favorites.contains { $0.id == favorite.id }
    }

    func toggleFavorite(_ favorite: IPTVFavorite) {
        if let index = favorites.firstIndex(where: { $0.id == favorite.id }) {
            favorites.remove(at: index)
        } else {
            favorites.append(favorite)
        }
        favoritesFile.replace(with: IPTVFavoritesData(items: favorites))
    }

    /// Favorideki kaydı güncel katalogdaki kanala bağlar — canlı yayın
    /// oynatmak için kanal listesi de gerekiyor.
    func channel(withID id: Int) -> IPTVChannel? {
        catalog.channels.first { $0.id == id }
    }

    func series(withID id: Int) -> IPTVSeries? {
        catalog.series.first { $0.id == id }
    }

    /// Favori kaydından doğrudan oynatma adresi. Katalogda artık bulunmayan
    /// bir içerik için de çalışıyor: adres yalnızca kimlik ve uzantıdan kuruluyor.
    func url(for favorite: IPTVFavorite) -> URL? {
        switch favorite.kind {
        case .channel:
            return client.liveURL(IPTVChannel(id: favorite.streamID, name: favorite.name))
        case .movie:
            return client.movieURL(IPTVMovie(
                id: favorite.streamID, name: favorite.name,
                containerExtension: favorite.containerExtension ?? "mp4"
            ))
        case .series:
            return nil   // Dizi doğrudan oynatılmıyor; bölüm listesi açılıyor.
        }
    }

    // MARK: - Oynatma adresleri

    func url(for channel: IPTVChannel) -> URL? { client.liveURL(channel) }
    func url(for movie: IPTVMovie) -> URL? { client.movieURL(movie) }
    func url(for episode: IPTVEpisode) -> URL? { client.episodeURL(episode) }
}
