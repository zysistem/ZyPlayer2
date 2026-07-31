import Foundation
import Observation

/// Apple TV+ originals, straight from TMDB. Like `CinemaStore`, nothing here is
/// persisted — it is a live view, and the user owns none of it by definition.
@Observable
final class AppleTVStore {
    private(set) var movies: [RemoteTitle] = []
    private(set) var shows: [RemoteTitle] = []
    var isLoading = false

    /// Fetch 5 pages of each (around 100 movies and 100 shows).
    private static let pages = 5

    @MainActor
    func refresh(settings: AppSettings) async {
        guard settings.hasTMDBToken, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        let client = TMDBClient(token: settings.tmdbToken, language: settings.metadataLanguage)

        var collectedShows: [RemoteTitle] = []
        var collectedMovies: [RemoteTitle] = []
        for page in 1...Self.pages {
            if let results = try? await client.appleTVShows(page: page) {
                let released = results.filter { Self.isReleased(dateString: $0.firstAirDate) }
                collectedShows += released.map(RemoteTitle.init(show:))
            }
            if let results = try? await client.appleTVMovies(page: page) {
                let released = results.filter { Self.isReleased(dateString: $0.releaseDate) }
                collectedMovies += released.map(RemoteTitle.init(movie:))
            }
        }

        // A title can repeat across pages when the ranking shifts mid-fetch.
        shows = Self.deduplicated(collectedShows)
        movies = Self.deduplicated(collectedMovies)
    }

    private static func isReleased(dateString: String?) -> Bool {
        guard let dateString, !dateString.isEmpty else { return false }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        guard let releaseDate = formatter.date(from: dateString) else { return false }
        return releaseDate <= Date()
    }

    private static func deduplicated(_ titles: [RemoteTitle]) -> [RemoteTitle] {
        var seen = Set<String>()
        return titles.filter { seen.insert($0.id).inserted }
    }
}
