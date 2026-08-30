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
    /// Bir kütüphane öğesinin detay ekranı. Bölümler kendi başlarına bir
    /// sayfaya sahip değil; dizisinin sayfası açılır, bölüm listesi orada.
    var openDetail: (MediaItem) -> Void = { _ in }
    /// Bir devam kaydının detay ekranı (torrent ya da ZyStream yapımı).
    var openResumeDetail: (ResumePoint) -> Void = { _ in }
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
    /// "Sizin İçin Öneriler" rafı — NVIDIA NIM'e izleme geçmişine göre sorar.
    let recommendations: RecommendationStore
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
                async let a: () = stream.loadDiscover(providers: settings.enabledStreamProviders)
                async let b: () = library.refreshTrending(settings: settings)
                async let c: () = cinema.refresh(settings: settings)
                async let d: () = appleTV.refresh(settings: settings)
                async let e: () = providers.refresh(settings: settings)
                _ = await (a, b, c, d, e)
                let seedInfo = TMDBRecommendationSeedBuilder.build(library: library)
                await recommendations.refreshIfNeeded(seeds: seedInfo.seeds, excluded: seedInfo.excluded,
                                                        settings: settings)
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
                        onRemoveResumePoint: { point in resume.remove(key: point.id) },
                        onOpenResumeDetail: { point in actions.openResumeDetail(point) }
                    )
                }

                // 2.5 Sizin İçin Öneriler — TMDB'nin izlenmiş film/dizileri tohum alan
                // öneri uç noktasından. Önbellekteki en fazla 20 seçimin tamamı,
                // 10'ar iki sıra halinde (10+10).
                let recItems = recommendations.displayItems()
                if !recItems.isEmpty {
                    RecommendationsRow(
                        items: recItems,
                        library: library,
                        stream: stream,
                        actions: actions,
                        onOpenStream: onOpenStream
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

/// "Sizin İçin Öneriler" — NVIDIA NIM'in izleme geçmişine bakıp seçtiği
/// kartlar, her birinin altında kısa bir gerekçe. Kart türü kütüphane
/// filmi/dizisi, ZyStream ya da Netflix/Prime/sinema (RemoteTitle) olabilir;
/// hepsi kendi paylarına düşen mevcut kart bileşenini kullanır, böylece
/// oynatma/favori/işaretleme davranışı diğer raflarla birebir aynı kalır.
struct RecommendationsRow: View {
    let items: [(candidate: RecommendationCandidate, imdbRating: Double?)]
    let library: LibraryStore
    let stream: ZyStreamStore
    let actions: LibraryActions
    let onOpenStream: (StreamHit) -> Void
    /// 10'ar iki sıra (10+10) — bu raf en fazla 20 (TMDBRecommender.maxPicks) kart gösterir.
    private let columns = 10

    private var gridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 22), count: columns)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                Text("Sizin İçin Öneriler").font(.system(size: 16, weight: .semibold))
            }
            .padding(.horizontal, 24)

            LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 26) {
                ForEach(items, id: \.candidate.id) { entry in
                    CandidateCardView(candidate: entry.candidate, library: library, stream: stream,
                                       actions: actions, onOpenStream: onOpenStream,
                                       imdbRating: entry.imdbRating)
                }
            }
            .padding(.horizontal, 24)
        }
    }
}

/// Bir `RecommendationCandidate`'ı türüne uygun karta çevirir — hem ana ekran
/// önerileri hem de sohbet asistanının önerdiği başlıkların küçük çipleri bu
/// tek noktadan geçiyor, böylece tıklama/oynatma davranışı her yerde aynı.
struct CandidateCardView: View {
    let candidate: RecommendationCandidate
    let library: LibraryStore
    let stream: ZyStreamStore
    let actions: LibraryActions
    let onOpenStream: (StreamHit) -> Void
    /// Yalnızca "Sizin İçin Öneriler" rafından geliyor — TMDB'nin önerdiği
    /// başlığın IMDb kimliği çözülüp resmi veri kümesinden bulunmuş puanı.
    var imdbRating: Double? = nil

    var body: some View {
        switch candidate {
        case .movie(let item):
            MediaCard(item: item, state: library.state(for: item), actions: actions, library: library)
        case .series(let series):
            SeriesCard(series: series, actions: actions, library: library)
        case .stream(let hit):
            StreamHitCard(hit: hit, store: stream, onOpen: onOpenStream, library: library)
        case .remote(let title):
            RemoteCard(title: title, isOwned: isOwned(title), library: library,
                       imdbRating: imdbRating, onSelect: { actions.selectRemote(title) })
        }
    }

    private func isOwned(_ title: RemoteTitle) -> Bool {
        switch title.kind {
        case .movie: library.ownedMovieTMDBIDs.contains(title.tmdbID)
        case .tv: library.ownedShowTMDBIDs.contains(title.tmdbID)
        }
    }
}

/// Sidebar'daki "Kütüphane": tek yerde, üstte Film/Dizi tab'ı, altta kütüphane
/// filmleri ya da dizileri. Eski ayrı "Filmler"/"Diziler" sidebar öğelerinin
/// yerini alıyor (o adlar artık akış içeriğine ayrıldı).
struct LibraryTabsView: View {
    let library: LibraryStore
    let actions: LibraryActions

    enum Tab: String, CaseIterable { case series = "Dizi", movies = "Film" }
    @State private var tab: Tab = .series

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 220)
            .padding(.horizontal, 22)
            .padding(.vertical, 12)

            Divider().opacity(0.3)

            switch tab {
            case .movies: MoviesView(library: library, actions: actions)
            case .series: ShowsView(library: library, actions: actions)
            }
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

/// Favoriler / İzledim / İzleyeceğim — üstteki sekmelerle geçiliyor.
/// Kaynak fark etmiyor: kütüphane, ZyStream, IPTV, torrent (ZyMovie) ve
/// Apple TV+/Bollywood'un TMDB kartları hepsi aynı iki sekmede toplanıyor.
struct FavoritesView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case favorites, watched, toWatch
        var id: String { rawValue }
        var title: String {
            switch self {
            case .favorites: "Favoriler"
            case .watched: "İzledim"
            case .toWatch: "İzleyeceğim"
            }
        }
    }

    let library: LibraryStore
    let actions: LibraryActions
    /// Passed so favourited ZyStream titles can open from the Favourites screen.
    var stream: ZyStreamStore?
    var onSelectStream: ((StreamHit) -> Void)?
    /// Favoriye alınmış IPTV içerikleri buradan da oynatılabiliyor.
    var iptv: IPTVStore?
    var onPlayIPTVFavorite: ((IPTVFavorite) -> Void)?
    /// İzledim sekmesindeki "İzlemeyi Sürdür" tipi kartları (ZyStream/torrent/
    /// IPTV) oynatabilmek/detayına dönebilmek için.
    var resume: PlaybackResumeStore?
    /// Afiş eksikse TMDB'den başlığa göre yedek afiş aramak için.
    var settings: AppSettings?

    @State private var tab: Tab = .favorites

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 320)
            .padding(.top, 16)
            .padding(.bottom, 4)

            switch tab {
            case .favorites: favoritesTab
            case .watched: watchedTab
            case .toWatch: toWatchTab
            }
        }
    }

    // MARK: - Favoriler

    private var favoritesTab: some View {
        Group {
            if !library.hasFavorites {
                emptyState(icon: "star", title: "Favori yok",
                           detail: "Bir film ya da dizinin detay ekranındaki yıldıza basarak ekleyin.")
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

                        // Favoriye alınmış IPTV içerikleri. Kanal ve film doğrudan
                        // açılıyor, dizi bölüm listesini getiriyor.
                        if let iptv, !iptv.favorites.isEmpty {
                            SectionBlock(title: "IP Tv", total: iptv.favorites.count,
                                         onShowAll: nil) {
                                ForEach(iptv.favorites) { favorite in
                                    IPTVSearchCard(
                                        title: favorite.name,
                                        imageURL: favorite.iconURL,
                                        kindLabel: favorite.kindLabel
                                    ) {
                                        onPlayIPTVFavorite?(favorite)
                                    }
                                    .contextMenu {
                                        Button("Favorilerden Çıkar", systemImage: "star.slash") {
                                            iptv.toggleFavorite(favorite)
                                        }
                                    }
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

    // MARK: - İzledim

    /// Oynanarak %92'sinin üzerine geçilen ya da 10 dakikadan azı kalan her
    /// ZyStream/torrent/IPTV içeriği burada — kaynağı ne olursa olsun,
    /// `ResumePoint.isFinished` zaten otomatik hesaplanıyor, ayrıca bir
    /// "işaretleme" adımı gerekmiyor. Sağ tıkla elle işaretlenenler (ör.
    /// hiç oynatılmadan "İzledim" denen ya da Apple TV+/Bollywood'un henüz
    /// kütüphanede olmayan TMDB kartları) altında ayrıca listeleniyor.
    private var watchedTab: some View {
        let finishedPoints = (resume?.points ?? []).filter(\.isFinished)
            .sorted { $0.updatedAt > $1.updatedAt }
        let coveredKeys = Set(finishedPoints.map(\.id))
        let watchedMovies = library.movies.filter { library.isWatched($0) }
        let watchedShows = library.shows.filter { library.isSeriesFullyWatched(seriesKey: $0.id) }
        let snapshots = WatchFlagsStore.shared.finishedSnapshots.filter { !coveredKeys.contains($0.key) }
        // Bir dizinin izlenen her bölümü ayrı bir `ResumePoint`; burada
        // sayı kadar kart değil, dizi başına tek kart olsun diye gruplanıyor.
        let watchedGroups = groupFinishedPoints(finishedPoints)

        return Group {
            if finishedPoints.isEmpty && watchedMovies.isEmpty && watchedShows.isEmpty && snapshots.isEmpty {
                emptyState(icon: "checkmark.circle", title: "İzlediğiniz bir şey yok",
                           detail: "Bir içeriği sonuna kadar izleyin ya da sağ tıkla \"İzledim\" işaretleyin.")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        if !watchedShows.isEmpty {
                            SectionBlock(title: "Diziler", total: watchedShows.count, onShowAll: nil) {
                                ForEach(watchedShows) { series in
                                    SeriesCard(series: series, actions: actions, library: library, isWatched: true)
                                }
                            }
                        }
                        if !watchedMovies.isEmpty {
                            SectionBlock(title: "Filmler", total: watchedMovies.count, onShowAll: nil) {
                                ForEach(watchedMovies) { item in
                                    MediaCard(item: item, state: library.state(for: item), actions: actions, library: library)
                                }
                            }
                        }
                        if !watchedGroups.isEmpty {
                            SectionBlock(title: "ZyStream · Torrent · IP TV", total: watchedGroups.count,
                                         onShowAll: nil) {
                                ForEach(watchedGroups) { group in
                                    WatchedGroupCard(
                                        group: group,
                                        stream: stream,
                                        settings: settings,
                                        onOpen: { openWatchedGroup(group) },
                                        onRemove: {
                                            for key in group.allKeys { resume?.remove(key: key) }
                                        }
                                    )
                                }
                            }
                        }
                        snapshotSections(snapshots, emptyMessage: nil)
                    }
                    .padding(.vertical, 22)
                }
            }
        }
    }

    // MARK: - İzleyeceğim

    private var toWatchTab: some View {
        let watchlistMovies = library.movies.filter { library.isWatchlisted($0) }
        let watchlistShows = library.shows.filter { $0.meta?.wantToWatch == true }
        let snapshots = WatchFlagsStore.shared.wantToWatchSnapshots

        return Group {
            if watchlistMovies.isEmpty && watchlistShows.isEmpty && snapshots.isEmpty {
                emptyState(icon: "bookmark", title: "İzleyecekleriniz boş",
                           detail: "Bir kartta sağ tıkla \"İzleyeceğim\" seçin, buraya eklensin.")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        if !watchlistShows.isEmpty {
                            SectionBlock(title: "Diziler", total: watchlistShows.count, onShowAll: nil) {
                                ForEach(watchlistShows) { series in
                                    SeriesCard(series: series, actions: actions, library: library,
                                               isWatched: library.isSeriesFullyWatched(seriesKey: series.id))
                                }
                            }
                        }
                        if !watchlistMovies.isEmpty {
                            SectionBlock(title: "Filmler", total: watchlistMovies.count, onShowAll: nil) {
                                ForEach(watchlistMovies) { item in
                                    MediaCard(item: item, state: library.state(for: item), actions: actions, library: library)
                                }
                            }
                        }
                        snapshotSections(snapshots, emptyMessage: nil)
                    }
                    .padding(.vertical, 22)
                }
            }
        }
    }

    // MARK: - Ortak

    /// `WatchFlagsStore` anlık görüntülerini kaynağa göre grupluyor — her biri
    /// zaten kendi türünün kartını (rozet ve İzledim/İzleyeceğim menüsü dahil)
    /// biliyor, burada yalnızca doğru bileşene yönlendiriliyor.
    @ViewBuilder
    private func snapshotSections(_ snapshots: [(key: String, snapshot: WatchSnapshot)],
                                  emptyMessage: String?) -> some View {
        let streams: [StreamHit] = snapshots.compactMap {
            if case .stream(let hit) = $0.snapshot { return hit }
            return nil
        }
        let iptvItems: [IPTVFavorite] = snapshots.compactMap {
            if case .iptv(let fav) = $0.snapshot { return fav }
            return nil
        }
        let remotes: [RemoteTitle] = snapshots.compactMap {
            if case .remote(let title) = $0.snapshot { return title }
            return nil
        }
        let torrents: [ZyMovieHit] = snapshots.compactMap {
            if case .torrent(let hit) = $0.snapshot { return hit }
            return nil
        }

        if let stream, let onSelectStream, !streams.isEmpty {
            SectionBlock(title: "ZyStream", total: streams.count, onShowAll: nil) {
                ForEach(streams) { hit in
                    StreamHitCard(hit: hit, store: stream, onOpen: onSelectStream, library: library)
                }
            }
        }
        if let iptv, !iptvItems.isEmpty {
            SectionBlock(title: "IP Tv", total: iptvItems.count, onShowAll: nil) {
                ForEach(iptvItems) { favorite in
                    IPTVSearchCard(
                        title: favorite.name,
                        imageURL: favorite.iconURL,
                        kindLabel: favorite.kindLabel,
                        isFinished: WatchFlagsStore.shared.isFinished(favorite.id),
                        watchlisted: WatchFlagsStore.shared.isWantToWatch(favorite.id)
                    ) {
                        onPlayIPTVFavorite?(favorite)
                    }
                    .contextMenu {
                        let watched = WatchFlagsStore.shared.isFinished(favorite.id)
                        Button(watched ? "İzlemedim olarak işaretle" : "İzledim") {
                            WatchFlagsStore.shared.setFinished(favorite.id, !watched, snapshot: .iptv(favorite))
                        }
                        let listed = WatchFlagsStore.shared.isWantToWatch(favorite.id)
                        Button(listed ? "İzleyeceklerimden çıkar" : "İzleyeceğim") {
                            WatchFlagsStore.shared.setWantToWatch(favorite.id, !listed, snapshot: .iptv(favorite))
                        }
                        Divider()
                        Button(iptv.isFavorite(favorite) ? "Favorilerden Çıkar" : "Favorilere Ekle") {
                            iptv.toggleFavorite(favorite)
                        }
                    }
                }
            }
        }
        if !remotes.isEmpty {
            SectionBlock(title: "Apple TV+ · Bollywood", total: remotes.count, onShowAll: nil) {
                ForEach(remotes) { title in
                    RemoteCard(
                        title: title,
                        isOwned: false,
                        library: library,
                        onSelect: { actions.selectRemote(title) }
                    )
                }
            }
        }
        if !torrents.isEmpty {
            SectionBlock(title: "Torrent (ZyMovie)", total: torrents.count, onShowAll: nil) {
                ForEach(torrents) { hit in
                    TorrentSnapshotCard(hit: hit, settings: settings, onOpen: actions.selectRemote)
                }
            }
        }
    }

    /// Bir dizinin izlenen bölümleri ayrı `ResumePoint`'ler (her bölümün
    /// kendi sayfası/kimliği var) — "her bölüm için ayrı kart olmasın, sadece
    /// dizi" isteği üzerine, dizisi belli olan noktalar dizi kimliğine göre
    /// tek gruba toplanıyor. IPTV'de `iptvSeriesID`, ZyStream'de
    /// `streamHit` (bölümün değil, açılan dizi sayfasının kendisi — bkz.
    /// `ZyStreamStore.resolveAndPlay`) grup anahtarı oluyor; ikisi de yoksa
    /// (torrent, film, eski kayıt) nokta kendi başına bir grup.
    private func groupFinishedPoints(_ points: [ResumePoint]) -> [WatchedGroup] {
        var order: [String] = []
        var byKey: [String: [ResumePoint]] = [:]
        for point in points {
            let key: String
            if point.id.hasPrefix("iptv:episode:"), let seriesID = point.iptvSeriesID {
                key = "iptv-series-\(seriesID)"
            } else if let hit = point.streamHit {
                key = "stream-\(hit.id)"
            } else {
                key = point.id
            }
            if byKey[key] == nil { order.append(key) }
            byKey[key, default: []].append(point)
        }
        return order.compactMap { key in
            guard let items = byKey[key], let newest = items.max(by: { $0.updatedAt < $1.updatedAt })
            else { return nil }
            let allKeys = items.map(\.id)
            if key.hasPrefix("iptv-series-"), let seriesID = newest.iptvSeriesID,
               let series = iptv?.series(withID: seriesID) {
                return WatchedGroup(id: key, title: IPTVNaming.split(series.name).name,
                                    posterURL: series.coverURL, representative: newest, allKeys: allKeys)
            }
            if let hit = newest.streamHit {
                return WatchedGroup(id: key, title: hit.title, posterURL: hit.posterURL,
                                    representative: newest, allKeys: allKeys)
            }
            return WatchedGroup(id: key, title: newest.title, posterURL: newest.posterURL,
                                representative: newest, allKeys: allKeys)
        }
        .sorted { $0.representative.updatedAt > $1.representative.updatedAt }
    }

    /// İzledim'de karta tıklamak her zaman detay sayfasını açar, dizi ya da
    /// film fark etmeksizin — doğrudan oynatma yok. `openResumeDetail`
    /// (`RootView`) zaten ikisini de tek yolla çözüyor: `streamHit` varsa
    /// ZyStream detayı, `remoteTitle` varsa TMDB detayı, `"iptv:"` önekiyse
    /// IPTV detayı.
    private func openWatchedGroup(_ group: WatchedGroup) {
        actions.openResumeDetail(group.representative)
    }

    private func emptyState(icon: String, title: String, detail: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text(title).font(.title2.weight(.semibold))
            Text(detail)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// İzledim sekmesinde bir dizinin bütün bitmiş bölümlerini temsil eden tek
/// kart. `allKeys`, hepsini "Listeden Kaldır"da birlikte silebilmek için.
struct WatchedGroup: Identifiable {
    let id: String
    let title: String
    let posterURL: URL?
    let representative: ResumePoint
    let allKeys: [String]
}

/// `WatchedGroup`ün kartı. ZyStream afişleri Cloudflare arkasında olduğundan
/// düz `AsyncImage` çoğu zaman boş döner (bkz. `StreamHitCard`) — bu yüzden
/// temsilci noktanın `streamHit`i varsa aynı `StreamImageLoader` + temizlenmiş
/// web görünümü yoluyla çekiliyor; yoksa (IPTV/torrent) doğrudan URL yeterli.
struct WatchedGroupCard: View {
    let group: WatchedGroup
    var stream: ZyStreamStore?
    /// Afiş hiç gelmezse (site vermedi ya da Cloudflare engelledi) TMDB'den
    /// başlığa göre yedek afiş aramak için.
    var settings: AppSettings?
    let onOpen: () -> Void
    let onRemove: () -> Void

    @State private var streamPoster: NSImage?
    @State private var fallbackPosterURL: URL?

    var body: some View {
        Button(action: onOpen) {
            PosterCard(title: group.title, subtitle: "", isFinished: true,
                       posterURL: group.posterURL ?? fallbackPosterURL, posterImage: streamPoster)
        }
        .buttonStyle(.plain)
        .task(id: group.id) {
            if let hit = group.representative.streamHit, let url = group.posterURL, let stream,
               let base = stream.baseURL(forProviderID: hit.providerID) {
                streamPoster = await StreamImageLoader.shared.image(for: url, baseURL: base)
            }
            guard streamPoster == nil, group.posterURL == nil, let settings else { return }
            fallbackPosterURL = await tmdbPosterURL(forTitle: group.title, settings: settings)
        }
        .contextMenu {
            Button("Detayı Aç", action: onOpen)
            Divider()
            Button("Listeden Kaldır", action: onRemove)
        }
    }
}

/// `ZyMovieHit`'in TMDB eşleşmesi varsa (çoğu zaman öyle) dokununca onun
/// detay sayfası açılıyor — favorilerdeki "Kütüphanemde Olmayanlar"
/// bölümüyle aynı yol; her ikisinde de dokunma detay açar, doğrudan oynatmaz.
/// Eşleşme yoksa afiş TMDB'de başlığa göre aranıyor; yine de bulunamazsa kart
/// yalnızca durumu gösterir, açacak bir sayfa yok.
struct TorrentSnapshotCard: View {
    let hit: ZyMovieHit
    var settings: AppSettings?
    let onOpen: (RemoteTitle) -> Void

    @State private var fallbackPosterURL: URL?

    var body: some View {
        let titleText = hit.remoteTitle?.title ?? hit.rssTitle
        let card = PosterCard(
            title: titleText,
            subtitle: "",
            isFinished: WatchFlagsStore.shared.isFinished(hit.rssLink),
            watchlisted: WatchFlagsStore.shared.isWantToWatch(hit.rssLink),
            posterURL: hit.remoteTitle?.posterURL ?? fallbackPosterURL
        )
        Group {
            if let remote = hit.remoteTitle {
                Button { onOpen(remote) } label: { card }
                    .buttonStyle(.plain)
            } else {
                card
            }
        }
        .task(id: hit.id) {
            guard hit.remoteTitle == nil, let settings else { return }
            fallbackPosterURL = await tmdbPosterURL(forTitle: titleText, settings: settings)
        }
        .contextMenu {
            let watched = WatchFlagsStore.shared.isFinished(hit.rssLink)
            Button(watched ? "İzlemedim olarak işaretle" : "İzledim") {
                WatchFlagsStore.shared.setFinished(hit.rssLink, !watched, snapshot: .torrent(hit))
            }
            let listed = WatchFlagsStore.shared.isWantToWatch(hit.rssLink)
            Button(listed ? "İzleyeceklerimden çıkar" : "İzleyeceğim") {
                WatchFlagsStore.shared.setWantToWatch(hit.rssLink, !listed, snapshot: .torrent(hit))
            }
        }
    }
}

/// Elde afiş yoksa TMDB'de başlığa göre arayıp ilk sonucun afişini dener.
/// Gerçek bir IMDb eşleştirmesi değil (o, kaynak sayfasını yeniden açıp
/// IMDb kimliğini taramayı gerektirirdi) ama aynı sonucu veriyor: ZyStream'in
/// kendi taramasının vermediği bir afiş, TMDB'den başlık üzerinden geliyor.
private func tmdbPosterURL(forTitle title: String, settings: AppSettings) async -> URL? {
    guard settings.hasTMDBToken else { return nil }
    let client = TMDBClient(token: settings.tmdbToken, language: settings.metadataLanguage)
    guard let results = try? await client.searchMulti(query: title),
          let best = results.first, let remote = RemoteTitle(multi: best) else { return nil }
    return remote.posterURL
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

