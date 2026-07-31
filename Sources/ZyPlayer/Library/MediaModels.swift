import Foundation

enum MediaKind: String, Codable, Hashable {
    case movie
    case episode
}

/// Where a file lives. Local items are rebuilt by every folder scan; remote
/// ones are owned by their source and must survive a rescan.
enum MediaSourceKind: String, Codable, Hashable {
    case local
    case googleDrive
}

/// One playable file in the library.
struct MediaItem: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var url: URL
    var kind: MediaKind
    var source: MediaSourceKind = .local
    /// Provider-side identifier, e.g. a Google Drive file id.
    var remoteID: String?

    /// Cleaned-up display title. For episodes this is the episode title when the
    /// filename carries one, otherwise the show title.
    var title: String
    var year: Int?

    // Episode fields, nil for movies.
    var showTitle: String?
    var season: Int?
    var episode: Int?

    var fileSize: Int64 = 0
    var addedAt: Date = .now
    var modifiedAt: Date = .now

    // Filled in by Phase 3 (TMDB); kept here so the store stays one file.
    var overview: String?
    var tmdbID: Int?
    /// `tt0111161`. Subtitle addons key on IMDb, not TMDB.
    var imdbID: String?
    var posterFileName: String?
    var backdropFileName: String?
    var runtimeMinutes: Int?
    /// TMDB vote average, used to rank the daily Home selection.
    var rating: Double?
    var genres: [String] = []
    var isFavorite: Bool = false

    init(id: UUID = UUID(),
         url: URL,
         kind: MediaKind,
         source: MediaSourceKind = .local,
         remoteID: String? = nil,
         title: String,
         year: Int? = nil,
         showTitle: String? = nil,
         season: Int? = nil,
         episode: Int? = nil,
         fileSize: Int64 = 0,
         addedAt: Date = .now,
         modifiedAt: Date = .now) {
        self.id = id
        self.url = url
        self.kind = kind
        self.source = source
        self.remoteID = remoteID
        self.title = title
        self.year = year
        self.showTitle = showTitle
        self.season = season
        self.episode = episode
        self.fileSize = fileSize
        self.addedAt = addedAt
        self.modifiedAt = modifiedAt
    }

    /// Tolerant decoding: a file written by an older build is missing whatever
    /// fields were added since, and must still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, UUID())
        url = try c.decode(URL.self, forKey: .url)
        kind = c.value(.kind, MediaKind.movie)
        source = c.value(.source, MediaSourceKind.local)
        remoteID = c.optional(.remoteID)
        title = c.value(.title, "")
        year = c.optional(.year)
        showTitle = c.optional(.showTitle)
        season = c.optional(.season)
        episode = c.optional(.episode)
        fileSize = c.value(.fileSize, 0)
        addedAt = c.value(.addedAt, Date.now)
        modifiedAt = c.value(.modifiedAt, Date.now)
        overview = c.optional(.overview)
        tmdbID = c.optional(.tmdbID)
        imdbID = c.optional(.imdbID)
        posterFileName = c.optional(.posterFileName)
        backdropFileName = c.optional(.backdropFileName)
        runtimeMinutes = c.optional(.runtimeMinutes)
        rating = c.optional(.rating)
        genres = c.value(.genres, [])
        isFavorite = c.value(.isFavorite, false)
    }

    /// `Dizi Adı · S01E03` style subtitle for lists and grids.
    var subtitleLine: String {
        switch kind {
        case .movie:
            return year.map(String.init) ?? ""
        case .episode:
            guard let season, let episode else { return showTitle ?? "" }
            return String(format: "S%02dB%02d", season, episode)
        }
    }

    /// Grouping key so episodes of the same show collapse into one poster.
    var seriesKey: String? {
        guard kind == .episode, let showTitle else { return nil }
        return showTitle.lowercased()
    }
}

/// A folder the user added to the library.
struct LibraryFolder: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var url: URL
    /// Security-scoped bookmark so access survives relaunches.
    var bookmark: Data?
    var addedAt: Date = .now
    var lastScannedAt: Date?
    /// Disabled folders stay in the list but are skipped by scans, and their
    /// items are hidden — a way to park a drive that is not always plugged in.
    var isEnabled: Bool = true

    init(id: UUID = UUID(), url: URL, bookmark: Data? = nil,
         addedAt: Date = .now, lastScannedAt: Date? = nil, isEnabled: Bool = true) {
        self.id = id
        self.url = url
        self.bookmark = bookmark
        self.addedAt = addedAt
        self.lastScannedAt = lastScannedAt
        self.isEnabled = isEnabled
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, UUID())
        url = try c.decode(URL.self, forKey: .url)
        bookmark = c.optional(.bookmark)
        addedAt = c.value(.addedAt, Date.now)
        lastScannedAt = c.optional(.lastScannedAt)
        isEnabled = c.value(.isEnabled, true)
    }
}

/// Playback progress for one item.
struct WatchState: Codable, Hashable {
    var position: Double = 0
    var duration: Double = 0
    var isFinished: Bool = false
    var lastPlayedAt: Date = .now
    /// The user's "İzleyeceğim" (watchlist) flag — set by hand, independent of
    /// whether the item has ever been played.
    var wantToWatch: Bool = false

    init(position: Double = 0, duration: Double = 0, isFinished: Bool = false,
         lastPlayedAt: Date = .now, wantToWatch: Bool = false) {
        self.position = position
        self.duration = duration
        self.isFinished = isFinished
        self.lastPlayedAt = lastPlayedAt
        self.wantToWatch = wantToWatch
    }

    /// Tolerant decoding: a watchstate.json written before `wantToWatch` existed
    /// is missing the key and must still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        position = c.value(.position, 0)
        duration = c.value(.duration, 0)
        isFinished = c.value(.isFinished, false)
        lastPlayedAt = c.value(.lastPlayedAt, Date.now)
        wantToWatch = c.value(.wantToWatch, false)
    }

    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(max(position / duration, 0), 1)
    }

    /// Treated as "started but not finished" for the Continue Watching row.
    var isInProgress: Bool {
        let remaining = duration - position
        if isFinished { return false }
        if position <= 30 { return false }
        if duration > 600 {
            return remaining > 600 && progress < 0.95
        }
        return progress < 0.95
    }
}

/// Show-level metadata, matched once per series rather than per episode.
struct SeriesMeta: Codable, Hashable {
    var tmdbID: Int?
    /// The show's IMDb id. Episodes are addressed as `tt0903747:1:1`, so the
    /// series carries it rather than each episode.
    var imdbID: String?
    /// Canonical name from TMDB, which also fixes filename casing.
    var name: String?
    var overview: String?
    var year: Int?
    var posterFileName: String?
    var backdropFileName: String?
    /// TMDB vote average, used to rank the daily Home selection.
    var rating: Double?
    var genres: [String] = []
    var cast: [String] = []
    /// Set when a lookup found nothing, so we don't retry forever.
    var matchFailed: Bool = false
    var isFavorite: Bool = false
    /// True once the user picked the match by hand; automatic passes leave it alone.
    var isLocked: Bool = false
    /// The show is on the user's "İzleyeceğim" (watchlist).
    var wantToWatch: Bool = false

    init(tmdbID: Int? = nil,
         imdbID: String? = nil,
         name: String? = nil,
         overview: String? = nil,
         year: Int? = nil,
         posterFileName: String? = nil,
         backdropFileName: String? = nil,
         rating: Double? = nil,
         genres: [String] = [],
         cast: [String] = [],
         matchFailed: Bool = false,
         isFavorite: Bool = false,
         isLocked: Bool = false,
         wantToWatch: Bool = false) {
        self.tmdbID = tmdbID
        self.imdbID = imdbID
        self.name = name
        self.overview = overview
        self.year = year
        self.posterFileName = posterFileName
        self.backdropFileName = backdropFileName
        self.rating = rating
        self.genres = genres
        self.cast = cast
        self.matchFailed = matchFailed
        self.isFavorite = isFavorite
        self.isLocked = isLocked
        self.wantToWatch = wantToWatch
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tmdbID = c.optional(.tmdbID)
        imdbID = c.optional(.imdbID)
        name = c.optional(.name)
        overview = c.optional(.overview)
        year = c.optional(.year)
        posterFileName = c.optional(.posterFileName)
        backdropFileName = c.optional(.backdropFileName)
        rating = c.optional(.rating)
        genres = c.value(.genres, [])
        cast = c.value(.cast, [])
        matchFailed = c.value(.matchFailed, false)
        isFavorite = c.value(.isFavorite, false)
        isLocked = c.value(.isLocked, false)
        wantToWatch = c.value(.wantToWatch, false)
    }
}

/// On-disk shape of `library.json`.
struct LibraryData: Codable {
    var folders: [LibraryFolder] = []
    var items: [MediaItem] = []
    /// Keyed by `MediaItem.seriesKey` (lowercased show name).
    var series: [String: SeriesMeta] = [:]

    init(folders: [LibraryFolder] = [], items: [MediaItem] = [], series: [String: SeriesMeta] = [:]) {
        self.folders = folders
        self.items = items
        self.series = series
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        folders = c.value(.folders, [])
        items = c.value(.items, [])
        series = c.value(.series, [:])
    }
}

/// On-disk shape of `watchstate.json`, keyed by item id.
struct WatchStateData: Codable {
    var states: [UUID: WatchState] = [:]

    init(states: [UUID: WatchState] = [:]) { self.states = states }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        states = c.value(.states, [:])
    }
}
