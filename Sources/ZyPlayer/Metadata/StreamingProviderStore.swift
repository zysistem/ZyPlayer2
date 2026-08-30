import Foundation
import Observation

/// Ana ekranda rafı olan yayın platformları.
///
/// TMDB kimlikleri bölgeye göre ayrışabiliyor: Prime Video kimi ülkede 9, kimi
/// ülkede 119 olarak listeleniyor, o yüzden ikisi de VEYA'lanarak soruluyor.
enum StreamingBrand: String, CaseIterable, Identifiable {
    case netflix
    case primeVideo
    case disneyPlus
    case hboMax
    case paramountPlus
    case appleTVPlus

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .netflix: "Netflix"
        case .primeVideo: "Amazon Prime Video"
        case .disneyPlus: "Disney+"
        case .hboMax: "HBO Max"
        case .paramountPlus: "Paramount+"
        case .appleTVPlus: "Apple TV+"
        }
    }

    /// `with_watch_providers` alanına giden değer. Bazı platformlar bölgeye
    /// göre iki kimlikten biriyle listeleniyor, o yüzden VEYA'lanıyor: Prime
    /// Video (9/119), HBO Max — eski adıyla kimi ülkede hâlâ 384, yeni marka
    /// "Max" 1899.
    var providerQuery: String {
        switch self {
        case .netflix: "8"
        case .primeVideo: "9|119"
        case .disneyPlus: "337"
        case .hboMax: "384|1899"
        case .paramountPlus: "531"
        case .appleTVPlus: "350"
        }
    }

    /// Logo aranırken kullanılacak asıl kimlik; bulunamazsa `logoFallbackID`.
    var logoProviderID: Int {
        switch self {
        case .netflix: 8
        case .primeVideo: 119
        case .disneyPlus: 337
        case .hboMax: 1899
        case .paramountPlus: 531
        case .appleTVPlus: 350
        }
    }

    var logoFallbackID: Int {
        switch self {
        case .netflix: 8
        case .primeVideo: 9
        case .disneyPlus: 337
        case .hboMax: 384
        case .paramountPlus: 531
        case .appleTVPlus: 350
        }
    }
}

/// Netflix ve Prime Video kataloglarının en yeni başlıkları, TMDB'den.
///
/// `CinemaStore`/`AppleTVStore` gibi hiçbir şey saklanmıyor — canlı bir görünüm.
/// Marka logoları da TMDB'den geliyor (`watch/providers`), böylece uygulamaya
/// gömülü görsel taşımıyoruz.
@Observable
final class StreamingProviderStore {

    /// Bir platformun ana ekrandaki iki rafı.
    struct Shelf: Identifiable {
        let brand: StreamingBrand
        let movies: [RemoteTitle]
        let shows: [RemoteTitle]

        var id: String { brand.id }
        var isEmpty: Bool { movies.isEmpty && shows.isEmpty }
    }

    private(set) var shelves: [Shelf] = []
    private(set) var isLoading = false

    /// TMDB platform kimliği → logo yolu.
    private(set) var logoPaths: [Int: String] = [:]

    /// Sidebar'daki tek platform sayfası (Netflix, Amazon, Disney+, HBO Max,
    /// Apple TV+): "son eklenen 50" film + 50 dizi. Ana ekranın 10'ar öğelik
    /// `shelves`'inden ayrı tutuluyor — yalnızca kullanıcı o markanın kendi
    /// sayfasını açınca, ihtiyaç anında yükleniyor.
    struct BrandDetail {
        var movies: [RemoteTitle] = []
        var shows: [RemoteTitle] = []
        var isLoading = false
        var isLoaded = false
    }
    private(set) var brandDetails: [StreamingBrand: BrandDetail] = [:]
    /// Bir sayfada 20 sonuç geldiğinden, posterli 50 bırakmak için 3 sayfa çekilir.
    private static let detailPages = 3
    private static let detailCount = 50

    func detail(for brand: StreamingBrand) -> BrandDetail {
        brandDetails[brand] ?? BrandDetail()
    }

    @MainActor
    func refreshDetail(for brand: StreamingBrand, settings: AppSettings) async {
        guard settings.hasTMDBToken else { return }
        guard brandDetails[brand]?.isLoaded != true, brandDetails[brand]?.isLoading != true else { return }
        brandDetails[brand, default: BrandDetail()].isLoading = true

        let client = TMDBClient(token: settings.tmdbToken, language: settings.metadataLanguage)
        let region = Self.region(for: settings.metadataLanguage)

        if logoPaths[brand.logoProviderID] == nil, logoPaths[brand.logoFallbackID] == nil,
           let logos = try? await client.watchProviderLogos(region: region) {
            logoPaths = logos
        }

        var movies: [RemoteTitle] = []
        var shows: [RemoteTitle] = []
        for page in 1...Self.detailPages {
            if let results = try? await client.providerMovies(
                providerIDs: brand.providerQuery, region: region, page: page) {
                movies += results.filter { $0.posterPath != nil }.map(RemoteTitle.init(movie:))
            }
            if let results = try? await client.providerShows(
                providerIDs: brand.providerQuery, region: region, page: page) {
                shows += results.filter { $0.posterPath != nil }.map(RemoteTitle.init(show:))
            }
        }
        brandDetails[brand] = BrandDetail(
            movies: Array(Self.deduplicated(movies).prefix(Self.detailCount)),
            shows: Array(Self.deduplicated(shows).prefix(Self.detailCount)),
            isLoading: false,
            isLoaded: true
        )
    }

    /// Raf başına gösterilen başlık sayısı.
    static let count = 10
    /// Afişsiz kayıtlar elendikten sonra ondan azı kalabiliyor; ikinci sayfa
    /// bunun için.
    private static let pages = 2

    func logoURL(for brand: StreamingBrand) -> URL? {
        let path = logoPaths[brand.logoProviderID] ?? logoPaths[brand.logoFallbackID]
        return path.map { TMDBClient.imageURL(path: $0, size: "w92") }
    }

    @MainActor
    func refresh(settings: AppSettings) async {
        guard settings.hasTMDBToken, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        let client = TMDBClient(token: settings.tmdbToken, language: settings.metadataLanguage)
        let region = Self.region(for: settings.metadataLanguage)

        if let logos = try? await client.watchProviderLogos(region: region) {
            logoPaths = logos
        }

        var built: [Shelf] = []
        for brand in StreamingBrand.allCases {
            var movies: [RemoteTitle] = []
            var shows: [RemoteTitle] = []
            for page in 1...Self.pages {
                if movies.count < Self.count,
                   let results = try? await client.providerMovies(
                       providerIDs: brand.providerQuery, region: region, page: page) {
                    movies += results.filter { $0.posterPath != nil }.map(RemoteTitle.init(movie:))
                }
                if shows.count < Self.count,
                   let results = try? await client.providerShows(
                       providerIDs: brand.providerQuery, region: region, page: page) {
                    shows += results.filter { $0.posterPath != nil }.map(RemoteTitle.init(show:))
                }
            }
            built.append(Shelf(
                brand: brand,
                movies: Array(Self.deduplicated(movies).prefix(Self.count)),
                shows: Array(Self.deduplicated(shows).prefix(Self.count))
            ))
        }
        shelves = built
    }

    /// Katalog ülkeye göre değişiyor; "tr-TR" → "TR". Dil kodu ülke taşımıyorsa
    /// Türkiye varsayılıyor.
    private static func region(for language: String) -> String {
        let parts = language.split(separator: "-")
        guard parts.count == 2, parts[1].count == 2 else { return "TR" }
        return parts[1].uppercased()
    }

    private static func deduplicated(_ titles: [RemoteTitle]) -> [RemoteTitle] {
        var seen = Set<String>()
        return titles.filter { seen.insert($0.id).inserted }
    }
}
