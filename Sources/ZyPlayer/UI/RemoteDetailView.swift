import SwiftUI

/// Detail screen for a title that came from TMDB rather than the library — an In
/// Cinemas film or a search hit.
///
/// It is the same screen either way, and it grows a play button when the title
/// turns out to be in the library: a film plays straight away, a show hands off
/// to its own detail screen where the episodes live.
struct RemoteDetailView: View {
    let title: RemoteTitle
    let library: LibraryStore
    let settings: AppSettings
    let streamer: TorrentStreamer
    let onBack: () -> Void
    let onPlay: (MediaItem) -> Void
    let onOpenSeries: (String) -> Void
    let onStreamTorrent: (TorrentOption, String, String?) -> Void
    let onDownloadTorrent: (TorrentOption, String) -> Void
    let onSelectPerson: (PersonRef) -> Void
    let onTrailer: () -> Void
    var isTrailerLoading: Bool = false
    /// Akış aramasından seçilen sonucun detayını açar.
    var onOpenStream: (StreamHit) -> Void = { _ in }

    /// Kumandanın dikey imleci. İki kademe var: bir bölüm açık değilken bölüm
    /// listesinde, açıkken o bölümün kalite listesinde gezer — oynatma orada.
    var gamepadIndex: Int = 0
    var gamepadSelectTick: Int = 0
    /// Sezon adımı: sağa basınca artan, sola basınca azalan bir sayaç.
    var gamepadSeasonStep: Int = 0
    /// "Akışlarda ara" IPTV aboneliğinde de arıyor; abonelik yoksa nil ve
    /// o bölüm hiç çıkmıyor.
    var iptv: IPTVStore?
    var onPlayIPTVMovie: ((IPTVMovie) -> Void)?
    var onOpenIPTVSeries: ((IPTVSeries) -> Void)?

    @State private var loader = RemoteDetailLoader()
    @State private var credits = CreditsLoader()
    @State private var streams = StreamLookupLoader()
    @State private var selectedSeason: Int?
    /// Which episode has its torrent list open. One at a time keeps the page
    /// from turning into a wall of lists.
    @State private var expandedEpisode: Int?
    /// IPTV aboneliğinde bulunan eşleşmeler. Arama yerel olduğu için sonuç
    /// anında geliyor, ayrı bir yükleme durumu gerekmiyor.
    @State private var iptvMatches: (movies: [IPTVMovie], series: [IPTVSeries]) = ([], [])
    /// Bir bölüm açıldığı andaki imleç değeri; kalite listesinin sıfır noktası.
    @State private var focusBaseline = 0

    private var ownedMovie: MediaItem? {
        title.kind == .movie ? library.movie(tmdbID: title.tmdbID) : nil
    }

    private var ownedSeriesKey: String? {
        title.kind == .tv ? library.seriesKey(tmdbID: title.tmdbID) : nil
    }

    private var isOwned: Bool { ownedMovie != nil || ownedSeriesKey != nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header

                streamResults

                iptvResults

                PeopleStrip(people: credits.people, onSelect: onSelectPerson)
                    .padding(.top, 24)

                // Only for titles the user does not have: owning it already makes
                // the play button above the right answer.
                if !isOwned {
                    switch title.kind {
                    case .movie:
                        TorrentPickerView(
                            request: .movie(imdbID: loader.imdbID, title: title.title, year: title.year),
                            isReady: loader.loadedID == title.id,
                            settings: settings,
                            streamer: streamer,
                            onPlay: { onStreamTorrent($0, loader.displayTitle ?? title.title, title.posterPath) },
                            onDownload: { onDownloadTorrent($0, loader.displayTitle ?? title.title) },
                            // Filmde ara kademe yok: imleç doğrudan kalitelerde.
                            gamepadIndex: gamepadIndex,
                            gamepadSelectTick: gamepadSelectTick
                        )
                        .padding(.horizontal, 24)
                        .padding(.top, 22)
                        .padding(.bottom, 26)
                    case .tv:
                        seasons
                    }
                }
            }
        }
        .task(id: title.id) {
            // Önceki yapımın akış sonuçları bu ekranda kalmasın.
            streams.reset(forTitleID: title.id)
            await loader.load(title, settings: settings)
            await credits.load(kind: title.kind, tmdbID: title.tmdbID, settings: settings)
        }
    }

    /// The show laid out the way a library show is: season tabs, episodes under
    /// them. Each episode opens its own torrent list, because an episode is what
    /// the index is keyed on.
    @ViewBuilder
    private var seasons: some View {
        let numbers = loader.seasons.compactMap(\.seasonNumber)
        let current = selectedSeason ?? numbers.first ?? 1

        VStack(alignment: .leading, spacing: 0) {
            if numbers.count > 1 {
                SeasonTabs(
                    seasons: numbers,
                    selected: current,
                    episodeCount: { season in
                        loader.seasons.first { $0.seasonNumber == season }?.episodeCount ?? 0
                    },
                    onSelect: {
                        selectedSeason = $0
                        expandedEpisode = nil
                    }
                )
                .padding(.top, 20)
            } else if !numbers.isEmpty {
                Text("Sezon \(current)")
                    .font(.headline)
                    .padding(.horizontal, 24)
                    .padding(.top, 20)
            }

            if loader.isLoadingSeason(current) {
                ProgressView()
                    .controlSize(.small)
                    .padding(.horizontal, 24)
                    .padding(.top, 16)
            }

            ForEach(Array((loader.episodes[current] ?? []).enumerated()), id: \.element.id) { index, episode in
                episodeRow(episode, season: current,
                           isGamepadFocused: GamepadManager.shared.isConnected
                                && expandedEpisode == nil
                                && index == focusedEpisodeIndex(in: current))
            }
        }
        .padding(.bottom, 26)
        .task(id: "\(title.id)-\(current)") {
            await loader.loadSeason(current, of: title, settings: settings)
        }
        .onChange(of: gamepadSeasonStep) { old, new in
            // Sezon sekmeleri yatayda gezilir; adım farkı kadar ilerlenir.
            guard numbers.count > 1,
                  let position = numbers.firstIndex(of: current) else { return }
            let next = max(0, min(position + (new - old), numbers.count - 1))
            selectedSeason = numbers[next]
            expandedEpisode = nil
        }
        .onChange(of: gamepadSelectTick) { _, _ in
            // Bir bölüm zaten açıksa seçim ona ait kalite listesine aittir;
            // TorrentPickerView kendi satırını oynatır, burada yapılacak iş yok.
            guard expandedEpisode == nil else { return }
            let episodes = loader.episodes[current] ?? []
            guard !episodes.isEmpty else { return }
            let index = focusedEpisodeIndex(in: current)
            focusBaseline = gamepadIndex
            withAnimation(.easeOut(duration: 0.15)) {
                expandedEpisode = episodes[index].episodeNumber ?? 0
            }
        }
    }

    /// Kumandanın üzerinde durduğu bölüm, listeye kırpılmış.
    private func focusedEpisodeIndex(in season: Int) -> Int {
        let count = (loader.episodes[season] ?? []).count
        guard count > 0 else { return 0 }
        return max(0, min(gamepadIndex, count - 1))
    }

    /// Bölüm açıldıktan sonraki imleç, kalite listesinin başından sayılır.
    ///
    /// Dışarıdan tek bir sayaç geliyor; bölüm seçildiği andaki değeri sıfır
    /// noktası kabul edilir, böylece aşağı basmak kaliteler arasında gezer.
    private var qualityFocusIndex: Int {
        max(0, gamepadIndex - focusBaseline)
    }

    @ViewBuilder
    private func episodeRow(_ episode: EpisodeDetail, season: Int,
                            isGamepadFocused: Bool = false) -> some View {
        let number = episode.episodeNumber ?? 0
        let isExpanded = expandedEpisode == number

        VStack(alignment: .leading, spacing: 0) {
            DetailEpisodeRow(
                stillURL: episode.stillPath.map { TMDBClient.imageURL(path: $0, size: "w500") },
                number: number,
                title: episode.name ?? "Bölüm \(number)",
                duration: episode.airDate,
                plot: episode.overview,
                isHighlighted: isGamepadFocused
            ) {
                withAnimation(.easeOut(duration: 0.15)) {
                    expandedEpisode = isExpanded ? nil : number
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 4)
            if isExpanded {
                if let imdbID = loader.imdbID, !imdbID.isEmpty {
                    TorrentPickerView(
                        request: .episode(imdbID: imdbID, season: season, episode: number),
                        showsHeader: false,
                        settings: settings,
                        streamer: streamer,
                        onPlay: { option in
                            onStreamTorrent(option, "\(loader.displayTitle ?? title.title) · S\(season)B\(number)", title.posterPath)
                        },
                        onDownload: { option in
                            onDownloadTorrent(option, "\(loader.displayTitle ?? title.title) · S\(season)B\(number)")
                        },
                        gamepadIndex: qualityFocusIndex,
                        gamepadSelectTick: gamepadSelectTick
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

    @ViewBuilder
    private func still(_ episode: EpisodeDetail) -> some View {
        if let path = episode.stillPath {
            CachedAsyncImage(url: TMDBClient.imageURL(path: path, size: "w300")) { phase in
                if case .success(let image) = phase {
                    image.resizable().aspectRatio(contentMode: .fill)
                } else {
                    emptyStill
                }
            }
        } else {
            emptyStill
        }
    }

    private var emptyStill: some View {
        ZStack {
            Rectangle().fill(Color(white: 0.16))
            Image(systemName: "play.rectangle").foregroundStyle(.white.opacity(0.3))
        }
    }

    private var header: some View {
        Group {
            DetailHeader(
                backdropFileName: nil,
                posterFileName: nil,
                backdropURL: title.backdropURL,
                posterURL: title.posterURL,
                title: loader.displayTitle ?? title.title,
                tagline: metaLine,
                overview: title.overview,
                genres: loader.genres,
                rating: loader.rating ?? title.rating,
                imdbID: loader.imdbID,
                showsLibraryControls: false,
                isFavorite: library.isFavorite(remote: title),
                resumeLabel: playLabel,
                onBack: onBack,
                onPlay: playAction,
                onToggleFavorite: { library.toggleFavorite(remote: title) },
                onTrailer: onTrailer,
                isTrailerLoading: isTrailerLoading,
                onSearchStreams: settings.hasEnabledStreamSources ? searchStreams : nil,
                isSearchingStreams: streams.state == .searching
            )
            .overlay(alignment: .topTrailing) {
                if isOwned {
                    PosterBadge.inLibrary.label.padding(20)
                }
            }
        }
    }

    /// IPTV aboneliğinde bulunan eşleşmeler, akış sonuçlarıyla aynı satır
    /// biçiminde — rozet hangi kaynaktan geldiğini söylüyor.
    @ViewBuilder
    private var iptvResults: some View {
        if !iptvMatches.movies.isEmpty || !iptvMatches.series.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("IP Tv’de Bulundu")
                    .font(.system(size: 15, weight: .semibold))

                ForEach(iptvMatches.movies) { movie in
                    iptvRow(
                        name: movie.name, kind: "Film",
                        favorite: IPTVFavorite(
                            kind: .movie, streamID: movie.id, name: movie.name,
                            iconURLString: movie.iconURLString,
                            containerExtension: movie.containerExtension
                        )
                    ) { onPlayIPTVMovie?(movie) }
                }
                ForEach(iptvMatches.series) { item in
                    iptvRow(
                        name: item.name, kind: "Dizi",
                        favorite: IPTVFavorite(
                            kind: .series, streamID: item.id, name: item.name,
                            iconURLString: item.coverURLString
                        )
                    ) { onOpenIPTVSeries?(item) }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 18)
        }
    }

    private func iptvRow(name: String, kind: String, favorite: IPTVFavorite,
                         action: @escaping () -> Void) -> some View {
        let isFavorite = iptv?.isFavorite(favorite) ?? false
        return Button(action: action) {
            HStack(spacing: 10) {
                Text("IP TV")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color(red: 0.15, green: 0.55, blue: 0.35), in: Capsule())
                    .foregroundStyle(.white)

                Text(IPTVNaming.split(name).name)
                    .lineLimit(1)

                Text(kind)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 8)

                // Favorideyse yıldız görünür duruyor: sağ tık menüsünü açmadan
                // hangisini işaretlediğin belli olsun.
                if isFavorite {
                    Image(systemName: "star.fill")
                        .font(.caption)
                        .foregroundStyle(.yellow)
                }

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isFavorite ? "Favorilerde — sağ tıklayarak çıkarabilirsiniz"
                         : "Sağ tıklayarak favorilere ekleyebilirsiniz")
        .contextMenu {
            if let iptv {
                Button(isFavorite ? "Favorilerden Çıkar" : "Favorilere Ekle",
                       systemImage: isFavorite ? "star.slash" : "star") {
                    iptv.toggleFavorite(favorite)
                }
            }
        }
    }

    // MARK: - Akışlarda ara

    private func searchStreams() {
        // IPTV kataloğu bellekte: aynı düğme aboneliği de tarıyor.
        if let iptv, iptv.isConfigured {
            let query = loader.displayTitle ?? title.title
            let hits = iptv.search(query, limitPerSection: 6)
            iptvMatches = (hits.movies, hits.series)
        }
        Task {
            await streams.search(
                title,
                displayTitle: loader.displayTitle ?? title.title,
                originalTitle: loader.originalTitle,
                settings: settings,
                providers: settings.enabledStreamProviders
            )
        }
    }

    @ViewBuilder
    private var streamResults: some View {
        switch streams.state {
        case .idle:
            EmptyView()

        case .searching:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Akışlarda aranıyor…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.top, 18)

        case .empty:
            streamNotice("Akışlarda bulunamadı.", color: .secondary)

        case .unreachable:
            streamNotice("Akış kaynaklarına şu an ulaşılamıyor. Birazdan tekrar deneyin.",
                         color: .orange)

        case .found(let hits):
            VStack(alignment: .leading, spacing: 8) {
                Text("Akışlarda Bulundu")
                    .font(.system(size: 15, weight: .semibold))

                ForEach(hits) { hit in
                    Button { onOpenStream(hit) } label: {
                        HStack(spacing: 10) {
                            let badge = StreamRegistry.badge(forProviderID: hit.providerID)
                            Text(badge.name)
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color(hex: badge.hex), in: Capsule())
                                .foregroundStyle(.white)

                            Text(hit.title)
                                .lineLimit(1)

                            if let year = hit.year {
                                Text(String(year))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer(minLength: 8)

                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 18)
        }
    }

    private func streamNotice(_ text: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
            Text(text)
        }
        .font(.callout)
        .foregroundStyle(color)
        .padding(.horizontal, 24)
        .padding(.top, 18)
    }

    /// A film plays; a show opens its library detail, which is where seasons and
    /// episodes are chosen.
    private var playAction: (() -> Void)? {
        if let movie = ownedMovie { return { onPlay(movie) } }
        if let key = ownedSeriesKey { return { onOpenSeries(key) } }
        return nil
    }

    private var playLabel: String {
        if let movie = ownedMovie {
            let state = library.state(for: movie)
            if let state, state.isInProgress {
                return "\(state.position.asTimecode) konumundan devam et"
            }
            return "Oynat"
        }
        return "Kütüphanede Aç"
    }

    private var metaLine: String {
        var parts: [String] = []
        if let year = title.year { parts.append(String(year)) }
        if let runtime = loader.runtimeMinutes, runtime > 0 { parts.append("\(runtime) dk") }
        if let seasons = loader.seasonCount, seasons > 0 { parts.append("\(seasons) sezon") }
        if !isOwned { parts.append(title.kind == .movie ? "Film" : "Dizi") }
        return parts.joined(separator: " · ")
    }
}

/// A TMDB-only card. Used by the In Cinemas rail and by search results that the
/// library does not have.
struct RemoteCard: View {
    let title: RemoteTitle
    let isOwned: Bool
    var library: LibraryStore? = nil
    var imdbRating: Double? = nil
    let onSelect: () -> Void
    var isGamepadSelected: Bool = false

    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: onSelect) {
            PosterCard(
                title: title.title,
                subtitle: subtitle,
                posterURL: title.posterURL,
                badge: isOwned ? .inLibrary : nil,
                imdbRating: imdbRating,
                isFocused: isFocused,
                isGamepadSelected: isGamepadSelected
            )
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .contextMenu {
            Button("Aç") { onSelect() }
            if let library {
                Divider()
                let isFav = library.remoteFavorites.contains { $0.id == title.id }
                Button(isFav ? "Favorilerden Çıkar" : "Favorilere Ekle") {
                    library.toggleFavorite(remote: title)
                }
            }
        }
    }

    private var subtitle: String {
        let year = title.year.map(String.init) ?? ""
        let kind = title.kind == .movie ? "Film" : "Dizi"
        return year.isEmpty ? kind : "\(year) · \(kind)"
    }
}
