import SwiftUI

/// Loads a ZyStream title's detail: a TMDB match (backdrop, overview, rating) and
/// the provider's own details (movie page or episode list).
@MainActor
@Observable
final class StreamDetailLoader {
    var match: RemoteTitle?
    var details: StreamDetails?
    private(set) var isLoading = false
    @ObservationIgnored private var loadedID: String?

    func load(_ hit: StreamHit, provider: StreamProvider?, settings: AppSettings) async {
        guard loadedID != hit.id else { return }
        loadedID = hit.id
        match = nil
        details = nil
        isLoading = true
        defer { isLoading = false }

        if let provider { details = try? await provider.details(hit) }
        if settings.hasTMDBToken {
            match = await tmdbMatch(hit, imdbID: details?.imdbID, settings: settings)
        }
    }

    /// The IMDb id from the page gives an exact match; a title search is the
    /// fallback. HdFilmCehennemi titles are "Türkçe Ad - Original Name", so the
    /// original half is tried first (TMDB indexes originals best), then the whole.
    private func tmdbMatch(_ hit: StreamHit, imdbID: String?, settings: AppSettings) async -> RemoteTitle? {
        let client = TMDBClient(token: settings.tmdbToken, language: settings.metadataLanguage)
        if let imdbID, let found = try? await client.find(imdbID: imdbID) {
            if let movie = found.movieResults.first { return RemoteTitle(movie: movie) }
            if let show = found.tvResults.first { return RemoteTitle(show: show) }
        }
        for query in Self.queries(for: hit.title) {
            guard let results = try? await client.searchMulti(query: query) else { continue }
            if let best = results.compactMap(RemoteTitle.init(multi:)).first { return best }
        }
        return nil
    }

    static func queries(for title: String) -> [String] {
        var queries: [String] = []
        if let range = title.range(of: " - ", options: .backwards) {
            let original = String(title[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            let local = String(title[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            if !original.isEmpty { queries.append(original) }
            if !local.isEmpty { queries.append(local) }
        }
        queries.append(title)
        return queries
    }
}

/// Detail page for a ZyStream title: TMDB-matched artwork and synopsis, a play
/// button for a film, or an episode list for a series.
struct StreamDetailView: View {
    let hit: StreamHit
    @Bindable var store: ZyStreamStore
    let library: LibraryStore
    let settings: AppSettings
    let resume: PlaybackResumeStore
    let onBack: () -> Void
    /// Plays the TMDB trailer for the matched title.
    var onTrailer: (RemoteTitle) -> Void = { _ in }
    var isTrailerLoading: Bool = false

    @State private var loader = StreamDetailLoader()
    @State private var poster: NSImage?
    @State private var season: Int = 1
    /// TMDB episode stills: key is "s{season}e{episode}" -> still URL.
    /// Fetched per-season from TMDB's seasonDetail endpoint when a match is available.
    @State private var episodeStills: [String: URL] = [:]
    /// Tracks which seasons we've already fetched stills for (avoids repeat requests).
    @State private var fetchedStillSeasons: Set<Int> = []

    private var episodes: [StreamEpisode] { loader.details?.episodes ?? [] }
    private var isSeries: Bool { !episodes.isEmpty }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                DetailHeader(
                    backdropFileName: nil,
                    posterFileName: nil,
                    backdropURL: loader.match?.backdropURL,
                    posterURL: loader.match?.posterURL,
                    posterImage: loader.match == nil ? poster : nil,
                    title: displayTitle,
                    tagline: metaLine,
                    overview: loader.match?.overview,
                    genres: [],
                    rating: loader.match?.rating,
                    showsLibraryControls: false,
                    isFavorite: library.isStreamFavorite(hit),
                    resumeLabel: resumeLabel,
                    onBack: onBack,
                    onPlay: isSeries ? nil : { playMovie() },
                    onToggleFavorite: { library.toggleStreamFavorite(hit) },
                    onTrailer: loader.match.map { m in { onTrailer(m) } },
                    isTrailerLoading: isTrailerLoading
                )

                if isSeries {
                    episodeSection
                } else if loader.isLoading {
                    ProgressView().controlSize(.small)
                        .padding(.horizontal, 24).padding(.top, 20)
                }

                if let message = store.message {
                    Text(message)
                        .font(.callout).foregroundStyle(.orange)
                        .padding(.horizontal, 24).padding(.top, 16)
                }
            }
            .padding(.bottom, 30)
        }
        .task(id: hit.id) {
            guard let url = hit.posterURL,
                  let base = store.baseURL(forProviderID: hit.providerID) else { return }
            poster = await StreamImageLoader.shared.image(for: url, baseURL: base)
        }
        .task(id: hit.id) {
            await loader.load(hit, provider: store.lookup(hit.providerID), settings: settings)
        }
        // Fetch TMDB episode stills whenever the matched tmdbID or displayed season changes.
        .task(id: "\(loader.match?.tmdbID ?? 0)-\(season)") {
            await fetchEpisodeStills(forSeason: season)
        }
        // Also fetch when match first arrives (id doesn't change but match just appeared).
        .onChange(of: loader.match?.tmdbID) {
            Task { await fetchEpisodeStills(forSeason: season) }
        }
    }

    // MARK: - TMDB Episode Stills

    /// Fetches `stillPath` for every episode in `season` using TMDB `seasonDetail`.
    /// Results are cached in `episodeStills` keyed by "s{season}e{episode}".
    /// Silently skips when: no TMDB match, no token, or the season was already fetched.
    private func fetchEpisodeStills(forSeason s: Int) async {
        guard settings.hasTMDBToken,
              let tmdbID = loader.match?.tmdbID,
              !fetchedStillSeasons.contains(s) else { return }
        fetchedStillSeasons.insert(s)
        let client = TMDBClient(token: settings.tmdbToken, language: settings.metadataLanguage)
        guard let detail = try? await client.seasonDetail(showID: tmdbID, season: s),
              let eps = detail.episodes else { return }
        for ep in eps {
            guard let num = ep.episodeNumber, let path = ep.stillPath else { continue }
            let key = "s\(s)e\(num)"
            episodeStills[key] = TMDBClient.imageURL(path: path, size: "w300")
        }
    }

    // MARK: - Movie

    private func playMovie() {
        Task {
            await store.playPage(hit.pageURL, providerID: hit.providerID,
                                 title: displayTitle, resolvingID: hit.id, 
                                 posterURL: loader.match?.posterURL ?? hit.posterURL)
        }
    }

    private var resumeLabel: String {
        guard !isSeries, let point = resume.point(forKey: hit.pageURL),
              point.progress > 0.01, !point.isFinished else { return "Oynat" }
        return "\(point.position.asTimecode) konumundan devam et"
    }

    // MARK: - Series

    private var episodeSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            let seasons = loader.details?.seasons ?? [1]
            if seasons.count > 1 {
                SeasonTabs(seasons: seasons, selected: effectiveSeason,
                           episodeCount: { loader.details?.episodes(inSeason: $0).count ?? 0 },
                           onSelect: { season = $0 })
                .padding(.top, 18)
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(loader.details?.episodes(inSeason: effectiveSeason) ?? []) { episode in
                    episodeRow(episode)
                    Divider().opacity(0.4).padding(.leading, 24)
                }
            }
            .padding(.top, 12)
        }
    }

    private func episodeRow(_ episode: StreamEpisode) -> some View {
        let point = resume.point(forKey: episode.pageURL)
        let progress = point?.progress ?? 0
        let isFinished = point?.isFinished ?? false

        return Button {
            Task {
                await store.playPage(
                    episode.pageURL, providerID: hit.providerID,
                    title: "\(displayTitle) · S\(episode.season)B\(episode.episode)",
                    resolvingID: episode.id, posterURL: loader.match?.posterURL ?? hit.posterURL,
                    // Player'daki bölüm seçici bu listeden besleniyor.
                    series: loader.details
                )
            }
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    // Thumbnail: TMDB still önce, yoksa site'den gelen URL, yoksa placeholder
                    let stillKey = "s\(episode.season)e\(episode.episode)"
                    let thumbURL = episodeStills[stillKey] ?? episode.thumbnailURL
                    Group {
                        if let thumbURL {
                            CachedAsyncImage(url: thumbURL) { phase in
                                switch phase {
                                case .success(let img):
                                    img.resizable()
                                        .aspectRatio(16/9, contentMode: .fill)
                                        .frame(width: 100, height: 56)
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                default:
                                    stillPlaceholder
                                }
                            }
                        } else {
                            stillPlaceholder
                        }
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text("\(episode.episode).")
                                .foregroundStyle(.secondary)
                                .frame(width: 28, alignment: .trailing)
                            Text(episode.title ?? "Bölüm \(episode.episode)").lineLimit(1)
                            Spacer(minLength: 0)
                            if store.resolvingID == episode.id {
                                ProgressView().controlSize(.small)
                            } else if isFinished {
                                Label("İzlendi", systemImage: "checkmark.circle.fill")
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.green)
                            } else if progress > 0.01 {
                                Text(point?.position.asTimecode ?? "")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Image(systemName: "play.circle.fill").foregroundStyle(.blue)
                            } else {
                                Image(systemName: "play.circle").foregroundStyle(.secondary)
                            }
                        }

                        // Progress bar
                        if progress > 0.01 && !isFinished {
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Color.white.opacity(0.12))
                                    Capsule()
                                        .fill(Color.blue)
                                        .frame(width: geo.size.width * progress)
                                }
                            }
                            .frame(height: 3)
                            .padding(.leading, 34)
                        }
                    }
                }
                .padding(.horizontal, 24).padding(.vertical, 10)
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
    }

    /// Shown when no thumbnail is available (TMDB still or site image).
    private var stillPlaceholder: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(Color.white.opacity(0.07))
            .frame(width: 100, height: 56)
            .overlay(
                Image(systemName: "play.tv")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.3))
            )
    }

    private var effectiveSeason: Int {
        let seasons = loader.details?.seasons ?? [1]
        return seasons.contains(season) ? season : (seasons.first ?? 1)
    }

    // MARK: - Text

    private var displayTitle: String { loader.match?.title ?? hit.title }

    private var metaLine: String {
        var parts: [String] = []
        if let year = loader.match?.year ?? hit.year { parts.append(String(year)) }
        parts.append(isSeries ? "Dizi" : "Film")
        parts.append(hit.providerName)
        return parts.joined(separator: " · ")
    }
}
