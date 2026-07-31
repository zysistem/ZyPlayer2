import Foundation
import Observation

enum RemoteKind: String, Codable, Hashable {
    case movie
    case tv
}

/// A title that lives on TMDB rather than in the library — an In Cinemas film or
/// a search hit the user does not own. It carries only what a rail card and the
/// detail screen need.
///
/// Codable because a title the user favourites is kept: there is no library row
/// to hang that flag off.
struct RemoteTitle: Identifiable, Hashable, Codable {
    var kind: RemoteKind
    var tmdbID: Int
    var title: String
    var overview: String?
    var year: Int?
    /// TMDB vote average (0–10).
    var rating: Double?
    var posterPath: String?
    var backdropPath: String?

    var id: String { "\(kind.rawValue)-\(tmdbID)" }

    /// Remote artwork — unlike library posters these are not cached to disk,
    /// since the lists rotate and are cheap to refetch.
    var posterURL: URL? {
        posterPath.map { TMDBClient.imageURL(path: $0, size: "w500") }
    }

    var backdropURL: URL? {
        backdropPath.map { TMDBClient.imageURL(path: $0, size: "w1280") }
    }

    init(kind: RemoteKind, tmdbID: Int, title: String, overview: String? = nil,
         year: Int? = nil, rating: Double? = nil,
         posterPath: String? = nil, backdropPath: String? = nil) {
        self.kind = kind
        self.tmdbID = tmdbID
        self.title = title
        self.overview = overview
        self.year = year
        self.rating = rating
        self.posterPath = posterPath
        self.backdropPath = backdropPath
    }

    /// Tolerant decoding, like every stored model here: a favourites file
    /// written by an older build must still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = c.value(.kind, RemoteKind.movie)
        tmdbID = c.value(.tmdbID, 0)
        title = c.value(.title, "")
        overview = c.optional(.overview)
        year = c.optional(.year)
        rating = c.optional(.rating)
        posterPath = c.optional(.posterPath)
        backdropPath = c.optional(.backdropPath)
    }

    init(movie: MovieResult) {
        var displayTitle = movie.title
        if containsNonLatin(displayTitle), let orig = movie.originalTitle, !containsNonLatin(orig) {
            displayTitle = orig
        }
        self.init(kind: .movie, tmdbID: movie.id, title: displayTitle,
                  overview: movie.overview, year: movie.year, rating: movie.voteAverage,
                  posterPath: movie.posterPath, backdropPath: movie.backdropPath)
    }

    init(show: TVResult) {
        var displayName = show.name
        if containsNonLatin(displayName), let orig = show.originalName, !containsNonLatin(orig) {
            displayName = orig
        }
        self.init(kind: .tv, tmdbID: show.id, title: displayName,
                  overview: show.overview, year: show.year, rating: show.voteAverage,
                  posterPath: show.posterPath, backdropPath: show.backdropPath)
    }

    /// `search/multi` also returns people, which have neither title nor name we
    /// can show as a poster — those are dropped.
    init?(multi: MultiResult) {
        switch multi.mediaType {
        case "movie":
            guard let title = multi.title else { return nil }
            var displayTitle = title
            if containsNonLatin(displayTitle), let orig = multi.originalTitle, !containsNonLatin(orig) {
                displayTitle = orig
            }
            self.init(kind: .movie, tmdbID: multi.id, title: displayTitle,
                      overview: multi.overview, year: multi.year(for: .movie),
                      rating: multi.voteAverage,
                      posterPath: multi.posterPath, backdropPath: multi.backdropPath)
        case "tv":
            guard let name = multi.name else { return nil }
            var displayName = name
            if containsNonLatin(displayName), let orig = multi.originalName, !containsNonLatin(orig) {
                displayName = orig
            }
            self.init(kind: .tv, tmdbID: multi.id, title: displayName,
                      overview: multi.overview, year: multi.year(for: .tv),
                      rating: multi.voteAverage,
                      posterPath: multi.posterPath, backdropPath: multi.backdropPath)
        default:
            return nil
        }
    }
}

/// On-disk shape of `remote-favorites.json`. Kept out of `library.json` so a
/// favourite that belongs to no file cannot disturb the library itself.
struct RemoteFavoritesData: Codable {
    var titles: [RemoteTitle] = []

    init(titles: [RemoteTitle] = []) { self.titles = titles }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        titles = c.value(.titles, [])
    }
}

/// TMDB search for titles the library does not have. Kept apart from
/// `LibraryStore.search`, which stays a pure local filter.
@Observable
final class RemoteSearchStore {
    private(set) var results: [RemoteTitle] = []
    /// Actors and directors matching the query, so searching a name finds their
    /// work rather than nothing.
    private(set) var people: [PersonRef] = []
    private(set) var query = ""
    var isLoading = false

    @MainActor
    func search(_ text: String, settings: AppSettings) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard settings.hasTMDBToken, trimmed.count >= 2 else {
            results = []
            people = []
            query = trimmed
            return
        }
        isLoading = true
        defer { isLoading = false }

        let client = TMDBClient(token: settings.tmdbToken, language: settings.metadataLanguage)

        // IMDb kimliği ya da bağlantısı yazıldıysa başlık araması yapmak
        // anlamsız: `find` uç noktası kimliği doğrudan tek bir yapıma çevirir.
        if let imdbID = IMDbID.extract(from: trimmed) {
            await findByIMDb(imdbID, query: trimmed, client: client)
            return
        }

        guard let found = try? await client.searchMulti(query: trimmed) else { return }
        // The caller debounces with `.task(id:)`, so a stale response can still
        // land after the query moved on.
        guard !Task.isCancelled else { return }

        query = trimmed
        results = found.compactMap(RemoteTitle.init(multi:))
        people = found.compactMap(PersonRef.init(multi:))
    }

    /// IMDb kimliğini TMDB'de bulup sonuç listesine koyar. Kimlik tek bir yapıma
    /// karşılık geldiği için liste ya bir satırdır ya da boştur; kişi sonucu
    /// aranmaz, bir kimlik kişi eşleştirmez.
    @MainActor
    private func findByIMDb(_ imdbID: String, query text: String, client: TMDBClient) async {
        guard let found = try? await client.find(imdbID: imdbID) else { return }
        guard !Task.isCancelled else { return }

        query = text
        people = []
        results = found.movieResults.map(RemoteTitle.init(movie:))
            + found.tvResults.map(RemoteTitle.init(show:))
    }

    func clear() {
        results = []
        people = []
        query = ""
    }
}

/// Fills in what a search or cinema card does not carry: genres, runtime and the
/// IMDb id. Loaded once when the detail screen opens.
@Observable
final class RemoteDetailLoader {
    private(set) var genres: [String] = []
    private(set) var runtimeMinutes: Int?
    private(set) var seasonCount: Int?
    private(set) var imdbID: String?
    private(set) var rating: Double?
    private(set) var loadedID: String?
    private(set) var displayTitle: String?
    /// Yapımın kendi dilindeki adı. Akış sitelerinde arama yaparken yerel adın
    /// yanında bu da deneniyor: siteler başlıkları çoğunlukla orijinal adla
    /// listeliyor ("The Price of Confession - Jabaekui Daega" gibi), oysa TMDB
    /// Türkçe adı veriyor ("İtirafın Bedeli").
    private(set) var originalTitle: String?
    /// Seasons of a show, for the tabs. Specials (season 0) and empty seasons
    /// are dropped — nothing to play there.
    private(set) var seasons: [TVSeasonSummary] = []
    /// Episodes of the season on screen, keyed by season number so switching
    /// tabs back does not refetch.
    private(set) var episodes: [Int: [EpisodeDetail]] = [:]
    @ObservationIgnored private var loadingSeasons: Set<Int> = []

    @MainActor
    func load(_ title: RemoteTitle, settings: AppSettings) async {
        guard settings.hasTMDBToken, loadedID != title.id else { return }
        // Marked loaded even when the request fails, so anything waiting on the
        // identity (the torrent list) stops waiting and falls back to the title.
        defer { loadedID = title.id }
        let client = TMDBClient(token: settings.tmdbToken, language: settings.metadataLanguage)

        var finalTitle = title.title
        if containsNonLatin(finalTitle) {
            let engClient = TMDBClient(token: settings.tmdbToken, language: "en-US")
            switch title.kind {
            case .movie:
                if let detail = try? await engClient.movieDetail(id: title.tmdbID) {
                    finalTitle = detail.title
                }
            case .tv:
                if let detail = try? await engClient.tvDetail(id: title.tmdbID) {
                    finalTitle = detail.name
                }
            }
        }
        self.displayTitle = finalTitle

        switch title.kind {
        case .movie:
            guard let detail = try? await client.movieDetail(id: title.tmdbID) else { return }
            genres = detail.genres?.map(\.name) ?? []
            runtimeMinutes = detail.runtime
            imdbID = detail.imdbId
            rating = detail.voteAverage
            originalTitle = detail.originalTitle
        case .tv:
            guard let detail = try? await client.tvDetail(id: title.tmdbID) else { return }
            genres = detail.genres?.map(\.name) ?? []
            seasonCount = detail.numberOfSeasons
            rating = detail.voteAverage
            originalTitle = detail.originalName
            seasons = (detail.seasons ?? []).filter {
                ($0.seasonNumber ?? 0) > 0 && ($0.episodeCount ?? 0) > 0
            }
            // TV keeps its IMDb id in a separate payload.
            imdbID = try? await client.externalIDs(tvID: title.tmdbID).imdbId
        }
        loadedID = title.id
    }

    /// Pulls one season's episodes, once.
    @MainActor
    func loadSeason(_ season: Int, of title: RemoteTitle, settings: AppSettings) async {
        guard settings.hasTMDBToken, title.kind == .tv,
              episodes[season] == nil, !loadingSeasons.contains(season) else { return }
        loadingSeasons.insert(season)
        defer { loadingSeasons.remove(season) }

        let client = TMDBClient(token: settings.tmdbToken, language: settings.metadataLanguage)
        guard let detail = try? await client.seasonDetail(showID: title.tmdbID, season: season)
        else { return }
        episodes[season] = detail.episodes ?? []
    }

    func isLoadingSeason(_ season: Int) -> Bool { loadingSeasons.contains(season) }
}

func containsNonLatin(_ string: String) -> Bool {
    for scalar in string.unicodeScalars {
        if scalar.value < 0x0370 {
            continue
        }
        if CharacterSet.letters.contains(scalar) {
            return true
        }
    }
    return false
}
