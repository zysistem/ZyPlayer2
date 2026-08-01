import SwiftUI

/// Pre-playback screen: backdrop, poster, synopsis and the play button.
struct MovieDetailView: View {
    let item: MediaItem
    let state: WatchState?
    let library: LibraryStore
    let settings: AppSettings
    let onPlay: (MediaItem) -> Void
    let onBack: () -> Void
    let onEditMatch: () -> Void
    let onTrailer: () -> Void
    let onSelectPerson: (PersonRef) -> Void
    var isTrailerLoading: Bool = false

    @State private var credits = CreditsLoader()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
            DetailHeader(
                backdropFileName: item.backdropFileName,
                posterFileName: item.posterFileName,
                title: item.title,
                tagline: metaLine,
                overview: item.overview,
                genres: item.genres,
                rating: item.rating,
                imdbID: item.imdbID,
                isFavorite: item.isFavorite,
                isWatched: state?.isFinished ?? false,
                isWatchlisted: state?.wantToWatch ?? false,
                onSetWatched: { library.markWatched(item, watched: $0) },
                onSetWatchlist: { library.setWatchlist(item, $0) },
                resumeLabel: resumeLabel,
                onBack: onBack,
                onPlay: { onPlay(item) },
                onToggleFavorite: { library.toggleFavorite(item) },
                onEditMatch: onEditMatch,
                onTrailer: item.tmdbID != nil ? onTrailer : nil,
                isTrailerLoading: isTrailerLoading
            )

            PeopleStrip(people: credits.people, onSelect: onSelectPerson)
                .padding(.top, 24)
                .padding(.bottom, 26)
            }
        }
        .task(id: item.id) {
            await library.fillMissingDetail(for: item, settings: settings)
            if let tmdbID = item.tmdbID {
                await credits.load(kind: .movie, tmdbID: tmdbID, settings: settings)
            }
        }
    }

    /// "1:24:10 konumundan devam et" is clearer than a bare "Devam Et".
    private var resumeLabel: String {
        guard let state, state.isInProgress else { return "Oynat" }
        return "\(state.position.asTimecode) konumundan devam et"
    }

    private var metaLine: String {
        var parts: [String] = []
        if let year = item.year { parts.append(String(year)) }
        if let runtime = item.runtimeMinutes, runtime > 0 {
            parts.append("\(runtime) dk")
        }
        return parts.joined(separator: " · ")
    }
}

/// Show detail: backdrop plus a season-grouped episode list.
struct SeriesDetailView: View {
    let series: Series
    let library: LibraryStore
    let settings: AppSettings
    let streamer: TorrentStreamer
    let onPlay: (MediaItem) -> Void
    let onBack: () -> Void
    let onEditMatch: () -> Void
    let onTrailer: () -> Void
    let onSelectPerson: (PersonRef) -> Void
    /// Torrent hand-offs for episodes the library does not have.
    let onStreamTorrent: (TorrentOption, String, String?) -> Void
    let onDownloadTorrent: (TorrentOption, String) -> Void
    var isTrailerLoading: Bool = false

    /// nil until the user picks one; the default follows whatever plays next.
    @State private var selectedSeason: Int?
    @State private var credits = CreditsLoader()
    /// Pulls the full episode list from TMDB so episodes the user does not own
    /// still show up — with a torrent list instead of a play button.
    @State private var loader = RemoteDetailLoader()
    /// Which missing episode has its torrent list open. One at a time.
    @State private var expandedEpisode: Int?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                DetailHeader(
                    backdropFileName: series.meta?.backdropFileName,
                    posterFileName: series.meta?.posterFileName,
                    title: series.displayName,
                    tagline: metaLine,
                    overview: series.meta?.overview,
                    genres: series.meta?.genres ?? [],
                    rating: series.meta?.rating,
                    imdbID: series.meta?.imdbID,
                    isFavorite: series.meta?.isFavorite ?? false,
                    isWatched: library.isSeriesFullyWatched(seriesKey: series.id),
                    isWatchlisted: series.meta?.wantToWatch ?? false,
                    watchedLabel: "Tümünü izledim",
                    onSetWatched: { library.markSeriesWatched(seriesKey: series.id, watched: $0) },
                    onSetWatchlist: { library.setSeriesWatchlist(seriesKey: series.id, $0) },
                    resumeLabel: resumeLabel,
                    onBack: onBack,
                    onPlay: { if let next = nextEpisode { onPlay(next) } },
                    onToggleFavorite: { library.toggleFavorite(seriesKey: series.id) },
                    onEditMatch: onEditMatch,
                    onTrailer: series.meta?.tmdbID != nil ? onTrailer : nil,
                    isTrailerLoading: isTrailerLoading
                )

                PeopleStrip(people: credits.people, onSelect: onSelectPerson)
                    .padding(.top, 24)

                if seasonNumbers.count > 1 {
                    SeasonTabs(
                        seasons: seasonNumbers,
                        selected: currentSeason,
                        episodeCount: { episodeCount(inSeason: $0) },
                        onSelect: {
                            selectedSeason = $0
                            expandedEpisode = nil
                        }
                    )
                    .padding(.top, 18)
                } else {
                    Text("Sezon \(currentSeason)")
                        .font(.headline)
                        .padding(.horizontal, 24)
                        .padding(.top, 18)
                }

                if loader.isLoadingSeason(currentSeason) {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.horizontal, 24)
                        .padding(.top, 14)
                }

                VStack(alignment: .leading, spacing: 0) {
                    ForEach(episodeNumbers(inSeason: currentSeason), id: \.self) { number in
                        if let owned = ownedEpisode(season: currentSeason, episode: number) {
                            EpisodeRow(
                                item: owned,
                                state: library.state(for: owned),
                                onPlay: onPlay,
                                library: library
                            )
                        } else if let remote = remoteEpisode(season: currentSeason, episode: number) {
                            missingEpisodeRow(remote, season: currentSeason)
                        }
                    }
                }
                .padding(.top, 10)
                .padding(.bottom, 24)
            }
        }
        .task(id: series.id) {
            if let episode = series.episodes.first {
                await library.fillMissingDetail(for: episode, settings: settings)
            }
            if let tmdbID = series.meta?.tmdbID {
                await credits.load(kind: .tv, tmdbID: tmdbID, settings: settings)
            }
            if let remoteTitle {
                await loader.load(remoteTitle, settings: settings)
            }
        }
        .task(id: "\(series.id)-\(currentSeason)") {
            if let remoteTitle {
                await loader.loadSeason(currentSeason, of: remoteTitle, settings: settings)
            }
        }
    }

    // MARK: - Missing-episode rows

    /// A TMDB title built from the show's own metadata, so the shared loader can
    /// fetch the full episode list. nil when the show was never matched.
    private var remoteTitle: RemoteTitle? {
        guard let tmdbID = series.meta?.tmdbID else { return nil }
        return RemoteTitle(
            kind: .tv,
            tmdbID: tmdbID,
            title: series.displayName,
            overview: series.meta?.overview,
            year: series.meta?.year,
            rating: series.meta?.rating
        )
    }

    private var seriesIMDbID: String? {
        if let id = series.meta?.imdbID, !id.isEmpty { return id }
        return loader.imdbID
    }

    private func ownedEpisode(season: Int, episode: Int) -> MediaItem? {
        series.seasons[season]?.first { $0.episode == episode }
    }

    private func remoteEpisode(season: Int, episode: Int) -> EpisodeDetail? {
        loader.episodes[season]?.first { $0.episodeNumber == episode }
    }

    /// Owned episode numbers merged with TMDB's, so a gap in the library still
    /// lists the episodes the user is missing.
    private func episodeNumbers(inSeason season: Int) -> [Int] {
        var numbers = Set((series.seasons[season] ?? []).compactMap(\.episode))
        for episode in loader.episodes[season] ?? [] {
            if let n = episode.episodeNumber, n > 0 { numbers.insert(n) }
        }
        return numbers.sorted()
    }

    private func episodeCount(inSeason season: Int) -> Int {
        let remote = loader.seasons.first { $0.seasonNumber == season }?.episodeCount ?? 0
        return max(series.seasons[season]?.count ?? 0, remote)
    }

    @ViewBuilder
    private func missingEpisodeRow(_ episode: EpisodeDetail, season: Int) -> some View {
        let number = episode.episodeNumber ?? 0
        let isExpanded = expandedEpisode == number

        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) {
                    expandedEpisode = isExpanded ? nil : number
                }
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    ZStack {
                        if let path = episode.stillPath {
                            CachedAsyncImage(url: TMDBClient.imageURL(path: path, size: "w300")) { phase in
                                if case .success(let image) = phase {
                                    image.resizable().aspectRatio(contentMode: .fill)
                                } else {
                                    missingStill
                                }
                            }
                        } else {
                            missingStill
                        }
                    }
                    .frame(width: 150, height: 84)
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text("\(number).")
                                .foregroundStyle(.secondary)
                            Text(episode.name ?? "Bölüm \(number)")
                                .fontWeight(.medium)
                            Text("· bende yok")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        if let overview = episode.overview, !overview.isEmpty {
                            Text(overview)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }
                    }
                    Spacer(minLength: 0)
                    Image(systemName: isExpanded ? "chevron.down" : "arrow.down.left.arrow.up.right.circle")
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                if let imdbID = seriesIMDbID, !imdbID.isEmpty {
                    TorrentPickerView(
                        request: .episode(imdbID: imdbID, season: season, episode: number),
                        showsHeader: false,
                        settings: settings,
                        streamer: streamer,
                        onPlay: { onStreamTorrent($0, "\(series.displayName) · S\(season)B\(number)", series.meta?.posterFileName) },
                        onDownload: { onDownloadTorrent($0, "\(series.displayName) · S\(season)B\(number)") }
                    )
                    .padding(.leading, 186)
                    .padding(.trailing, 24)
                    .padding(.bottom, 10)
                } else {
                    Text("Bu dizinin IMDb kimliği bulunamadı, torrent aranamıyor.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 186)
                        .padding(.bottom, 10)
                }
            }
        }
    }

    private var missingStill: some View {
        ZStack {
            Rectangle().fill(Color(white: 0.16))
            Image(systemName: "arrow.down.circle")
                .foregroundStyle(.white.opacity(0.3))
        }
    }

    /// Owned seasons merged with TMDB's, so a season the user has no files for
    /// still gets a tab.
    private var seasonNumbers: [Int] {
        var numbers = Set(series.seasons.keys)
        for season in loader.seasons {
            if let n = season.seasonNumber, n > 0 { numbers.insert(n) }
        }
        return numbers.sorted()
    }

    private var currentSeason: Int {
        if let selectedSeason, seasonNumbers.contains(selectedSeason) { return selectedSeason }
        return nextEpisode?.season ?? seasonNumbers.first ?? 1
    }

    /// An episode already in progress wins; otherwise the first unwatched one.
    private var nextEpisode: MediaItem? {
        if let inProgress = series.episodes.first(where: {
            library.state(for: $0)?.isInProgress == true
        }) {
            return inProgress
        }
        return series.episodes.first { library.state(for: $0)?.isFinished != true }
            ?? series.episodes.first
    }

    private var resumeLabel: String {
        guard let next = nextEpisode else { return "Oynat" }
        let state = library.state(for: next)
        if let state, state.isInProgress {
            return "S\(next.season ?? 0)B\(next.episode ?? 0) · \(state.position.asTimecode) devam"
        }
        return "S\(next.season ?? 0)B\(next.episode ?? 0) oynat"
    }

    private var metaLine: String {
        var parts: [String] = []
        if let year = series.meta?.year { parts.append(String(year)) }
        parts.append("\(series.seasonCount) sezon")
        parts.append("\(series.episodes.count) bölüm")
        return parts.joined(separator: " · ")
    }
}

/// Seasons as a row of pills above the episode list, so a long-running show does
/// not turn the detail screen into an endless scroll.
struct SeasonTabs: View {
    let seasons: [Int]
    let selected: Int
    let episodeCount: (Int) -> Int
    let onSelect: (Int) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(seasons, id: \.self) { season in
                    let isSelected = season == selected
                    Button {
                        onSelect(season)
                    } label: {
                        HStack(spacing: 6) {
                            Text("Sezon \(season)")
                                .font(.system(size: 12, weight: .semibold))
                            Text("\(episodeCount(season))")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(isSelected ? .white.opacity(0.75) : .secondary)
                        }
                        .foregroundStyle(isSelected ? .white : .primary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(
                            isSelected ? AnyShapeStyle(Color.accentColor)
                                       : AnyShapeStyle(.white.opacity(0.08)),
                            in: Capsule()
                        )
                        .overlay(
                            Capsule().strokeBorder(.white.opacity(isSelected ? 0 : 0.12), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 2)
        }
    }
}

/// Score chip plus a link out to IMDb. TMDB is the source for both: the score is
/// its vote average, the link its `imdb_id`.
struct RatingRow: View {
    let rating: Double?
    let imdbID: String?

    var body: some View {
        HStack(spacing: 8) {
            if let rating, rating > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "star.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.yellow)
                    Text(String(format: "%.1f", rating))
                        .font(.system(size: 12, weight: .semibold))
                    Text("/10")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.white.opacity(0.1), in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1))
            }

            if let imdbID, !imdbID.isEmpty,
               let url = URL(string: "https://www.imdb.com/title/\(imdbID)/") {
                Link(destination: url) {
                    Text("IMDb")
                        .font(.system(size: 11, weight: .heavy))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(
                            Color(red: 0.96, green: 0.78, blue: 0.11),
                            in: RoundedRectangle(cornerRadius: 4, style: .continuous)
                        )
                }
                .help("IMDb sayfasını aç")
            }
        }
    }

    var isEmpty: Bool {
        (rating ?? 0) <= 0 && (imdbID ?? "").isEmpty
    }
}

struct EpisodeRow: View {
    let item: MediaItem
    let state: WatchState?
    let onPlay: (MediaItem) -> Void
    /// Optional so simpler callers can omit the right-click watch actions.
    var library: LibraryStore?

    var body: some View {
        Button {
            onPlay(item)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    if let image = ArtworkCache.image(named: item.posterFileName) {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Rectangle().fill(Color(white: 0.16))
                        Image(systemName: "play.rectangle")
                            .foregroundStyle(.white.opacity(0.3))
                    }
                }
                .frame(width: 150, height: 84)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(alignment: .bottom) {
                    if let state, state.isInProgress {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Rectangle().fill(.black.opacity(0.5))
                                Rectangle().fill(.white).frame(width: geo.size.width * state.progress)
                            }
                        }
                        .frame(height: 3)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text("\(item.episode ?? 0).")
                            .foregroundStyle(.secondary)
                        Text(item.title)
                            .fontWeight(.medium)
                        if state?.isFinished == true {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.blue)
                                .font(.caption)
                        } else if state?.wantToWatch == true {
                            Image(systemName: "bookmark.fill")
                                .foregroundStyle(.orange)
                                .font(.caption)
                        }
                    }
                    if let overview = item.overview, !overview.isEmpty {
                        Text(overview)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let library {
                let watched = state?.isFinished ?? false
                Button(watched ? "İzlemedim olarak işaretle" : "İzledim") {
                    library.markWatched(item, watched: !watched)
                }
                let listed = state?.wantToWatch ?? false
                Button(listed ? "İzleyeceklerimden çıkar" : "İzleyeceğim") {
                    library.setWatchlist(item, !listed)
                }
            }
        }
    }
}

struct DetailHeader: View {
    let backdropFileName: String?
    let posterFileName: String?
    /// Remote artwork, for TMDB-only detail (In Cinemas) with nothing cached.
    var backdropURL: URL?
    var posterURL: URL?
    /// A pre-decoded poster (ZyStream, whose artwork is Cloudflare-gated and can't
    /// go through AsyncImage). Wins over the URLs.
    var posterImage: NSImage?
    let title: String
    let tagline: String
    let overview: String?
    let genres: [String]
    /// TMDB vote average, shown as a star chip.
    var rating: Double?
    /// `tt0111161`, from TMDB — turns into a link to the IMDb page.
    var imdbID: String?
    /// Library-only chrome: the favourite star and the edit-match pencil. A
    /// TMDB-only title has neither, but it may still have a play button when it
    /// turns out to be in the library.
    var showsLibraryControls: Bool = true
    var isFavorite: Bool = false
    /// Right-click state for the poster. The two handlers stay nil for a title
    /// with no library entry to mark, and then no menu is attached at all.
    var isWatched: Bool = false
    var isWatchlisted: Bool = false
    /// A show marks every episode at once, so it says so.
    var watchedLabel: String = "İzledim"
    var onSetWatched: ((Bool) -> Void)?
    var onSetWatchlist: ((Bool) -> Void)?
    var resumeLabel: String = "Oynat"
    let onBack: () -> Void
    var onPlay: (() -> Void)?
    var onToggleFavorite: (() -> Void)?
    var onEditMatch: (() -> Void)?
    var onTrailer: (() -> Void)?
    var isTrailerLoading: Bool = false
    /// "Akışlarda ara": yapımı açık akış kaynaklarında arar. Yalnızca TMDB
    /// başlıklarında var — akış detayında zaten kaynağın içindesiniz.
    var onSearchStreams: (() -> Void)?
    var isSearchingStreams: Bool = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            backdrop

            VStack(alignment: .leading, spacing: 0) {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.headline)
                        .padding(9)
                        .background(.black.opacity(0.4), in: Circle())
                }
                .buttonStyle(.plain)
                .padding(20)

                Spacer(minLength: 90)

                HStack(alignment: .bottom, spacing: 20) {
                    poster
                        .frame(width: 150)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .shadow(radius: 12)
                        .contextMenu { watchActions }

                    VStack(alignment: .leading, spacing: 8) {
                        Text(title)
                            .font(.system(size: 30, weight: .bold))
                            .shadow(radius: 6)

                        if !tagline.isEmpty {
                            Text(tagline)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }

                        if !genres.isEmpty {
                            Text(genres.prefix(3).joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        let ratings = RatingRow(rating: rating, imdbID: imdbID)
                        if !ratings.isEmpty {
                            ratings.padding(.top, 2)
                        }

                        HStack(spacing: 10) {
                            if let onPlay {
                                Button(action: onPlay) {
                                    Label(resumeLabel, systemImage: "play.fill")
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.large)
                            }

                            if let onTrailer {
                                trailerButton(onTrailer)
                            }

                            // The star is not library-only: a title the user does
                            // not own can be favourited too.
                            if let onToggleFavorite {
                                Button(action: onToggleFavorite) {
                                    Image(systemName: isFavorite ? "star.fill" : "star")
                                        .foregroundStyle(isFavorite ? .yellow : .white)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.large)
                                .help(isFavorite ? "Favorilerden çıkar" : "Favorilere ekle")
                            }

                            if let onSearchStreams {
                                Button(action: onSearchStreams) {
                                    if isSearchingStreams {
                                        ProgressView().controlSize(.small)
                                    } else {
                                        Label("Akışlarda Ara", systemImage: "antenna.radiowaves.left.and.right")
                                    }
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.large)
                                .disabled(isSearchingStreams)
                                .help("Bu yapımı açık akış kaynaklarında ara")
                            }

                            if showsLibraryControls {
                                Button(action: { onEditMatch?() }) {
                                    Image(systemName: "pencil")
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.large)
                                .help("Bilgileri düzenle")
                            }
                        }
                        .padding(.top, 6)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 24)

                if let overview, !overview.isEmpty {
                    Text(overview)
                        .font(.callout)
                        .foregroundStyle(.primary.opacity(0.85))
                        .padding(.horizontal, 24)
                        .padding(.top, 18)
                        .frame(maxWidth: 760, alignment: .leading)
                }
            }
            .padding(.bottom, 20)
        }
    }

    /// The same two entries the poster cards in the library carry, so right-clicking
    /// artwork does the same thing wherever it is drawn.
    @ViewBuilder
    private var watchActions: some View {
        if let onSetWatched {
            Button(isWatched ? "İzlemedim olarak işaretle" : watchedLabel) {
                onSetWatched(!isWatched)
            }
        }
        if let onSetWatchlist {
            Button(isWatchlisted ? "İzleyeceklerimden çıkar" : "İzleyeceğim") {
                onSetWatchlist(!isWatchlisted)
            }
        }
    }

    /// Prominent when it is the only action (a title with nothing to play),
    /// bordered otherwise.
    @ViewBuilder
    private func trailerButton(_ action: @escaping () -> Void) -> some View {
        let label = Group {
            if isTrailerLoading {
                ProgressView().controlSize(.small)
            } else {
                Label("Fragman", systemImage: "film")
            }
        }
        if onPlay != nil {
            Button(action: action) { label }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(isTrailerLoading)
        } else {
            Button(action: action) { label }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isTrailerLoading)
        }
    }

    private var backdropDim: some View {
        LinearGradient(
            colors: [.black.opacity(0.15), .black.opacity(0.92)],
            startPoint: .top, endPoint: .bottom
        )
    }

    @ViewBuilder
    private var backdrop: some View {
        GeometryReader { geo in
            if let image = ArtworkCache.image(named: backdropFileName) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
                    .overlay(backdropDim)
            } else if let backdropURL {
                CachedAsyncImage(url: backdropURL) { phase in
                    if case .success(let image) = phase {
                        image.resizable().aspectRatio(contentMode: .fill)
                            .frame(width: geo.size.width, height: geo.size.height)
                            .clipped()
                            .overlay(backdropDim)
                    } else {
                        emptyBackdrop
                    }
                }
            } else {
                emptyBackdrop
            }
        }
        .ignoresSafeArea()
    }

    private var emptyBackdrop: some View {
        LinearGradient(
            colors: [Color(white: 0.16), Color(white: 0.07)],
            startPoint: .top, endPoint: .bottom
        )
    }

    @ViewBuilder
    private var poster: some View {
        if let posterImage {
            Image(nsImage: posterImage).resizable().aspectRatio(2.0 / 3.0, contentMode: .fit)
        } else if let image = ArtworkCache.image(named: posterFileName) {
            Image(nsImage: image).resizable().aspectRatio(2.0 / 3.0, contentMode: .fit)
        } else if let posterURL {
            CachedAsyncImage(url: posterURL) { phase in
                if case .success(let image) = phase {
                    image.resizable().aspectRatio(2.0 / 3.0, contentMode: .fit)
                } else {
                    emptyPoster
                }
            }
        } else {
            emptyPoster
        }
    }

    private var emptyPoster: some View {
        ZStack {
            Color(white: 0.2)
            Image(systemName: "film").font(.largeTitle).foregroundStyle(.white.opacity(0.3))
        }
        .aspectRatio(2.0 / 3.0, contentMode: .fit)
    }
}
