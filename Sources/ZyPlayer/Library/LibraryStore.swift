import Foundation
import Observation

/// The library: folders the user added, the items found inside them, and watch
/// progress. Persisted as JSON — no database, by design.
@Observable
final class LibraryStore {

    private(set) var folders: [LibraryFolder] = []
    private(set) var items: [MediaItem] = []
    private(set) var watchStates: [UUID: WatchState] = [:]
    private(set) var series: [String: SeriesMeta] = [:]

    var isScanning = false
    var scanMessage: String = ""
    var isFetchingMetadata = false
    var metadataMessage: String = ""

    @ObservationIgnored private let libraryFile = LocalStore(
        fileName: "library.json", defaultValue: LibraryData()
    )
    @ObservationIgnored private let watchFile = LocalStore(
        fileName: "watchstate.json", defaultValue: WatchStateData()
    )
    @ObservationIgnored private let remoteFavoritesFile = LocalStore(
        fileName: "remote-favorites.json", defaultValue: RemoteFavoritesData()
    )
    @ObservationIgnored private let streamFavoritesFile = LocalStore(
        fileName: "stream-favorites.json", defaultValue: StreamFavoritesData()
    )
    /// Folders we called `startAccessingSecurityScopedResource` on.
    @ObservationIgnored private var accessedURLs: [URL] = []

    /// Favourited titles the user does not own, straight from TMDB.
    private(set) var remoteFavorites: [RemoteTitle] = []
    /// Favourited streaming-site titles (ZyStream), which belong to no library row.
    private(set) var streamFavorites: [StreamHit] = []

    init() {
        folders = libraryFile.value.folders
        items = libraryFile.value.items
        series = libraryFile.value.series
        watchStates = watchFile.value.states
        remoteFavorites = remoteFavoritesFile.value.titles
        streamFavorites = streamFavoritesFile.value.hits
        resolveBookmarks()
    }

    func meta(forSeriesKey key: String?) -> SeriesMeta? {
        guard let key else { return nil }
        return series[key]
    }

    /// The assembled show for a grouping key, so an episode (e.g. a Continue
    /// Watching entry) can open its series page.
    func show(forSeriesKey key: String?) -> Series? {
        guard let key else { return nil }
        return shows.first { $0.id == key }
    }

    deinit {
        accessedURLs.forEach { $0.stopAccessingSecurityScopedResource() }
    }

    // MARK: - Derived collections

    var movies: [MediaItem] {
        items.filter { $0.kind == .movie }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    var episodes: [MediaItem] {
        items.filter { $0.kind == .episode }
    }

    /// One entry per show, with its episodes attached.
    var shows: [Series] {
        let grouped = Dictionary(grouping: episodes) { $0.seriesKey ?? "?" }
        return grouped.compactMap { _, episodes -> Series? in
            guard let first = episodes.first, let name = first.showTitle else { return nil }
            let sorted = episodes.sorted {
                ($0.season ?? 0, $0.episode ?? 0) < ($1.season ?? 0, $1.episode ?? 0)
            }
            return Series(name: name, episodes: sorted, meta: meta(forSeriesKey: first.seriesKey))
        }
        .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    /// Started but unfinished, most recent first — the Continue Watching row.
    var continueWatching: [MediaItem] {
        items.compactMap { item -> (MediaItem, Date)? in
            guard let state = watchStates[item.id], state.isInProgress else { return nil }
            return (item, state.lastPlayedAt)
        }
        .sorted { $0.1 > $1.1 }
        .map(\.0)
    }

    /// TMDB movie ids currently trending, fetched at launch. Empty until then.
    @ObservationIgnored var trendingMovieIDs: [Int] = []
    @ObservationIgnored var trendingShowIDs: [Int] = []

    /// The user's own movies for the Home rail: today's trending ones first (so
    /// the rail changes daily and mirrors what the world is watching), then the
    /// rest of the library by TMDB rating to fill out 14 cards. Deterministic
    /// within a day, so it doesn't reshuffle on every redraw.
    var moviesOfTheDay: [MediaItem] {
        dailyPick(from: movies, trending: trendingMovieIDs) { $0.tmdbID }
    }

    var showsOfTheDay: [Series] {
        dailyPick(from: shows, trending: trendingShowIDs) { $0.meta?.tmdbID }
    }

    /// Trending-first, then rating-ranked, capped at the Home limit.
    private func dailyPick<T>(from all: [T], trending: [Int],
                              id: (T) -> Int?) -> [T] {
        let trendingRank = Dictionary(uniqueKeysWithValues: trending.enumerated().map { ($1, $0) })
        return all.sorted { lhs, rhs in
            let lt = id(lhs).flatMap { trendingRank[$0] }
            let rt = id(rhs).flatMap { trendingRank[$0] }
            switch (lt, rt) {
            case let (l?, r?): return l < r          // both trending: TMDB order
            case (_?, nil):    return true           // trending beats non-trending
            case (nil, _?):    return false
            case (nil, nil):   return ratingRank(lhs) > ratingRank(rhs)
            }
        }
    }

    private func ratingRank<T>(_ value: T) -> Double {
        if let item = value as? MediaItem { return item.rating ?? 0 }
        if let series = value as? Series { return series.meta?.rating ?? 0 }
        return 0
    }

    /// Drops a title off Continue Watching without touching the library entry or
    /// marking it watched — the user is saying "stop suggesting this".
    func removeFromContinueWatching(_ item: MediaItem) {
        guard watchStates[item.id] != nil else { return }
        watchStates.removeValue(forKey: item.id)
        persistWatchStates()
    }

    /// TMDB ids the user already owns, so "In Cinemas" cards can be flagged.
    var ownedMovieTMDBIDs: Set<Int> {
        Set(items.compactMap { $0.kind == .movie ? $0.tmdbID : nil })
    }

    var ownedShowTMDBIDs: Set<Int> {
        Set(series.values.compactMap(\.tmdbID))
    }

    /// The library movie behind a TMDB id, so a cinema or search result can
    /// offer playback when the user turns out to own it.
    func movie(tmdbID: Int) -> MediaItem? {
        items.first { $0.kind == .movie && $0.tmdbID == tmdbID }
    }

    /// The series key behind a TMDB id, for the same reason.
    func seriesKey(tmdbID: Int) -> String? {
        series.first { $0.value.tmdbID == tmdbID }?.key
    }

    /// Favourite movies plus favourite shows, for the sidebar section.
    var favoriteMovies: [MediaItem] {
        movies.filter(\.isFavorite)
    }

    var favoriteShows: [Series] {
        shows.filter { $0.meta?.isFavorite == true }
    }

    var hasFavorites: Bool {
        !favoriteMovies.isEmpty || !favoriteShows.isEmpty
            || !remoteFavoritesNotOwned.isEmpty || !streamFavorites.isEmpty
    }

    // MARK: - Streaming-site favourites (ZyStream)

    func isStreamFavorite(_ hit: StreamHit) -> Bool {
        streamFavorites.contains { $0.id == hit.id }
    }

    func toggleStreamFavorite(_ hit: StreamHit) {
        if let index = streamFavorites.firstIndex(where: { $0.id == hit.id }) {
            streamFavorites.remove(at: index)
        } else {
            streamFavorites.append(hit)
        }
        streamFavoritesFile.replace(with: StreamFavoritesData(hits: streamFavorites))
    }

    func toggleFavorite(_ item: MediaItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].isFavorite.toggle()
        persistLibrary()
    }

    func toggleFavorite(seriesKey: String) {
        var meta = series[seriesKey] ?? SeriesMeta()
        meta.isFavorite.toggle()
        series[seriesKey] = meta
        persistLibrary()
    }

    func isFavorite(seriesKey: String) -> Bool {
        series[seriesKey]?.isFavorite ?? false
    }

    // MARK: - Favourites for titles that are not in the library

    func isFavorite(remote: RemoteTitle) -> Bool {
        remoteFavorites.contains { $0.id == remote.id }
    }

    /// Favouriting a TMDB-only title keeps a copy of it: there is no file and no
    /// library row to hang the flag off, and the Favourites screen still has to
    /// draw a poster after a relaunch.
    func toggleFavorite(remote: RemoteTitle) {
        if let index = remoteFavorites.firstIndex(where: { $0.id == remote.id }) {
            remoteFavorites.remove(at: index)
        } else {
            remoteFavorites.append(remote)
        }
        remoteFavoritesFile.replace(with: RemoteFavoritesData(titles: remoteFavorites))
    }

    /// Titles that were favourited before the user got them, and now match
    /// something in the library — they are shown from the library instead.
    var remoteFavoritesNotOwned: [RemoteTitle] {
        let movies = ownedMovieTMDBIDs
        let shows = ownedShowTMDBIDs
        return remoteFavorites.filter { title in
            switch title.kind {
            case .movie: return !movies.contains(title.tmdbID)
            case .tv:    return !shows.contains(title.tmdbID)
            }
        }
    }

    // MARK: - Manual match correction

    /// Replaces a movie's metadata with a match the user picked by hand.
    @MainActor
    func applyMovieMatch(to item: MediaItem, tmdbID: Int, settings: AppSettings) async {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        let service = MetadataService(
            client: TMDBClient(token: settings.tmdbToken, language: settings.metadataLanguage)
        )
        guard let detail = try? await service.client.movieDetail(id: tmdbID) else { return }

        let poster = await ArtworkCache.fetch(
            path: detail.posterPath, size: "w500", key: "movie_\(detail.id)_poster"
        )
        let backdrop = await ArtworkCache.fetch(
            path: detail.backdropPath, size: "w1280", key: "movie_\(detail.id)_backdrop"
        )

        items[index].tmdbID = detail.id
        items[index].imdbID = detail.imdbId
        items[index].title = detail.title
        items[index].year = detail.year
        items[index].overview = detail.overview
        items[index].runtimeMinutes = detail.runtime
        items[index].rating = detail.voteAverage
        items[index].genres = detail.genres?.map(\.name) ?? []
        items[index].posterFileName = poster
        items[index].backdropFileName = backdrop
        persistLibrary()
    }

    /// Re-matches a whole series, then refreshes every episode under it.
    @MainActor
    func applySeriesMatch(seriesKey: String, tmdbID: Int, settings: AppSettings) async {
        let service = MetadataService(
            client: TMDBClient(token: settings.tmdbToken, language: settings.metadataLanguage)
        )
        guard let detail = try? await service.client.tvDetail(id: tmdbID) else { return }

        let poster = await ArtworkCache.fetch(
            path: detail.posterPath, size: "w500", key: "tv_\(detail.id)_poster"
        )
        let backdrop = await ArtworkCache.fetch(
            path: detail.backdropPath, size: "w1280", key: "tv_\(detail.id)_backdrop"
        )

        var meta = series[seriesKey] ?? SeriesMeta()
        meta.tmdbID = detail.id
        meta.imdbID = try? await service.client.externalIDs(tvID: detail.id).imdbId
        meta.name = detail.name
        meta.overview = detail.overview
        meta.year = detail.year
        meta.posterFileName = poster
        meta.backdropFileName = backdrop
        meta.rating = detail.voteAverage
        meta.genres = detail.genres?.map(\.name) ?? []
        meta.cast = detail.credits?.cast?.prefix(10).map(\.name) ?? []
        meta.matchFailed = false
        meta.isLocked = true
        series[seriesKey] = meta

        // Clear the old episode matches so they re-fetch against the new show.
        for index in items.indices where items[index].seriesKey == seriesKey {
            items[index].tmdbID = nil
        }
        await matchEpisodes(using: service)
        persistLibrary()
    }

    func search(_ query: String) -> [MediaItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        // IMDb kimliği ya da bağlantısı yazıldıysa isimle değil kimlikle eşleştir:
        // kullanıcı zaten sahip olduğu dosyayı da bu yolla bulabilsin.
        if let imdbID = IMDbID.extract(from: trimmed) {
            return items.filter { $0.imdbID?.lowercased() == imdbID }
        }
        return items.filter {
            $0.title.localizedCaseInsensitiveContains(trimmed)
                || ($0.showTitle?.localizedCaseInsensitiveContains(trimmed) ?? false)
        }
    }

    func state(for item: MediaItem) -> WatchState? { watchStates[item.id] }

    // MARK: - Folders

    func addFolder(_ url: URL) {
        guard !folders.contains(where: { $0.url == url }) else { return }
        let bookmark = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        let folder = LibraryFolder(url: url, bookmark: bookmark)
        folders.append(folder)
        persistLibrary()
        Task { await rescan() }
    }

    /// Turns a folder off without forgetting it; its items leave the library
    /// until it is switched back on.
    func setFolder(_ folder: LibraryFolder, enabled: Bool) {
        guard let index = folders.firstIndex(where: { $0.id == folder.id }) else { return }
        folders[index].isEnabled = enabled
        if !enabled {
            items.removeAll { $0.source == .local && $0.url.path.hasPrefix(folder.url.path) }
            persistLibrary()
        } else {
            persistLibrary()
            Task { await rescan() }
        }
    }

    func removeFolder(_ folder: LibraryFolder) {
        folders.removeAll { $0.id == folder.id }
        // Drop the items that lived under it.
        items.removeAll { $0.url.path.hasPrefix(folder.url.path) }
        persistLibrary()
    }

    /// Re-establishes access to previously added folders on launch.
    private func resolveBookmarks() {
        for index in folders.indices {
            guard let data = folders[index].bookmark else { continue }
            var isStale = false
            guard let url = try? URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) else { continue }

            if url.startAccessingSecurityScopedResource() {
                accessedURLs.append(url)
            }
            if isStale {
                folders[index].bookmark = try? url.bookmarkData(
                    options: .withSecurityScope,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
            }
        }
    }

    // MARK: - Scanning

    @MainActor
    func rescan() async {
        guard !isScanning else { return }
        isScanning = true
        scanMessage = "Taranıyor…"

        let snapshotFolders = folders.filter(\.isEnabled)
        // Cloud items are owned by their provider; a folder scan must not erase them.
        let remoteItems = items.filter { $0.source != .local }
        let localItems = items.filter { $0.source == .local }
        let existing = Dictionary(localItems.map { ($0.url.path, $0) }, uniquingKeysWith: { a, _ in a })

        let scanned: [MediaItem] = await Task.detached(priority: .utility) {
            var collected: [MediaItem] = []
            for folder in snapshotFolders {
                let result = LibraryScanner.scan(folder: folder.url, existing: existing)
                collected.append(contentsOf: result.items)
            }
            return collected
        }.value

        // De-duplicate by path in case two library folders overlap.
        var seen = Set<String>()
        items = remoteItems + scanned.filter { seen.insert($0.url.path).inserted }

        for index in folders.indices {
            folders[index].lastScannedAt = .now
        }

        isScanning = false
        scanMessage = items.isEmpty ? "İçerik bulunamadı" : "\(items.count) öğe"
        persistLibrary()
    }

    // MARK: - Remote sources

    /// Swaps in a provider's items, keeping ids (and therefore watch state and
    /// TMDB matches) for files we have seen before.
    func replaceItems(from source: MediaSourceKind, with incoming: [MediaItem]) {
        let previous = Dictionary(
            items.filter { $0.source == source }.compactMap { item -> (String, MediaItem)? in
                guard let key = item.remoteID else { return nil }
                return (key, item)
            },
            uniquingKeysWith: { a, _ in a }
        )

        let merged = incoming.map { new -> MediaItem in
            guard let key = new.remoteID, var existing = previous[key] else { return new }
            existing.url = new.url
            existing.fileSize = new.fileSize
            existing.modifiedAt = new.modifiedAt
            if existing.tmdbID == nil {
                existing.kind = new.kind
                existing.title = new.title
                existing.year = new.year
                existing.showTitle = new.showTitle
                existing.season = new.season
                existing.episode = new.episode
            }
            return existing
        }

        items.removeAll { $0.source == source }
        items.append(contentsOf: merged)
        persistLibrary()
    }

    func removeItems(from source: MediaSourceKind) {
        items.removeAll { $0.source == source }
        persistLibrary()
    }

    // MARK: - Metadata

    /// Matches everything that has no TMDB match yet: series first (so episodes
    /// inherit the canonical show), then episodes, then movies.
    @MainActor
    func fetchMetadata(settings: AppSettings, force: Bool = false) async {
        guard !isFetchingMetadata, settings.hasTMDBToken else {
            if !settings.hasTMDBToken { metadataMessage = "TMDB jetonu girilmemiş." }
            return
        }
        isFetchingMetadata = true
        defer { isFetchingMetadata = false }

        let service = MetadataService(
            client: TMDBClient(token: settings.tmdbToken, language: settings.metadataLanguage)
        )

        if force {
            // Hand-picked matches survive a full refresh; that is the point of
            // locking them.
            series = series.mapValues { $0.isLocked ? $0 : SeriesMeta() }
            for index in items.indices {
                let locked = series[items[index].seriesKey ?? ""]?.isLocked ?? false
                if !locked { items[index].tmdbID = nil }
            }
        }

        await matchSeries(using: service)
        await matchEpisodes(using: service)
        await matchMovies(using: service)

        metadataMessage = "Bilgiler güncellendi"
        persistLibrary()
    }

    /// Pulls today's trending ids so Home can float the user's own trending
    /// titles to the front. Best-effort: a failure just leaves the rails ranked
    /// by rating.
    @MainActor
    func refreshTrending(settings: AppSettings) async {
        guard settings.hasTMDBToken else { return }
        let client = TMDBClient(token: settings.tmdbToken, language: settings.metadataLanguage)
        if let movies = try? await client.trendingMovies() {
            trendingMovieIDs = movies.map(\.id)
        }
        if let shows = try? await client.trendingShows() {
            trendingShowIDs = shows.map(\.id)
        }
    }

    @MainActor
    private func matchSeries(using service: MetadataService) async {
        let pending = Set(items.compactMap(\.seriesKey)).filter { key in
            let existing = series[key]
            return existing?.tmdbID == nil && existing?.matchFailed != true
        }
        guard !pending.isEmpty else { return }

        // Display names come from the items; the key is lowercased.
        var names: [String: String] = [:]
        for item in items {
            if let key = item.seriesKey, names[key] == nil { names[key] = item.showTitle }
        }

        var done = 0
        for chunk in Array(pending).chunked(into: 4) {
            let matches = await withTaskGroup(of: (String, SeriesMeta?).self) { group in
                for key in chunk {
                    let name = names[key] ?? key
                    group.addTask { (key, await service.matchSeries(name: name)) }
                }
                var collected: [(String, SeriesMeta?)] = []
                for await result in group { collected.append(result) }
                return collected
            }
            for (key, match) in matches {
                series[key] = match ?? SeriesMeta(matchFailed: true)
                done += 1
            }
            metadataMessage = "Diziler eşleştiriliyor… \(done)/\(pending.count)"
        }
    }

    @MainActor
    private func matchEpisodes(using service: MetadataService) async {
        let pending = items.indices.filter { index in
            let item = items[index]
            return item.kind == .episode
                && item.tmdbID == nil
                && item.season != nil && item.episode != nil
                && meta(forSeriesKey: item.seriesKey)?.tmdbID != nil
        }
        guard !pending.isEmpty else { return }

        var done = 0
        for chunk in pending.chunked(into: 4) {
            let matches = await withTaskGroup(of: (Int, MetadataService.EpisodeMatch?).self) { group in
                for index in chunk {
                    let item = items[index]
                    guard let showID = meta(forSeriesKey: item.seriesKey)?.tmdbID,
                          let season = item.season, let episode = item.episode else { continue }
                    group.addTask {
                        (index, await service.matchEpisode(
                            showID: showID, season: season, episode: episode
                        ))
                    }
                }
                var collected: [(Int, MetadataService.EpisodeMatch?)] = []
                for await result in group { collected.append(result) }
                return collected
            }
            for (index, match) in matches {
                guard let match else { continue }
                if let title = match.title, !title.isEmpty { items[index].title = title }
                items[index].overview = match.overview
                items[index].posterFileName = match.stillFileName
                items[index].runtimeMinutes = match.runtimeMinutes
                items[index].tmdbID = meta(forSeriesKey: items[index].seriesKey)?.tmdbID
                done += 1
            }
            metadataMessage = "Bölümler eşleştiriliyor… \(done)/\(pending.count)"
        }
    }

    @MainActor
    private func matchMovies(using service: MetadataService) async {
        let pending = items.indices.filter { items[$0].kind == .movie && items[$0].tmdbID == nil }
        guard !pending.isEmpty else { return }

        var done = 0
        for chunk in pending.chunked(into: 4) {
            let matches = await withTaskGroup(of: (Int, MetadataService.MovieMatch?).self) { group in
                for index in chunk {
                    let item = items[index]
                    group.addTask {
                        (index, await service.matchMovie(title: item.title, year: item.year))
                    }
                }
                var collected: [(Int, MetadataService.MovieMatch?)] = []
                for await result in group { collected.append(result) }
                return collected
            }
            for (index, match) in matches {
                guard let match else { continue }
                items[index].tmdbID = match.tmdbID
                items[index].imdbID = match.imdbID
                items[index].title = match.title
                items[index].year = match.year ?? items[index].year
                items[index].overview = match.overview
                items[index].runtimeMinutes = match.runtimeMinutes
                items[index].rating = match.rating
                items[index].genres = match.genres
                items[index].posterFileName = match.posterFileName
                items[index].backdropFileName = match.backdropFileName
                done += 1
            }
            metadataMessage = "Filmler eşleştiriliyor… \(done)/\(pending.count)"
        }
    }

    // MARK: - Watch state

    func updateProgress(for item: MediaItem, position: Double, duration: Double) {
        guard duration > 0 else { return }
        var state = watchStates[item.id] ?? WatchState()
        state.position = position
        state.duration = duration
        state.lastPlayedAt = .now
        // Near the end counts as watched, so it leaves Continue Watching.
        let remaining = duration - position
        if duration > 600 && remaining <= 600 {
            state.isFinished = true
        } else if position / duration >= 0.95 {
            state.isFinished = true
        }
        watchStates[item.id] = state
        persistWatchStates()
    }

    func markWatched(_ item: MediaItem, watched: Bool = true) {
        var state = watchStates[item.id] ?? WatchState()
        state.isFinished = watched
        state.lastPlayedAt = .now
        if watched {
            state.position = state.duration
            // Watching it satisfies the watchlist.
            state.wantToWatch = false
        } else {
            state.position = 0
        }
        watchStates[item.id] = state
        persistWatchStates()
    }

    func isWatched(_ item: MediaItem) -> Bool { watchStates[item.id]?.isFinished ?? false }

    /// Toggles the "İzleyeceğim" (watchlist) flag on a single item.
    func setWatchlist(_ item: MediaItem, _ wanted: Bool) {
        var state = watchStates[item.id] ?? WatchState()
        state.wantToWatch = wanted
        if wanted { state.isFinished = false }
        watchStates[item.id] = state
        persistWatchStates()
    }

    func isWatchlisted(_ item: MediaItem) -> Bool { watchStates[item.id]?.wantToWatch ?? false }

    // MARK: - Series-level watch state

    func setSeriesWatchlist(seriesKey: String, _ wanted: Bool) {
        var meta = series[seriesKey] ?? SeriesMeta()
        meta.wantToWatch = wanted
        series[seriesKey] = meta
        persistLibrary()
    }

    func isSeriesWatchlisted(seriesKey: String) -> Bool {
        series[seriesKey]?.wantToWatch ?? false
    }

    /// Marks every episode of a show watched (or unwatched) in one go.
    func markSeriesWatched(seriesKey: String, watched: Bool) {
        for episode in episodes where episode.seriesKey == seriesKey {
            markWatched(episode, watched: watched)
        }
        if watched { setSeriesWatchlist(seriesKey: seriesKey, false) }
    }

    /// True when the show has episodes and all of them are finished.
    func isSeriesFullyWatched(seriesKey: String) -> Bool {
        let eps = episodes.filter { $0.seriesKey == seriesKey }
        guard !eps.isEmpty else { return false }
        return eps.allSatisfy { watchStates[$0.id]?.isFinished == true }
    }

    /// Item matching a URL, so the player can report progress back.
    func item(for url: URL) -> MediaItem? {
        items.first { $0.url == url }
    }

    // MARK: - IMDb ids

    /// The IMDb id subtitle addons need, fetched on demand.
    ///
    /// Libraries matched before this field existed have only a TMDB id, and
    /// re-running the whole metadata pass to fill one string would be wasteful.
    /// So the first subtitle search for an item pays for one request, and the
    /// answer is stored.
    ///
    /// Episodes resolve to their *show's* id: the protocol addresses them as
    /// `tt0903747:1:1`.
    @MainActor
    func imdbID(for item: MediaItem, settings: AppSettings) async -> String? {
        if item.kind == .episode {
            guard let key = item.seriesKey else { return nil }
            if let existing = series[key]?.imdbID, !existing.isEmpty { return existing }
            guard let showID = series[key]?.tmdbID, settings.hasTMDBToken else { return nil }

            let client = TMDBClient(token: settings.tmdbToken, language: settings.metadataLanguage)
            guard let fetched = try? await client.externalIDs(tvID: showID).imdbId,
                  !fetched.isEmpty else { return nil }

            var meta = series[key] ?? SeriesMeta()
            meta.imdbID = fetched
            series[key] = meta
            persistLibrary()
            return fetched
        }

        if let existing = item.imdbID, !existing.isEmpty { return existing }
        guard let tmdbID = item.tmdbID, settings.hasTMDBToken else { return nil }

        let client = TMDBClient(token: settings.tmdbToken, language: settings.metadataLanguage)
        guard let fetched = try? await client.movieDetail(id: tmdbID).imdbId,
              !fetched.isEmpty else { return nil }

        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index].imdbID = fetched
            persistLibrary()
        }
        return fetched
    }

    /// Fills in the fields a detail screen shows but an older match never stored
    /// — the TMDB score and the IMDb id — with a single request, the first time
    /// that screen is opened. Everything matched from now on already has them.
    @MainActor
    func fillMissingDetail(for item: MediaItem, settings: AppSettings) async {
        guard settings.hasTMDBToken else { return }
        let client = TMDBClient(token: settings.tmdbToken, language: settings.metadataLanguage)

        if item.kind == .episode {
            guard let key = item.seriesKey, var meta = series[key], let showID = meta.tmdbID,
                  meta.rating == nil || (meta.imdbID ?? "").isEmpty else { return }

            if meta.rating == nil, let detail = try? await client.tvDetail(id: showID) {
                meta.rating = detail.voteAverage
            }
            if (meta.imdbID ?? "").isEmpty,
               let fetched = try? await client.externalIDs(tvID: showID).imdbId {
                meta.imdbID = fetched
            }
            series[key] = meta
        } else {
            guard let tmdbID = item.tmdbID,
                  item.rating == nil || (item.imdbID ?? "").isEmpty,
                  let detail = try? await client.movieDetail(id: tmdbID),
                  let index = items.firstIndex(where: { $0.id == item.id }) else { return }

            if items[index].rating == nil { items[index].rating = detail.voteAverage }
            if (items[index].imdbID ?? "").isEmpty { items[index].imdbID = detail.imdbId }
        }
        persistLibrary()
    }

    // MARK: - Remote Favorites

    func addRemoteFavorite(_ title: RemoteTitle) {
        guard !remoteFavorites.contains(where: { $0.id == title.id }) else { return }
        remoteFavorites.append(title)
        persistRemoteFavorites()
    }

    func removeRemoteFavorite(_ title: RemoteTitle) {
        remoteFavorites.removeAll { $0.id == title.id }
        persistRemoteFavorites()
    }

    func toggleRemoteFavorite(_ title: RemoteTitle) {
        if remoteFavorites.contains(where: { $0.id == title.id }) {
            removeRemoteFavorite(title)
        } else {
            addRemoteFavorite(title)
        }
    }

    private func persistRemoteFavorites() {
        remoteFavoritesFile.replace(with: RemoteFavoritesData(titles: remoteFavorites))
    }

    // MARK: - Persistence

    private func persistLibrary() {
        libraryFile.replace(with: LibraryData(folders: folders, items: items, series: series))
    }

    private func persistWatchStates() {
        watchFile.replace(with: WatchStateData(states: watchStates))
    }
}

extension Array {
    /// Splits into fixed-size batches so network work stays bounded.
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}

/// A show plus its episodes, built on demand from flat episode items.
struct Series: Identifiable, Hashable {
    var name: String
    var episodes: [MediaItem]
    var meta: SeriesMeta?

    var id: String { name.lowercased() }

    /// TMDB's name when we have it — it also fixes filename casing like "Dmz".
    var displayName: String { meta?.name ?? name }

    var seasonCount: Int {
        Set(episodes.compactMap(\.season)).count
    }

    var seasons: [Int: [MediaItem]] {
        Dictionary(grouping: episodes) { $0.season ?? 0 }
    }
}
