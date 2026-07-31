import Foundation
import Observation

/// Fetches and holds the "In Cinemas" list. Kept apart from `LibraryStore`
/// because none of this is persisted — it is a live view of TMDB.
@Observable
final class CinemaStore {
    private(set) var movies: [RemoteTitle] = []
    var isLoading = false

    /// Ana ekrandaki fragman kuşağında gösterilen film sayısı.
    private static let count = 15

    @MainActor
    func refresh(settings: AppSettings) async {
        guard settings.hasTMDBToken, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        let client = TMDBClient(token: settings.tmdbToken, language: settings.metadataLanguage)

        // themoviedb.org/movie/now-playing sayfasının listesi. Sitedeki sıra
        // `region=US` ile birebir örtüşüyor (bölgesiz çağrı araya başka filmler
        // katıyor), o yüzden sıralama olduğu gibi korunuyor — kuşak siteyle aynı
        // filmleri aynı sırada gösteriyor. Uygulama her açılışta yeniden
        // çektiği için liste TMDB'de değiştikçe kendiliğinden tazeleniyor.
        //
        // İkinci sayfa yalnızca yedek: fragman kuşağı arka plan görseli olmayan
        // filmleri eliyor ve ilk sayfadan on tane kalmayabiliyor.
        var collected: [MovieResult] = []
        for page in 1...3 {
            guard let results = try? await client.nowPlaying(region: "US", page: page) else { break }
            collected += results
            if collected.filter({ $0.backdropPath != nil }).count >= Self.count { break }
        }

        var seen = Set<Int>()
        let unique = collected.filter { seen.insert($0.id).inserted }
        let usable = unique.filter { $0.backdropPath != nil }
        movies = (usable.isEmpty ? unique : usable)
            .prefix(Self.count)
            .map(RemoteTitle.init(movie:))
    }
}
