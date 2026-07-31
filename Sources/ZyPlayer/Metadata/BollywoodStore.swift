import Foundation
import Observation

/// Hindistan yapımı filmler: gelecek gösterimdekiler ve çıkmış olanlar.
///
/// `CinemaStore` gibi hiçbir şey diske yazılmıyor — liste TMDB'nin canlı
/// görüntüsü, her açılışta yeniden çekiliyor ki vizyon takvimi güncel kalsın.
@Observable
final class BollywoodStore {
    private(set) var upcoming: [RemoteTitle] = []
    private(set) var released: [RemoteTitle] = []
    /// TMDB kimliğinden IMDb puanına. Filmler geldikten sonra ayrıca dolduruluyor:
    /// kartlar puan beklemeden çiziliyor, puanlar hazır olunca beliriyor.
    private(set) var imdbRatings: [Int: Double] = [:]
    var isLoading = false

    func imdbRating(for tmdbID: Int) -> Double? { imdbRatings[tmdbID] }

    /// Toplam gösterilecek film sayısı.
    static let total = 60
    /// Bunun kadarı gelecek gösterimde olanlara ayrılıyor; o kadar film yoksa
    /// kalan yer çıkmış filmlerle doluyor, toplam yine 60 oluyor.
    private static let upcomingQuota = 20

    var all: [RemoteTitle] { upcoming + released }

    @MainActor
    func refresh(settings: AppSettings) async {
        guard settings.hasTMDBToken, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        let client = TMDBClient(token: settings.tmdbToken, language: settings.metadataLanguage)

        // Sayfa başına 20 sonuç: gelecek için 2, çıkmışlar için 4 sayfa çekip
        // eleme sonrası 60'ı doldurmaya yetecek kadar malzeme bırakıyoruz.
        async let upcomingPages = Self.fetch(client: client, upcoming: true, pages: 2)
        async let releasedPages = Self.fetch(client: client, upcoming: false, pages: 4)

        let futures = await upcomingPages
        let past = await releasedPages

        var seen = Set<Int>()
        let futureUnique = futures.filter { seen.insert($0.tmdbID).inserted }
        let pastUnique = past.filter { seen.insert($0.tmdbID).inserted }

        upcoming = Array(futureUnique.prefix(Self.upcomingQuota))
        released = Array(pastUnique.prefix(Self.total - upcoming.count))

        await loadIMDbRatings(client: client)
    }

    /// Kartlardaki IMDb puanları.
    ///
    /// TMDB'nin keşif yanıtı IMDb kimliğini taşımıyor, o yüzden her film için
    /// ayrıntı isteği gerekiyor. İstekler sekizerli gruplar hâlinde gidiyor:
    /// altmış istek tek seferde açıldığında TMDB hız sınırına takılıyor.
    @MainActor
    private func loadIMDbRatings(client: TMDBClient) async {
        let titles = all
        var imdbIDs: [Int: String] = [:]

        await withTaskGroup(of: (Int, String?).self) { group in
            var iterator = titles.makeIterator()
            var inFlight = 0

            func submitNext() {
                guard let title = iterator.next() else { return }
                inFlight += 1
                group.addTask {
                    (title.tmdbID, try? await client.movieDetail(id: title.tmdbID).imdbId)
                }
            }
            for _ in 0..<8 { submitNext() }
            while let (tmdbID, imdbID) = await group.next() {
                inFlight -= 1
                if let imdbID, !imdbID.isEmpty { imdbIDs[tmdbID] = imdbID }
                submitNext()
            }
            _ = inFlight
        }

        let ratings = await IMDbRatingStore.ratings(for: Array(imdbIDs.values))
        imdbRatings = imdbIDs.compactMapValues { ratings[$0] }
    }

    private static func fetch(client: TMDBClient, upcoming: Bool, pages: Int) async -> [RemoteTitle] {
        await withTaskGroup(of: (Int, [MovieResult]).self) { group in
            for page in 1...pages {
                group.addTask {
                    (page, (try? await client.indianMovies(upcoming: upcoming, page: page)) ?? [])
                }
            }
            var collected: [(Int, [MovieResult])] = []
            for await result in group { collected.append(result) }
            return collected
                .sorted { $0.0 < $1.0 }   // TMDB'nin sırası korunsun
                .flatMap(\.1)
                // Afişi olmayan kayıtlar ızgarada boş kart olarak duruyor.
                .filter { $0.posterPath != nil }
                .map(RemoteTitle.init(movie:))
        }
    }
}
