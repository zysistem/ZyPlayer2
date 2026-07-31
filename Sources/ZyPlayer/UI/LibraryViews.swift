import SwiftUI
import AppKit

/// Actions a library view can trigger.
struct LibraryActions {
    var selectItem: (MediaItem) -> Void
    var selectSeries: (Series) -> Void
    /// Opens the TMDB-only detail for a title the library does not have.
    var selectRemote: (RemoteTitle) -> Void
    /// Opens the category genre detail page.
    var selectCategory: (CategoryGenre) -> Void = { _ in }
    var play: (MediaItem) -> Void
    /// Jumps the sidebar to Movies or Shows.
    var showAll: (SidebarItem) -> Void
    /// "İzledim" / "İzlemedim" — mark one item watched or not.
    var markWatched: (MediaItem, Bool) -> Void = { _, _ in }
    /// "İzleyeceğim" — add or remove one item from the watchlist.
    var setWatchlist: (MediaItem, Bool) -> Void = { _, _ in }
    /// Same two, for a whole show.
    var markSeriesWatched: (Series, Bool) -> Void = { _, _ in }
    var setSeriesWatchlist: (Series, Bool) -> Void = { _, _ in }
    /// Resume a torrent from a saved ResumePoint.
    var resumeTorrent: (ResumePoint) -> Void = { _ in }
}

/// Home shows the trailer hero + categories on top, then the ZyStream
/// discovery shelves (recent films, series…) plus an "İzlemeye Devam Et" row
/// for in-progress stream titles — replacing the old per-day library sections.
private let homeSectionLimit = 20

struct HomeView: View {
    let library: LibraryStore
    let cinema: CinemaStore
    let appleTV: AppleTVStore
    /// Netflix / Amazon Prime rafları.
    let providers: StreamingProviderStore
    let settings: AppSettings
    let actions: LibraryActions
    /// ZyStream store — drives the discovery shelves and "İzlemeye Devam Et".
    let stream: ZyStreamStore
    let resume: PlaybackResumeStore
    /// Called when a ZyStream card or continue-watching card is tapped.
    let onOpenStream: (StreamHit) -> Void

    /// Fullscreen fits wider rails: 10 cards across, two rows, so 20 per section
    /// instead of the windowed 7×2 = 14.
    @State private var isFullscreen = false
    private var columnCount: Int { isFullscreen ? 10 : 7 }
    private var sectionLimit: Int { isFullscreen ? 20 : 14 }

    var body: some View {
        content
            .task {
                await stream.loadDiscover(providers: settings.enabledStreamProviders)
            }
            .onAppear {
                isFullscreen = NSApp.keyWindow?.styleMask.contains(.fullScreen) ?? false
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in
                isFullscreen = true
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in
                isFullscreen = false
            }
    }

    @ViewBuilder
    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                // 1. Ana ekranda sinemadaki filmler ve fragman otomatik oynatma (Hero Banner)
                HeroCinemaBanner(
                    movies: cinema.movies,
                    library: library,
                    settings: settings,
                    actions: actions
                )

                // 2. İzlemeyi sürdür — kütüphane + stream + torrent tek satırda
                let continueList = resume.streamContinue
                let torrentList = resume.points.filter { $0.kind == .torrent && !$0.isFinished && $0.position > 5 }
                let resumePoints = (continueList + torrentList).sorted { $0.updatedAt > $1.updatedAt }

                if !library.continueWatching.isEmpty || !resumePoints.isEmpty {
                    ContinueWatchingRow(
                        items: library.continueWatching,
                        library: library,
                        actions: actions,
                        settings: settings,
                        resumePoints: resumePoints,
                        onResumeTorrent: { point in actions.resumeTorrent(point) },
                        onResumeStream: { point in stream.resumeStream(point) },
                        onRemoveResumePoint: { point in resume.remove(key: point.id) }
                    )
                }

                // 3. Kategori sistemi
                CategoryGridRow { category in
                    actions.selectCategory(category)
                }

                // 4. ZyStream keşif rafları (Son Eklenen Filmler, Son Eklenen Diziler, vb.)
                if settings.hasEnabledStreamSources {
                    if stream.isLoadingShelves && stream.shelves.isEmpty {
                        HStack {
                            Spacer()
                            ProgressView("İçerikler yükleniyor…")
                            Spacer()
                        }
                        .padding(.vertical, 24)
                    } else {
                        ForEach(stream.shelves) { shelf in
                            SectionBlock(title: shelf.title, total: shelf.hits.count,
                                         onShowAll: nil, columns: columnCount, limit: sectionLimit) {
                                ForEach(Array(shelf.hits.prefix(sectionLimit))) { hit in
                                    StreamHitCard(hit: hit, store: stream,
                                                  onOpen: onOpenStream, library: library)
                                }
                            }
                        }
                    }
                }

                // 5. En altta Netflix ve Amazon Prime — son eklenen diziler ve filmler
                ForEach(providers.shelves) { shelf in
                    StreamingBrandShelves(
                        shelf: shelf,
                        logoURL: providers.logoURL(for: shelf.brand),
                        library: library,
                        actions: actions,
                        columns: columnCount
                    )
                }
            }
            .padding(.vertical, 22)
        }
    }

    /// Rebuilds a StreamHit from a ResumePoint so the shared StreamHitCard can play it.
    private func hitFrom(_ point: ResumePoint) -> StreamHit {
        StreamHit(
            providerID: point.providerID ?? "",
            providerName: point.providerID.flatMap { StreamRegistry.info(id: $0)?.displayName } ?? "",
            kind: .movie,
            title: point.title,
            year: nil,
            posterURL: point.posterURL,
            pageURL: point.pageURL ?? ""
        )
    }
}

/// Section header plus a fixed 7-column grid, so 14 items land as two full rows.
struct SectionBlock<Content: View>: View {
    let title: String
    let total: Int
    let onShowAll: (() -> Void)?
    /// Cards per row. Home widens this in fullscreen; everywhere else it is 10.
    var columns: Int = 10
    /// How many cards a full section shows, so "Tümünü Gör" only appears when
    /// there is genuinely more behind it.
    var limit: Int = homeSectionLimit
    /// Başlığın soluna konan marka logosu — Netflix/Prime rafları doldurur.
    var logo: StreamingBrandBadge? = nil
    @ViewBuilder let content: Content

    private var gridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 22), count: columns)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                if let logo {
                    // Logo metnin taban çizgisiyle değil, satırın ortasıyla hizalanmalı.
                    logo.alignmentGuide(.firstTextBaseline) { $0[.bottom] - 5 }
                }
                Text(title).font(.system(size: 16, weight: .semibold))
                Text("\(total)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if let onShowAll, total > limit {
                    Button(action: onShowAll) {
                        HStack(spacing: 3) {
                            Text("Tümünü Gör")
                            Image(systemName: "chevron.right").font(.caption2)
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.tint)
                }
            }
            .padding(.horizontal, 24)

            LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 26) {
                content
            }
            .padding(.horizontal, 24)
        }
    }
}

struct MoviesView: View {
    let library: LibraryStore
    let actions: LibraryActions
    var selectedIndex: Int = -1

    var body: some View {
        if library.movies.isEmpty {
            EmptyLibraryView(title: "Filmler")
        } else {
            PosterGrid(items: library.movies, selectedIndex: selectedIndex) { item, isGamepadSelected in
                MediaCard(item: item, state: library.state(for: item), actions: actions, isGamepadSelected: isGamepadSelected)
            }
        }
    }
}

struct ShowsView: View {
    let library: LibraryStore
    let actions: LibraryActions
    var selectedIndex: Int = -1

    var body: some View {
        if library.shows.isEmpty {
            EmptyLibraryView(title: "Diziler")
        } else {
            PosterGrid(items: library.shows, selectedIndex: selectedIndex) { series, isGamepadSelected in
                SeriesCard(series: series, actions: actions,
                           isWatched: library.isSeriesFullyWatched(seriesKey: series.id),
                           isGamepadSelected: isGamepadSelected)
            }
        }
    }
}

struct FavoritesView: View {
    let library: LibraryStore
    let actions: LibraryActions
    /// Passed so favourited ZyStream titles can open from the Favourites screen.
    var stream: ZyStreamStore?
    var onSelectStream: ((StreamHit) -> Void)?

    var body: some View {
        if !library.hasFavorites {
            VStack(spacing: 12) {
                Image(systemName: "star")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text("Favori yok").font(.title2.weight(.semibold))
                Text("Bir film ya da dizinin detay ekranındaki yıldıza basarak ekleyin.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    if !library.favoriteShows.isEmpty {
                        SectionBlock(title: "Diziler", total: library.favoriteShows.count,
                                     onShowAll: nil) {
                            ForEach(library.favoriteShows) { series in
                                SeriesCard(series: series, actions: actions, library: library,
                                           isWatched: library.isSeriesFullyWatched(seriesKey: series.id))
                            }
                        }
                    }
                    if !library.favoriteMovies.isEmpty {
                        SectionBlock(title: "Filmler", total: library.favoriteMovies.count,
                                     onShowAll: nil) {
                            ForEach(library.favoriteMovies) { item in
                                MediaCard(item: item, state: library.state(for: item), actions: actions, library: library)
                            }
                        }
                    }

                    // Favourited ZyStream titles, played straight from the source.
                    if let stream, let onSelectStream, !library.streamFavorites.isEmpty {
                        SectionBlock(title: "ZyStream", total: library.streamFavorites.count,
                                     onShowAll: nil) {
                            ForEach(library.streamFavorites) { hit in
                                StreamHitCard(hit: hit, store: stream, onOpen: onSelectStream, library: library)
                            }
                        }
                    }

                    // Favourited but not owned: these open the TMDB detail, where
                    // the torrent list lives.
                    let remote = library.remoteFavoritesNotOwned
                    if !remote.isEmpty {
                        SectionBlock(title: "Kütüphanemde Olmayanlar", total: remote.count,
                                     onShowAll: nil) {
                            ForEach(remote) { title in
                                RemoteCard(
                                    title: title,
                                    isOwned: false,
                                    library: library,
                                    onSelect: { actions.selectRemote(title) }
                                )
                            }
                        }
                    }
                }
                .padding(.vertical, 22)
            }
        }
    }
}

/// A single playable item; opens the detail screen, like Infuse does.
struct MediaCard: View {
    let item: MediaItem
    let state: WatchState?
    let actions: LibraryActions
    var library: LibraryStore? = nil
    var badge: PosterBadge?
    var onRemove: (() -> Void)?
    var posterOverride: String?
    var titleOverride: String?
    var onSelectOverride: (() -> Void)?
    var isGamepadSelected: Bool = false

    @State private var isHovering = false
    @FocusState private var isFocused: Bool

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button {
                if let onSelectOverride {
                    onSelectOverride()
                } else {
                    actions.selectItem(item)
                }
            } label: {
                PosterCard(
                    title: titleOverride ?? item.title,
                    subtitle: item.subtitleLine,
                    progress: state?.progress ?? 0,
                    isFinished: state?.isFinished ?? false,
                    watchlisted: state?.wantToWatch ?? false,
                    posterFileName: posterOverride ?? item.posterFileName,
                    badge: badge,
                    isRemovable: onRemove != nil,
                    isFocused: isFocused,
                    isGamepadSelected: isGamepadSelected
                )
            }
            .buttonStyle(.plain)
            .focused($isFocused)

            if let onRemove, (isHovering || isFocused) {
                PosterCard.removeButton(onRemove)
                    .transition(.opacity)
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Oynat") { actions.play(item) }
            Divider()
            let watched = state?.isFinished ?? false
            Button(watched ? "İzlemedim olarak işaretle" : "İzledim") {
                actions.markWatched(item, !watched)
            }
            let listed = state?.wantToWatch ?? false
            Button(listed ? "İzleyeceklerimden çıkar" : "İzleyeceğim") {
                actions.setWatchlist(item, !listed)
            }
            Divider()
            if let library {
                Button(item.isFavorite ? "Favorilerden Çıkar" : "Favorilere Ekle") {
                    library.toggleFavorite(item)
                }
                Divider()
            }
            if let onRemove {
                Button("İzlemeye Devam Et’ten Kaldır", action: onRemove)
            }
            Button("Finder'da Göster") {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            }
        }
    }
}

struct SeriesCard: View {
    let series: Series
    let actions: LibraryActions
    var library: LibraryStore? = nil
    var badge: PosterBadge?
    var isWatched: Bool = false
    var isGamepadSelected: Bool = false

    @FocusState private var isFocused: Bool

    var body: some View {
        let listed = series.meta?.wantToWatch ?? false
        Button {
            actions.selectSeries(series)
        } label: {
            PosterCard(
                title: series.displayName,
                subtitle: "\(series.episodes.count) bölüm · \(series.seasonCount) sezon",
                isFinished: isWatched,
                watchlisted: listed,
                posterFileName: series.meta?.posterFileName,
                badge: badge,
                isFocused: isFocused,
                isGamepadSelected: isGamepadSelected
            )
        }
        .buttonStyle(.plain)
        .focused($isFocused)
        .contextMenu {
            Button(isWatched ? "İzlemedim olarak işaretle" : "Tümünü izledim") {
                actions.markSeriesWatched(series, !isWatched)
            }
            Button(listed ? "İzleyeceklerimden çıkar" : "İzleyeceğim") {
                actions.setSeriesWatchlist(series, !listed)
            }
            if let library {
                Divider()
                let isFav = series.meta?.isFavorite ?? false
                Button(isFav ? "Favorilerden Çıkar" : "Favorilere Ekle") {
                    library.toggleFavorite(seriesKey: series.id)
                }
            }
        }
    }
}

