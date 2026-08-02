import SwiftUI
import AppKit

/// Where the detail pane is pointed, if anywhere.
enum DetailRoute: Hashable {
    case movie(UUID)
    case series(String)
    /// A title that only exists on TMDB — an In Cinemas film or a search hit.
    /// It carries the whole value because it has no home in the library to look
    /// it back up from.
    case remote(RemoteTitle)
    /// An actor or director, with everything they worked on.
    case person(PersonRef)
    /// A ZyStream title's detail page.
    case stream(StreamHit)
    /// A category genre filter page.
    case genre(CategoryGenre)
}

extension MatchTarget: Identifiable {
    var id: String {
        switch self {
        case .movie(let item): "movie-\(item.id)"
        case .series(let key, _): "series-\(key)"
        }
    }
}

/// Top-level shell: source sidebar on the left, content on the right, and the
/// player taking over the whole window while something is playing.
struct RootView: View {
    @Bindable var player: PlayerModel
    let library: LibraryStore
    let smb: SMBStore
    let drive: GoogleDriveStore
    let torrents: TorrentStore
    let streamer: TorrentStreamer
    @Bindable var cinema: CinemaStore
    @Bindable var appleTV: AppleTVStore
    /// Netflix / Amazon Prime rafları için TMDB katalogları.
    @Bindable var providers: StreamingProviderStore
    @Bindable var settings: AppSettings
    let iptv: IPTVStore

    enum GamepadFocusZone {
        case sidebar
        case content
    }

    @State private var focusZone: GamepadFocusZone = .sidebar
    @State private var focusedPosterIndex: Int = 0
    /// Kumandanın seçim tuşu sayacı. Ekranlar bunu izleyip kendi listelerinden
    /// doğru öğeyi açar — hangi içeriğin göründüğünü (arama süzgeci, sıralama)
    /// buradan bilmek mümkün değil.
    @State private var gamepadSelectTick = 0
    /// Bir detay ekranı açıkken kumanda oraya sürer: kenar çubuğu ve poster
    /// ızgarası artık görünmüyor, yön tuşlarının bölüm ve kalite listelerine
    /// gitmesi gerekiyor.
    @State private var detailFocusIndex = 0
    @State private var detailSelectTick = 0
    /// Sezon değişimi: sağa basınca artar, sola basınca azalır. Hangi sezona
    /// denk düştüğünü ekran kendi listesinden bulur.
    @State private var detailSeasonStep = 0
    @State private var selection: SidebarItem = .home
    @State private var searchText = ""
    @State private var route: DetailRoute?
    @State private var remoteSearch = RemoteSearchStore()
    @State private var streamStore = ZyStreamStore()
    @State private var youtubeStore = YouTubeStore()
    @State private var resumeStore = PlaybackResumeStore()
    @State private var bollywood = BollywoodStore()
    @State private var zyMovieStore = ZyMovieStore()
    @State private var matchTarget: MatchTarget?
    @State private var keyMonitor = RootKeyMonitor()
    @State private var isTrailerLoading = false
    @State private var trailerMessage: String?
    @State private var showSubtitleSearch = false
    /// Bölüm listesi açılan IPTV dizisi.
    @State private var iptvSeries: IPTVSeries?
    /// Canlı yayın izlenirken oynatıcıdaki kanal listesini besleyen durum:
    /// kanal hangi listeden açıldıysa o liste, ve açık olan kanal.
    @State private var iptvChannelList: [IPTVChannel] = []
    @State private var iptvCurrentChannel: IPTVChannel?
    /// Drives hiding the window toolbar only in fullscreen (where it shows as a
    /// grey strip), while keeping it — and the traffic-light buttons — in windowed
    /// mode.
    @State private var isFullscreen = false

    var body: some View {
        Group {
            if player.currentURL != nil {
                PlayerView(
                    model: player,
                    settings: settings,
                    onClose: closePlayer,
                    onSearchSubtitles: { showSubtitleSearch = true },
                    onPreviousEpisode: adjacentEpisode(offset: -1).map { episode in
                        { play(episode) }
                    },
                    onNextEpisode: adjacentEpisode(offset: 1).map { episode in
                        { play(episode) }
                    },
                    episodes: playerEpisodes,
                    channels: playerChannels
                )
            } else {
                NavigationSplitView {
                    Sidebar(
                        selection: $selection,
                        isSidebarActive: focusZone == .sidebar,
                        scheme: settings.colorScheme,
                        onSelect: selectFromSidebar
                    )
                    .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 320)
                } detail: {
                    detailPane
                        .background(AppTheme.background(settings.colorScheme).ignoresSafeArea())
                }
                // Kills the blue focus ring that AppKit draws around the sidebar
                // toggle button in the toolbar. Painting the window itself in the
                // gradient's top colour means the transparent toolbar strip blends
                // into the content in fullscreen instead of showing macOS grey.
                .focusEffectDisabled()
                .background(WindowConfigurator(
                    backgroundColor: AppTheme.windowTopColor(settings.colorScheme),
                    isFullscreen: isFullscreen
                ))
            }
        }
        // Streaming-site resolution runs over whatever is on screen (the ZyStream
        // page or the global search), so its overlay and episode sheet live here
        // rather than inside one view.
        .overlay {
            if player.currentURL == nil
                && (streamStore.resolvingID != nil || streamStore.isLoadingDetails) {
                StreamResolvingOverlay()
            }
        }
        .sheet(isPresented: Binding(
            get: { streamStore.activeDetails != nil },
            set: { if !$0 { streamStore.closeDetails() } }
        )) {
            if let details = streamStore.activeDetails {
                StreamEpisodePicker(details: details, store: streamStore, resume: resumeStore)
            }
        }
        .overlay(alignment: .top) {
            if GamepadManager.shared.showConnectionToast {
                HStack(spacing: 8) {
                    Image(systemName: "gamecontroller.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.cyan)
                    Text(GamepadManager.shared.toastMessage)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.cyan.opacity(0.4), lineWidth: 1))
                .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
                .padding(.top, 40)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if GamepadManager.shared.isConnected && player.currentURL == nil {
                GamepadLegendHUD()
                    .padding(20)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .onAppear {
            NSApp.activate(ignoringOtherApps: true)
            isFullscreen = NSApp.keyWindow?.styleMask.contains(.fullScreen) ?? false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                NSApp.keyWindow?.makeFirstResponder(nil)
            }
            let handleBack = {
                // En üstteki katman önce kapanır. Altyazı paneli oynatıcının
                // üstünde durur; eskiden en sonda sınandığı için oynatıcı
                // açıkken hiç sırası gelmiyor, panel Escape'e yanıt vermiyordu.
                if showSubtitleSearch {
                    showSubtitleSearch = false
                } else if player.currentURL != nil {
                    // Player handles its own Escape
                } else if streamStore.activeDetails != nil {
                    streamStore.closeDetails()
                } else if route != nil {
                    route = nil
                } else if !searchText.isEmpty {
                    searchText = ""
                } else if matchTarget != nil {
                    matchTarget = nil
                }
            }
            BluetoothRemoteManager.shared.startGlobal(
                onGlobalBack: handleBack,
                onGlobalSearch: { searchText = "" }
            )
            GamepadManager.shared.start(
                onGlobalBack: handleBack,
                onGlobalSearch: { searchText = "" }
            )
            
            let sidebarItems = SidebarItem.allCases
            GamepadManager.shared.onNavigateDown = {
                if route != nil { detailFocusIndex += 1; return }
                if focusZone == .sidebar {
                    if let idx = sidebarItems.firstIndex(of: selection), idx < sidebarItems.count - 1 {
                        selection = sidebarItems[idx + 1]
                        selectFromSidebar(selection)
                    }
                } else if focusZone == .content {
                    withAnimation(.easeOut(duration: 0.12)) {
                        focusedPosterIndex += 10
                    }
                }
            }
            GamepadManager.shared.onNavigateUp = {
                if route != nil { detailFocusIndex = max(0, detailFocusIndex - 1); return }
                if focusZone == .sidebar {
                    if let idx = sidebarItems.firstIndex(of: selection), idx > 0 {
                        selection = sidebarItems[idx - 1]
                        selectFromSidebar(selection)
                    }
                } else if focusZone == .content {
                    if focusedPosterIndex >= 10 {
                        withAnimation(.easeOut(duration: 0.12)) {
                            focusedPosterIndex -= 10
                        }
                    } else {
                        withAnimation(.easeOut(duration: 0.15)) {
                            focusZone = .sidebar
                        }
                    }
                }
            }
            GamepadManager.shared.onNavigateRight = {
                if route != nil { detailSeasonStep += 1; return }
                if focusZone == .sidebar {
                    // İmleci olmayan ekranlarda içerik alanına geçilmez: hiçbir
                    // kart vurgulanmadığı için kumanda kaybolmuş gibi olur ve
                    // seçim tuşu da bir şey açmaz. Kenar çubuğunda kalınır.
                    guard supportsGamepadGrid else { return }
                    withAnimation(.easeOut(duration: 0.15)) {
                        focusZone = .content
                        focusedPosterIndex = 0
                    }
                } else if focusZone == .content {
                    withAnimation(.easeOut(duration: 0.12)) {
                        focusedPosterIndex += 1
                    }
                }
            }
            GamepadManager.shared.onNavigateLeft = {
                if route != nil { detailSeasonStep -= 1; return }
                if focusZone == .content {
                    if focusedPosterIndex % 10 == 0 || focusedPosterIndex == 0 {
                        withAnimation(.easeOut(duration: 0.15)) {
                            focusZone = .sidebar
                        }
                    } else {
                        withAnimation(.easeOut(duration: 0.12)) {
                            focusedPosterIndex -= 1
                        }
                    }
                }
            }
            GamepadManager.shared.onSelectKey = {
                if route != nil { detailSelectTick += 1; return }
                if focusZone == .sidebar {
                    selectFromSidebar(selection)
                } else if focusZone == .content {
                    switch selection {
                    case .movies:
                        if focusedPosterIndex >= 0 && focusedPosterIndex < library.movies.count {
                            actions.selectItem(library.movies[focusedPosterIndex])
                        }
                    case .shows:
                        if focusedPosterIndex >= 0 && focusedPosterIndex < library.shows.count {
                            actions.selectSeries(library.shows[focusedPosterIndex])
                        }
                    case .appleTV:
                        if focusedPosterIndex >= 0 && focusedPosterIndex < appleTV.movies.count {
                            actions.selectRemote(appleTV.movies[focusedPosterIndex])
                        }
                    case .bollywood:
                        if focusedPosterIndex >= 0 && focusedPosterIndex < bollywood.all.count {
                            actions.selectRemote(bollywood.all[focusedPosterIndex])
                        }
                    default:
                        // Ekran kendi listesinden seçer: burada hangi içeriğin
                        // göründüğü bilinmiyor (arama süzgeci listeyi değiştirir),
                        // indeksle tahmin etmek yanlış içeriği açardı.
                        gamepadSelectTick += 1
                    }
                }
            }
            GamepadManager.shared.onShoulderLeft = {
                withAnimation(.spring(duration: 0.2)) {
                    focusZone = .sidebar
                }
            }
            GamepadManager.shared.onShoulderRight = {
                guard supportsGamepadGrid else { return }
                withAnimation(.spring(duration: 0.2)) {
                    focusZone = .content
                    focusedPosterIndex = 0
                }
            }
            keyMonitor.start(onEscape: handleBack)
        }
        .onDisappear {
            keyMonitor.stop()
        }
        .onChange(of: route) { _, _ in
            // Yeni bir detay ekranı önceki ekranın imlecini miras almasın.
            detailFocusIndex = 0
            detailSeasonStep = 0
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in
            isFullscreen = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in
            isFullscreen = false
        }
        .onChange(of: selection) { route = nil }
        // Fragmanların yanında YouTube arama sonuçları da bu uyarıyı kullanıyor.
        .alert("Oynatma", isPresented: Binding(
            get: { trailerMessage != nil },
            set: { if !$0 { trailerMessage = nil } }
        )) {
            Button("Tamam") { trailerMessage = nil }
        } message: {
            Text(trailerMessage ?? "")
        }
        .sheet(item: $matchTarget) { target in
            MatchPickerView(
                target: target,
                library: library,
                settings: settings,
                onDone: { matchTarget = nil }
            )
        }
        .sheet(item: $iptvSeries) { series in
            IPTVEpisodePicker(
                series: series, store: iptv,
                onPlay: { playIPTVEpisode($0, seriesName: series.name) },
                onClose: { iptvSeries = nil }
            )
        }
        .sheet(isPresented: $showSubtitleSearch) {
            SubtitleSearchPanel(
                model: player,
                library: library,
                settings: settings,
                item: player.currentURL.flatMap { library.item(for: $0) },
                initialQuery: subtitleQuery.title,
                season: subtitleQuery.season,
                episode: subtitleQuery.episode,
                onDone: { showSubtitleSearch = false }
            )
            // Panel açıkken oynatıcının tuş kısayolları susar: burada yazılan
            // backspace harf siler, boşluk boşluk yazar — oynatmaya karışmaz.
            .onAppear { KeyboardContext.isPanelOpen = true }
            .onDisappear { KeyboardContext.isPanelOpen = false }
        }
        .onAppear {
            // Progress is reported during playback, not only on close, so a
            // hard quit still resumes where the user left off. A ZyStream or
            // torrent stream carries a stable resume key (its media URL is
            // ephemeral); a library file has none and resumes by its URL.
            player.onProgress = { url, position, duration in
                if let key = player.currentResumeKey {
                    resumeStore.update(key: key, position: position, duration: duration,
                                       subtitleLabel: player.currentSubtitleLabel)
                } else if let item = library.item(for: url) {
                    library.updateProgress(for: item, position: position, duration: duration)
                }
            }
            player.applySubtitleStyle(settings.subtitleStyle)
            // A resolved streaming-site URL plays like any network file — the
            // Referer/User-Agent headers ride along the same way Drive's bearer
            // token does.
            streamStore.onPlay = { resolved, launch in
                player.open(resolved.url, title: launch.title, resumeAt: launch.resumeAt,
                            httpHeaders: resolved.headers, subtitles: resolved.subtitles,
                            resumeKey: launch.resumeKey, preferredSubtitle: launch.subtitleLabel)
            }
            // Provider lookup reads the live settings, so editing a source's URL
            // takes effect on the next search or play without a relaunch.
            streamStore.lookup = { settings.streamProvider(id: $0) }
            streamStore.resume = resumeStore
        }
        .onChange(of: settings.subtitleStyle) {
            player.applySubtitleStyle(settings.subtitleStyle)
        }
    }

    private var actions: LibraryActions {
        LibraryActions(
            selectItem: { route = .movie($0.id) },
            selectSeries: { route = .series($0.id) },
            selectRemote: { route = .remote($0) },
            selectCategory: { route = .genre($0) },
            play: play,
            showAll: { selection = $0 },
            markWatched: { library.markWatched($0, watched: $1) },
            setWatchlist: { library.setWatchlist($0, $1) },
            markSeriesWatched: { library.markSeriesWatched(seriesKey: $0.id, watched: $1) },
            setSeriesWatchlist: { library.setSeriesWatchlist(seriesKey: $0.id, $1) },
            resumeTorrent: resumeTorrent,
            // Bir bölümün kendi detay sayfası yok: dizisinin sayfası açılır,
            // kaldığı bölüm listenin içinde işaretli durur.
            openDetail: { item in
                if item.kind == .episode, let key = item.seriesKey {
                    route = .series(key)
                } else {
                    route = .movie(item.id)
                }
            },
            openResumeDetail: { point in
                if let hit = point.streamHit {
                    route = .stream(hit)
                } else if let remote = point.remoteTitle {
                    route = .remote(remote)
                }
            }
        )
    }

    /// A sidebar click always lands on the browser, even when it is the row that
    /// is already selected — that is how "Ana Ekran" doubles as a back button.
    /// Kumanda imlecinin gezinebildiği ekranlar: içerikleri tek bir düz ızgara.
    ///
    /// Ötekiler (ana ekran, favoriler, ZyStream) birden çok bölümden oluşuyor —
    /// raflar, "Diziler"/"Filmler" başlıkları — ve tek bir indeksle
    /// modellenemiyor: aynı sayı iki ızgarada birden kart vurgular, seçimin
    /// hangisine gideceği belirsiz kalır. O ekranlarda imleç hiç çizilmiyor.
    private var supportsGamepadGrid: Bool {
        switch selection {
        case .movies, .shows, .appleTV, .bollywood, .zyMovie: true
        default: false
        }
    }

    private func selectFromSidebar(_ item: SidebarItem) {
        selection = item
        route = nil
        searchText = ""
    }

    @ViewBuilder
    private var detailPane: some View {
        if let route {
            routedDetail(route)
        } else {
            // Search lives in the content, not the window toolbar: the system
            // `.searchable` field sits in a toolbar strip that macOS repaints grey
            // in fullscreen no matter what `.toolbarBackground` says. A custom
            // field on the left, over the app's own gradient, looks identical in
            // both windowed and fullscreen.
            VStack(spacing: 0) {
                HStack {
                    SearchField(text: $searchText)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 22)
                .padding(.top, 14)
                .padding(.bottom, 8)

                browser
            }
            // navigationTitle stays (its text is hidden by the transparent title
            // bar) purely so the window keeps a toolbar — which gives the title bar
            // its height and keeps the traffic-light buttons in place. Search lives
            // in the content now, and WindowConfigurator hides this toolbar only in
            // fullscreen, where it would otherwise show as a grey strip.
            .navigationTitle(selection.title)
        }
    }

    @ViewBuilder
    private func routedDetail(_ route: DetailRoute) -> some View {
        switch route {
        case .movie(let id):
            if let item = library.items.first(where: { $0.id == id }) {
                MovieDetailView(
                    item: item,
                    state: library.state(for: item),
                    library: library,
                    settings: settings,
                    onPlay: play,
                    onBack: { self.route = nil },
                    onEditMatch: { matchTarget = .movie(item) },
                    onTrailer: { playTrailer(movieID: item.tmdbID, title: item.title) },
                    onSelectPerson: { self.route = .person($0) },
                    isTrailerLoading: isTrailerLoading
                )
            }
        case .series(let key):
            if let series = library.shows.first(where: { $0.id == key }) {
                SeriesDetailView(
                    series: series,
                    library: library,
                    settings: settings,
                    streamer: streamer,
                    onPlay: play,
                    onBack: { self.route = nil },
                    onEditMatch: {
                        matchTarget = .series(key: series.id, name: series.displayName)
                    },
                    onTrailer: {
                        playTrailer(tvID: series.meta?.tmdbID, title: series.displayName)
                    },
                    onSelectPerson: { self.route = .person($0) },
                    onStreamTorrent: streamTorrent,
                    onDownloadTorrent: downloadTorrent,
                    isTrailerLoading: isTrailerLoading
                )
            }
        case .remote(let title):
            RemoteDetailView(
                title: title,
                library: library,
                settings: settings,
                streamer: streamer,
                onBack: { self.route = nil },
                onPlay: play,
                onOpenSeries: { self.route = .series($0) },
                onStreamTorrent: streamTorrent,
                onDownloadTorrent: downloadTorrent,
                onSelectPerson: { self.route = .person($0) },
                onTrailer: {
                    switch title.kind {
                    case .movie: playTrailer(movieID: title.tmdbID, title: title.title)
                    case .tv:    playTrailer(tvID: title.tmdbID, title: title.title)
                    }
                },
                isTrailerLoading: isTrailerLoading,
                onOpenStream: { self.route = .stream($0) },
                gamepadIndex: detailFocusIndex,
                gamepadSelectTick: detailSelectTick,
                gamepadSeasonStep: detailSeasonStep
            )
        case .person(let person):
            PersonDetailView(
                person: person,
                library: library,
                settings: settings,
                onBack: { self.route = nil },
                onSelectTitle: { self.route = .remote($0) }
            )
        case .stream(let hit):
            StreamDetailView(
                hit: hit,
                store: streamStore,
                library: library,
                settings: settings,
                resume: resumeStore,
                onBack: { self.route = nil },
                onTrailer: { title in
                    switch title.kind {
                    case .movie: playTrailer(movieID: title.tmdbID, title: title.title)
                    case .tv:    playTrailer(tvID: title.tmdbID, title: title.title)
                    }
                },
                isTrailerLoading: isTrailerLoading
            )
        case .genre(let genre):
            CategoryDetailView(
                genre: genre,
                library: library,
                settings: settings,
                actions: actions,
                onBack: { self.route = nil }
            )
        }
    }

    @ViewBuilder
    private var browser: some View {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            SearchResultsView(
                library: library,
                remote: remoteSearch,
                stream: streamStore,
                youtube: youtubeStore,
                settings: settings,
                query: query,
                actions: actions,
                resume: resumeStore,
                onSelectRemote: { route = .remote($0) },
                onSelectPerson: { route = .person($0) },
                onSelectStream: { route = .stream($0) },
                onPlayYouTube: playYouTube,
                    iptv: iptv,
                    onPlayIPTVChannel: playChannel,
                    onPlayIPTVMovie: playIPTVMovie,
                    onOpenIPTVSeries: { iptvSeries = $0 }
            )
        } else {
            switch selection {
            case .home:      HomeView(
                                 library: library,
                                 cinema: cinema,
                                 appleTV: appleTV,
                                 providers: providers,
                                 settings: settings,
                                 actions: actions,
                                 stream: streamStore,
                                 resume: resumeStore,
                                 onOpenStream: { route = .stream($0) }
                             )
            case .movies:    MoviesView(library: library, actions: actions, selectedIndex: focusZone == .content ? focusedPosterIndex : -1)
            case .shows:     ShowsView(library: library, actions: actions, selectedIndex: focusZone == .content ? focusedPosterIndex : -1)
            case .favorites: FavoritesView(library: library, actions: actions, stream: streamStore,
                                           onSelectStream: { route = .stream($0) },
                                           iptv: iptv,
                                           onPlayIPTVFavorite: playIPTVFavorite)
            case .appleTV:   AppleTVView(library: library, appleTV: appleTV, actions: actions, selectedIndex: focusZone == .content ? focusedPosterIndex : -1)
            case .bollywood: BollywoodView(library: library, store: bollywood,
                                           settings: settings, actions: actions, selectedIndex: focusZone == .content ? focusedPosterIndex : -1)
            case .zyMovie:   ZyMovieView(library: library, store: zyMovieStore,
                                         settings: settings, player: player, streamer: streamer, torrents: torrents, selectedIndex: focusZone == .content ? focusedPosterIndex : -1, selectTick: gamepadSelectTick, onOpenRemoteTitle: { route = .remote($0) })
            case .downloads: DownloadsView(library: library, torrents: torrents, settings: settings)
            case .settings:  SettingsView(library: library, smb: smb, drive: drive,
                                          torrents: torrents, settings: settings,
                                          resume: resumeStore, iptv: iptv)
            case .stream:    ZyStreamView(store: streamStore, library: library,
                                          resume: resumeStore, settings: settings,
                                          onOpen: { route = .stream($0) })
            case .iptv:      IPTVView(
                                 store: iptv, settings: settings,
                                 onPlayChannel: playChannel,
                                 onPlayMovie: playIPTVMovie,
                                 onOpenSeries: { iptvSeries = $0 }
                             )
            case .music:     MusicView()
            case .games:     GamesView()
            }
        }
    }

    private func play(_ item: MediaItem) {
        let title = playerTitle(for: item)
        let resume = library.state(for: item)?.position ?? 0

        guard item.source == .googleDrive else {
            player.open(item.url, title: title, resumeAt: resume)
            return
        }
        // Drive streams need a fresh bearer token on every open.
        Task {
            guard let token = await drive.currentAccessToken() else {
                drive.statusMessage = "Drive oturumu geçersiz, yeniden bağlanın."
                return
            }
            player.open(
                item.url, title: title, resumeAt: resume,
                httpHeaders: ["Authorization": "Bearer \(token)"]
            )
        }
    }

    /// Oynayan bölümün serisindeki komşusu: `-1` önceki, `+1` sonraki.
    ///
    /// Bölümler `library.shows` içinde sezon/bölüm sırasına dizili geliyor, o
    /// yüzden sezon sınırını da kendiliğinden aşıyor: bir sezonun son bölümünden
    /// sonraki, bir sonraki sezonun ilki oluyor. Film oynuyorsa ya da serinin
    /// ucundaysak nil döner ve düğme sönük görünür.
    private func adjacentEpisode(offset: Int) -> MediaItem? {
        guard let url = player.currentURL,
              let current = library.item(for: url), current.kind == .episode,
              let show = library.show(forSeriesKey: current.seriesKey),
              let index = show.episodes.firstIndex(where: { $0.id == current.id })
        else { return nil }
        let target = index + offset
        guard show.episodes.indices.contains(target) else { return nil }
        return show.episodes[target]
    }

    /// Player'ın sağ üstündeki bölüm seçicinin listesi — oynayan içerik bir dizi
    /// bölümü değilse nil.
    ///
    /// İki kaynak var: kütüphanedeki bir dizi ile bir akış sitesinin bölüm
    /// listesi. Akış tarafında oynayan bölüm devam anahtarından (sayfa adresi)
    /// bulunuyor; anahtar listedeki hiçbir bölümle eşleşmiyorsa oynayan şey o
    /// dizi değildir (film ya da torrent) ve seçici çıkmaz.
    private var playerEpisodes: PlayerEpisodeList? {
        if let url = player.currentURL,
           let current = library.item(for: url), current.kind == .episode,
           let show = library.show(forSeriesKey: current.seriesKey) {
            let entries = show.episodes.compactMap { item -> PlayerEpisodeList.Entry? in
                guard let season = item.season, let episode = item.episode else { return nil }
                return PlayerEpisodeList.Entry(
                    id: item.id.uuidString,
                    season: season,
                    episode: episode,
                    title: item.title,
                    isCurrent: item.id == current.id,
                    isWatched: library.state(for: item)?.isFinished ?? false,
                    play: { play(item) }
                )
            }
            guard !entries.isEmpty else { return nil }
            return PlayerEpisodeList(showTitle: show.displayName, entries: entries)
        }

        if let details = streamStore.playingDetails,
           let key = player.currentResumeKey,
           details.episodes.contains(where: { $0.pageURL == key }) {
            let entries = details.episodes.map { episode in
                PlayerEpisodeList.Entry(
                    id: episode.id,
                    season: episode.season,
                    episode: episode.episode,
                    title: episode.title,
                    isCurrent: episode.pageURL == key,
                    // Akış bölümlerinin izlenme durumu devam noktalarında duruyor.
                    isWatched: resumeStore.point(forKey: episode.pageURL)?.isFinished ?? false,
                    play: { streamStore.playEpisode(episode, from: details) }
                )
            }
            return PlayerEpisodeList(showTitle: details.hit.title, entries: entries)
        }
        
        if let hit = zyMovieStore.playingHit, streamer.activeHash == hit.rssLink, !zyMovieStore.playingFiles.isEmpty {
            let entries = zyMovieStore.playingFiles.map { file in
                let seasonStr = extractSeason(from: hit.rssTitle)
                let epNumber = extractEpisodeNumber(from: file.name) ?? (file.index + 1)
                
                return PlayerEpisodeList.Entry(
                    id: "\(hit.rssLink)-\(file.index)",
                    season: seasonStr != nil ? (Int(seasonStr!) ?? 1) : 1,
                    episode: epNumber,
                    title: extractEpisodeTitle(from: file.name) ?? "Bölüm \(epNumber)",
                    isCurrent: streamer.activeFileIndex == file.index,
                    isWatched: false,
                    play: {
                        let title = hit.remoteTitle?.title ?? hit.rssTitle
                        let option = TorrentOption(
                            id: hit.rssLink,
                            quality: "RSS",
                            detail: "TurkTorrent",
                            seeds: 0,
                            peers: 0,
                            provider: "TurkTorrent",
                            link: hit.rssLink,
                            fileIndex: file.index
                        )
                        // Kararlı kimlik: akış adresi her oynatmada değişiyor
                        // (yerel bağlantı noktası) — altyazı seçimi ona
                        // bağlanırsa bir daha hatırlanmaz.
                        let key = "zymovie:\(hit.rssLink)#\(file.index)"
                        streamer.start(option, title: title) { url, _ in
                            player.open(url, title: title,
                                        resumeAt: resumeStore.position(forKey: key),
                                        resumeKey: key,
                                        preferredSubtitle: resumeStore.point(forKey: key)?.subtitleLabel)
                        }
                    }
                )
            }
            let showTitle = hit.remoteTitle?.title ?? hit.rssTitle
            return PlayerEpisodeList(showTitle: showTitle, entries: entries)
        }

        return nil
    }
    
    private func extractSeason(from string: String) -> String? {
        if let range = string.range(of: "S(\\d+)", options: .regularExpression) {
            let match = string[range]
            return String(match.dropFirst())
        }
        return nil
    }
    
    private func extractEpisodeNumber(from string: String) -> Int? {
        if let range = string.range(of: "E(\\d+)", options: .regularExpression) {
            let match = string[range]
            return Int(match.dropFirst())
        }
        return nil
    }
    
    private func extractEpisodeTitle(from string: String) -> String? {
        // e.g., Extract base name
        let url = URL(fileURLWithPath: string)
        return url.deletingPathExtension().lastPathComponent
    }

    /// "Severance · S2B7 · Chikhai Bardo" for episodes, the title for movies.
    private func playerTitle(for item: MediaItem) -> String {
        guard item.kind == .episode else { return item.title }
        let show = library.meta(forSeriesKey: item.seriesKey)?.name ?? item.showTitle ?? ""
        let code = item.subtitleLine
        return [show, code, item.title].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// Seeds the OpenSubtitles search from whatever is playing. Shows search by
    /// series name plus season/episode; movies by title.
    private var subtitleQuery: (title: String, season: Int?, episode: Int?) {
        guard let url = player.currentURL, let item = library.item(for: url) else {
            return (player.currentTitle, nil, nil)
        }
        if item.kind == .episode {
            let show = library.meta(forSeriesKey: item.seriesKey)?.name
                ?? item.showTitle
                ?? item.title
            return (show, item.season, item.episode)
        }
        return (item.title, nil, nil)
    }

    /// Arama sonucundan seçilen YouTube videosunu oynatır.
    ///
    /// Fragman yolundan ayrı: bu tam bir film/bölüm olabildiği için devam noktası
    /// kaydediliyor ve aynı video yeniden açıldığında kaldığı yerden başlıyor.
    private func playYouTube(_ video: YouTubeVideo) {
        guard let url = video.watchURL else { return }
        // Adresi yt-dlp çözüyor; kurulu değilse mpv sessizce siyah ekranda kalırdı.
        guard YouTubePlaybackCheck.isToolInstalled else {
            trailerMessage = "YouTube videosu için yt-dlp gerekiyor. Terminal'de "
                + "`brew install yt-dlp` çalıştırın."
            return
        }
        let key = YouTubeStore.resumeKey(for: video)
        resumeStore.begin(ResumePoint(
            id: key, kind: .youtube, title: video.title,
            posterURLString: video.thumbnailURL?.absoluteString
        ))
        player.openYouTube(url, title: video.title,
                           resumeAt: resumeStore.position(forKey: key), resumeKey: key)
    }

    /// Looks the trailer up on TMDB and hands the YouTube URL to mpv, which
    /// resolves it through yt-dlp.
    private func playTrailer(movieID: Int? = nil, tvID: Int? = nil, title: String) {
        guard settings.hasTMDBToken else { return }
        // Fragmanın adresini yt-dlp çözüyor. Kurulu değilse mpv sessizce hiçbir
        // şey açmıyor — sebebini söylemek, boş boş beklemekten iyi.
        guard YouTubePlaybackCheck.isToolInstalled else {
            trailerMessage = "Fragman için yt-dlp gerekli. `brew install yt-dlp` ile kurun."
            return
        }
        isTrailerLoading = true
        Task {
            defer { isTrailerLoading = false }
            let client = TMDBClient(token: settings.tmdbToken, language: settings.metadataLanguage)
            let videos: [VideoResult]
            do {
                if let movieID {
                    videos = try await client.trailers(movieID: movieID)
                } else if let tvID {
                    videos = try await client.trailers(tvID: tvID)
                } else {
                    return
                }
            } catch {
                trailerMessage = "Fragman alınamadı."
                return
            }
            guard let url = videos.compactMap(\.youtubeURL).first else {
                trailerMessage = "Bu içerik için fragman yok."
                return
            }
            player.openTrailer(url, title: "\(title) — Fragman")
        }
    }

    // MARK: - IPTV

    /// Canlı yayın. Kanal listesi de veriliyor; oynatıcıdaki kanal seçici
    /// bunun üzerinden kuruluyor.
    private func playChannel(_ channel: IPTVChannel, _ list: [IPTVChannel]) {
        guard let url = iptv.url(for: channel) else { return }
        iptvChannelList = list
        iptvCurrentChannel = channel
        // Kararlı kimlik veriliyor: altyazı seçimi ve eklenen altyazılar bu
        // anahtarla hatırlanıyor. Adresin kendisi anahtar olarak kullanılamaz —
        // içinde abonelik bilgisi geçiyor ve sağlayıcı değişince kayıt kopardı.
        player.open(url, title: channel.name, resumeKey: "iptv:live:\(channel.id)")
    }

    /// Favorilerden gelen IPTV içeriği. Dizi doğrudan oynatılamaz; katalogdaki
    /// karşılığı bulunup bölüm listesi açılıyor.
    private func playIPTVFavorite(_ favorite: IPTVFavorite) {
        switch favorite.kind {
        case .series:
            if let series = iptv.series(withID: favorite.streamID) { iptvSeries = series }
        case .channel:
            if let channel = iptv.channel(withID: favorite.streamID) {
                playChannel(channel, iptv.channels(categoryID: nil))
            } else if let url = iptv.url(for: favorite) {
                player.open(url, title: favorite.name,
                            resumeKey: "iptv:live:\(favorite.streamID)")
            }
        case .movie:
            guard let url = iptv.url(for: favorite) else { return }
            let key = "iptv:movie:\(favorite.streamID)"
            let title = IPTVNaming.split(favorite.name).name
            resumeStore.begin(ResumePoint(id: key, kind: .stream, title: title,
                                          posterURLString: favorite.iconURLString))
            player.open(url, title: title,
                        resumeAt: resumeStore.position(forKey: key), resumeKey: key,
                        preferredSubtitle: resumeStore.point(forKey: key)?.subtitleLabel)
        }
    }

    /// Oynatıcının kanal seçicisi. Yalnızca canlı yayın açıkken doluyor;
    /// film ya da dizi izlenirken seçici hiç görünmüyor.
    private var playerChannels: PlayerChannelList? {
        guard iptvCurrentChannel != nil, !iptvChannelList.isEmpty else { return nil }
        return PlayerChannelList(entries: iptvChannelList.map { channel in
            PlayerChannelList.Entry(
                id: channel.id,
                name: channel.name,
                isCurrent: channel.id == iptvCurrentChannel?.id,
                play: { playChannel(channel, iptvChannelList) }
            )
        })
    }

    private func playIPTVMovie(_ movie: IPTVMovie) {
        guard let url = iptv.url(for: movie) else { return }
        let key = "iptv:movie:\(movie.id)"
        let title = IPTVNaming.split(movie.name).name
        resumeStore.begin(ResumePoint(
            id: key, kind: .stream, title: title,
            posterURLString: movie.iconURLString
        ))
        player.open(url, title: title,
                    resumeAt: resumeStore.position(forKey: key), resumeKey: key,
                    preferredSubtitle: resumeStore.point(forKey: key)?.subtitleLabel)
    }

    private func playIPTVEpisode(_ episode: IPTVEpisode, seriesName: String) {
        guard let url = iptv.url(for: episode) else { return }
        iptvSeries = nil
        let key = "iptv:episode:\(episode.id)"
        let title = "\(IPTVNaming.split(seriesName).name) · S\(episode.season)B\(episode.episode)"
        resumeStore.begin(ResumePoint(id: key, kind: .stream, title: title))
        player.open(url, title: title,
                    resumeAt: resumeStore.position(forKey: key), resumeKey: key,
                    preferredSubtitle: resumeStore.point(forKey: key)?.subtitleLabel)
    }

    /// Streams a torrent instead of downloading it: the helper buffers a few
    /// megabytes, then the player opens the local HTTP URL it serves.
    private func streamTorrent(_ torrent: TorrentOption, title: String, posterURLString: String? = nil) {
        let displayTitle = "\(title) · \(torrent.label)"
        let key = "torrent:\(torrent.id)"
        // Remembered by infohash so re-picking the same release resumes, and so
        // the Downloads screen can offer the last one.
        // Torrent her zaman bir detay ekranından başlatılıyor; devam kartından
        // o sayfaya dönebilmek için yapımın kendisi de kaydediliyor. Aksi hâlde
        // elde yalnızca magnet kalıyor ve dönülecek bir sayfa olmuyor.
        let openTitle: RemoteTitle? = if case .remote(let remote) = route { remote } else { nil }
        resumeStore.begin(ResumePoint(
            id: key, kind: .torrent, title: displayTitle,
            posterURLString: posterURLString,
            magnet: torrent.link, fileIndex: torrent.fileIndex,
            remoteTitle: openTitle
        ))
        let resumeAt = resumeStore.position(forKey: key)
        // The film's own name beats the release filename mpv would otherwise get.
        streamer.start(torrent, title: title) { url, _ in
            player.open(url, title: displayTitle, resumeAt: resumeAt, resumeKey: key)
        }
    }

    /// Re-streams the last torrent the user watched, from where they left off.
    private func resumeTorrent(_ point: ResumePoint) {
        guard let magnet = point.magnet else { return }
        let torrent = TorrentOption(
            id: point.id.replacingOccurrences(of: "torrent:", with: ""),
            quality: "", detail: "", seeds: 0, peers: 0,
            provider: nil, link: magnet, fileIndex: point.fileIndex
        )
        let resumeAt = resumeStore.position(forKey: point.id)
        let subtitle = point.subtitleLabel
        streamer.start(torrent, title: point.title) { url, _ in
            player.open(url, title: point.title, resumeAt: resumeAt,
                        resumeKey: point.id, preferredSubtitle: subtitle)
        }
    }

    /// Downloads a torrent straight to the folder set in Settings, then opens the
    /// Downloads screen so the transfer is visible — no per-download folder prompt.
    private func downloadTorrent(_ torrent: TorrentOption, title: String) {
        Task {
            await torrents.add(torrent.link, library: library)
        }
        route = nil
        selection = .downloads
    }

    /// Saves progress before leaving the player and cleans download/cache if not favorited.
    private func closePlayer() {
        if let url = player.currentURL, let item = library.item(for: url) {
            library.updateProgress(for: item, position: player.position, duration: player.duration)
        }
        
        let activeHash = streamer.activeHash
        let activeTitle = player.currentTitle
        let playingHit = zyMovieStore.playingHit
        
        player.close()
        streamer.stop()
        // Kanal seçicisi yalnızca açık bir canlı yayına ait; oynatıcı
        // kapandığında sonraki içeriğe sarkmamalı.
        iptvCurrentChannel = nil
        iptvChannelList = []
        
        Task { @MainActor in
            let favs = zyMovieStore.favorites
            
            if let hit = playingHit {
                let isFav = favs.contains { $0.id == hit.id }
                if !isFav {
                    zyMovieStore.playingHit = nil
                    zyMovieStore.playingFiles = []
                }
            }
            
            // Clean torrent downloads in aria2 (`torrents`) that match the active stream / playing hit UNLESS favorited
            for download in torrents.downloads {
                let isFavorited = favs.contains { fav in
                    if let hash = activeHash, !hash.isEmpty, fav.rssLink.contains(hash) { return true }
                    if let hit = playingHit, fav.id == hit.id { return true }
                    if !download.name.isEmpty && !fav.rssTitle.isEmpty &&
                        (download.name.localizedCaseInsensitiveContains(fav.rssTitle) || fav.rssTitle.localizedCaseInsensitiveContains(download.name)) {
                        return true
                    }
                    return false
                }
                
                if !isFavorited {
                    let matchesClosed = (activeHash != nil && !activeHash!.isEmpty && download.id.contains(activeHash!)) ||
                                       (playingHit != nil && (download.name.localizedCaseInsensitiveContains(playingHit!.rssTitle) || download.id.contains(playingHit!.rssLink))) ||
                                       (!activeTitle.isEmpty && (download.name.localizedCaseInsensitiveContains(activeTitle) || activeTitle.localizedCaseInsensitiveContains(download.name)))
                    if matchesClosed {
                        await torrents.remove(download, deleteFiles: true, library: library)
                    }
                }
            }
        }
    }
}

/// Search looks in the library first and asks TMDB in parallel, so a title the
/// user does not own still turns up — with a detail screen of its own.
struct SearchResultsView: View {
    let library: LibraryStore
    let remote: RemoteSearchStore
    let stream: ZyStreamStore
    let youtube: YouTubeStore
    let settings: AppSettings
    let query: String
    let actions: LibraryActions
    let resume: PlaybackResumeStore
    let onSelectRemote: (RemoteTitle) -> Void
    let onSelectPerson: (PersonRef) -> Void
    let onSelectStream: (StreamHit) -> Void
    let onPlayYouTube: (YouTubeVideo) -> Void
    /// IPTV kataloğu — abonelik yoksa nil ve bölüm hiç çıkmıyor.
    var iptv: IPTVStore?
    var onPlayIPTVChannel: ((IPTVChannel, [IPTVChannel]) -> Void)?
    var onPlayIPTVMovie: ((IPTVMovie) -> Void)?
    var onOpenIPTVSeries: ((IPTVSeries) -> Void)?

    /// Aramaya karışan IPTV sonuçları. Katalog zaten bellekte olduğundan
    /// arama yerel: ağ isteği yok, sonuçlar anında çıkıyor.
    private var iptvHits: (channels: [IPTVChannel], movies: [IPTVMovie], series: [IPTVSeries]) {
        guard let iptv, iptv.isConfigured else { return ([], [], []) }
        return iptv.search(query)
    }

    /// Arama sonucundaki bir IPTV kartının sağ tık menüsü. Favori durumu
    /// depodan okunuyor: aynı içerik hem burada hem IP Tv bölümünde
    /// görünebiliyor, ikisinin de aynı şeyi göstermesi gerekiyor.
    @ViewBuilder
    private func iptvFavoriteButton(_ favorite: IPTVFavorite) -> some View {
        if let iptv {
            let isFavorite = iptv.isFavorite(favorite)
            Button(isFavorite ? "Favorilerden Çıkar" : "Favorilere Ekle",
                   systemImage: isFavorite ? "star.slash" : "star") {
                iptv.toggleFavorite(favorite)
            }
        }
    }

    var body: some View {
        let local = library.search(query)
        let found = remoteResults

        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                // People first when the query is clearly a name: their titles
                // are one click away, and a person match is a strong signal.
                if !remote.people.isEmpty, remote.query == query {
                    PeopleStrip(
                        title: "Kişiler",
                        count: remote.people.count,
                        people: remote.people,
                        onSelect: onSelectPerson
                    )
                }

                if !local.isEmpty {
                    SectionBlock(title: "Kütüphanemde", total: local.count, onShowAll: nil) {
                        ForEach(local) { item in
                            MediaCard(item: item, state: library.state(for: item), actions: actions)
                        }
                    }
                }

                if !found.isEmpty {
                    SectionBlock(title: "TMDB’de Bulunanlar", total: found.count, onShowAll: nil) {
                        ForEach(found) { title in
                            RemoteCard(
                                title: title,
                                isOwned: false,
                                onSelect: { onSelectRemote(title) }
                            )
                        }
                    }
                }

                // Titles the enabled streaming sites can play, badged with their
                // source. A section of its own rather than a badge on the TMDB
                // card: scraped titles carry no TMDB id to match on reliably.
                if !stream.hits.isEmpty {
                    SectionBlock(title: "ZyStream’de Bulunanlar", total: stream.hits.count,
                                 onShowAll: nil) {
                        ForEach(stream.hits) { hit in
                            StreamHitCard(hit: hit, store: stream, onOpen: onSelectStream, library: library)
                        }
                    }
                }

                // IPTV aboneliğindekiler. Üç tür tek bölümde toplanıyor ama
                // her kart hangi tür olduğunu rozetinde söylüyor: aynı ad hem
                // canlı kanal hem film olarak çıkabiliyor.
                if !iptvHits.channels.isEmpty || !iptvHits.movies.isEmpty
                    || !iptvHits.series.isEmpty {
                    let total = iptvHits.channels.count + iptvHits.movies.count
                        + iptvHits.series.count
                    SectionBlock(title: "IP Tv’de Bulunanlar", total: total,
                                 onShowAll: nil) {
                        ForEach(iptvHits.channels) { channel in
                            IPTVSearchCard(title: channel.name, imageURL: channel.iconURL,
                                           kindLabel: "Canlı yayın") {
                                onPlayIPTVChannel?(channel, iptvHits.channels)
                            }
                            .contextMenu {
                                iptvFavoriteButton(IPTVFavorite(
                                    kind: .channel, streamID: channel.id, name: channel.name,
                                    iconURLString: channel.iconURLString
                                ))
                            }
                        }
                        ForEach(iptvHits.movies) { movie in
                            IPTVSearchCard(title: movie.name, imageURL: movie.iconURL,
                                           kindLabel: "Film") {
                                onPlayIPTVMovie?(movie)
                            }
                            .contextMenu {
                                iptvFavoriteButton(IPTVFavorite(
                                    kind: .movie, streamID: movie.id, name: movie.name,
                                    iconURLString: movie.iconURLString,
                                    containerExtension: movie.containerExtension
                                ))
                            }
                        }
                        ForEach(iptvHits.series) { item in
                            IPTVSearchCard(title: item.name, imageURL: item.coverURL,
                                           kindLabel: "Dizi") {
                                onOpenIPTVSeries?(item)
                            }
                            .contextMenu {
                                iptvFavoriteButton(IPTVFavorite(
                                    kind: .series, streamID: item.id, name: item.name,
                                    iconURLString: item.coverURLString
                                ))
                            }
                        }
                    }
                }

                // YouTube yalnızca aramada çıkıyor: bazı diziler ve filmler
                // (resmi kanallardan) orada tam olarak var. Kartlar 16:9 olduğu
                // için satıra beş tane sığıyor, afiş raflarındaki on değil.
                if settings.youtubeSearchEnabled, !youtube.videos.isEmpty {
                    SectionBlock(title: "YouTube’da Bulunanlar", total: youtube.videos.count,
                                 onShowAll: nil, columns: 5, limit: 24) {
                        ForEach(youtube.videos) { video in
                            YouTubeCard(
                                video: video,
                                progress: resume.point(
                                    forKey: YouTubeStore.resumeKey(for: video)
                                )?.progress ?? 0,
                                onPlay: onPlayYouTube
                            )
                        }
                    }
                }

                if local.isEmpty && found.isEmpty && remote.people.isEmpty && stream.hits.isEmpty
                    && youtube.videos.isEmpty && iptvHits.channels.isEmpty
                    && iptvHits.movies.isEmpty && iptvHits.series.isEmpty {
                    if remote.isLoading || stream.isSearching || youtube.isSearching {
                        ProgressView("Aranıyor…")
                            .frame(maxWidth: .infinity)
                            .padding(.top, 60)
                    } else {
                        PlaceholderView(
                            title: "Sonuç yok",
                            detail: settings.hasTMDBToken
                                ? "‘\(query)’ için eşleşme bulunamadı."
                                : "‘\(query)’ kütüphanede yok. TMDB’de aramak için Ayarlar’dan jeton girin."
                        )
                        .padding(.top, 40)
                    }
                }
            }
            .padding(.vertical, 22)
        }
        // Debounced: `.task(id:)` cancels the pending sleep on every keystroke,
        // so only the query the user stopped on reaches TMDB.
        .task(id: query) {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await remote.search(query, settings: settings)
        }
        // The streaming sites are searched in parallel with TMDB, on their own
        // debounce, so a slow site never holds up the library/TMDB sections.
        // Keyed on `streamQuery`, not `query`: an IMDb id means nothing to a
        // scraper, so that search waits for TMDB to turn the id into a name.
        .task(id: streamQuery) {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await stream.search(streamQuery, providers: settings.enabledStreamProviders,
                                settings: settings)
        }
        // YouTube da kendi gecikmesiyle, diğerlerine paralel aranıyor. Anahtar
        // `id`'ye giriyor: ayarlardan kapatıldığı anda bu görev yeniden çalışıp
        // sonuçları temizliyor, açıldığında ise arama kutusuna dokunmadan geliyor.
        .task(id: "\(settings.youtubeSearchEnabled)-\(streamQuery)") {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await youtube.search(streamQuery, isEnabled: settings.youtubeSearchEnabled)
        }
    }

    /// Aramanın akış sitelerine giden hâli. Kullanıcı IMDb kimliği yazdıysa
    /// siteler kimliği tanımaz; TMDB kimliği bir başlığa çevirene kadar boş
    /// kalır, çevirince o başlıkla aranır.
    private var streamQuery: String {
        guard IMDbID.isIMDbQuery(query) else { return query }
        guard remote.query == query, let first = remote.results.first else { return "" }
        return first.title
    }

    /// TMDB rows the library already covers are dropped — they are in the first
    /// section already, with artwork and a play button.
    private var remoteResults: [RemoteTitle] {
        guard remote.query == query else { return [] }
        let movies = library.ownedMovieTMDBIDs
        let shows = library.ownedShowTMDBIDs
        return remote.results.filter { title in
            switch title.kind {
            case .movie: return !movies.contains(title.tmdbID)
            case .tv:    return !shows.contains(title.tmdbID)
            }
        }
    }
}

enum SidebarItem: String, Hashable, CaseIterable, Identifiable {
    case home, movies, shows, favorites, appleTV, bollywood, zyMovie, iptv, stream, downloads, settings, music, games

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Ana Ekran"
        case .movies: "Filmler"
        case .shows: "Diziler"
        case .favorites: "Favoriler"
        case .appleTV: "Apple TV"
        case .bollywood: "Bollywood"
        case .zyMovie: "ZyMovie"
        case .iptv: "IP Tv"
        case .stream: "ZyStream"
        case .downloads: "İndirilenler"
        case .settings: "Ayarlar"
        case .music: "Müzik"
        case .games: "Oyunlar"
        }
    }

    var symbol: String {
        switch self {
        case .home: "house"
        case .movies: "film"
        case .shows: "tv"
        case .favorites: "star"
        case .appleTV: "appletv"
        case .bollywood: "movieclapper"
        case .zyMovie: "film.stack"
        case .iptv: "antenna.radiowaves.left.and.right"
        case .stream: "play.tv"
        case .downloads: "arrow.down.circle"
        case .settings: "gearshape"
        case .music: "music.note"
        case .games: "gamecontroller"
        }
    }
}

struct Sidebar: View {
    @Binding var selection: SidebarItem
    var isSidebarActive: Bool = true
    var scheme: ColorScheme = .dark
    var onSelect: (SidebarItem) -> Void = { _ in }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach([SidebarItem.home, .movies, .shows, .favorites, .appleTV, .bollywood, .zyMovie, .iptv]) { item in
                    row(item)
                }
                Divider()
                    .padding(.vertical, 8)
                ForEach([SidebarItem.music, .games, .downloads, .settings]) { item in
                    row(item)
                }
            }
            .padding(12)
        }
        .background(AppTheme.sidebar(scheme).ignoresSafeArea())
    }

    private func row(_ item: SidebarItem) -> some View {
        SidebarRowView(
            item: item,
            isSelected: selection == item,
            isSidebarActive: isSidebarActive,
            onSelect: { onSelect(item) }
        )
    }
}

private struct SidebarRowView: View {
    let item: SidebarItem
    let isSelected: Bool
    let isSidebarActive: Bool
    let onSelect: () -> Void
    @FocusState private var isFocused: Bool

    private var isGamepadFocused: Bool {
        GamepadManager.shared.isConnected && isSidebarActive && (isSelected || isFocused)
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                Image(systemName: item.symbol)
                    .font(.system(size: 14))
                    .frame(width: 20)

                Text(item.title)
                    .font(.system(size: 13, weight: (isSelected || isGamepadFocused) ? .semibold : .medium))

                Spacer(minLength: 0)
            }
            .foregroundStyle(isGamepadFocused ? AnyShapeStyle(Color.cyan) : (isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary)))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isGamepadFocused ? Color.cyan.opacity(0.3) : (isSelected ? Color.white.opacity(0.12) : Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isGamepadFocused ? Color.cyan : Color.clear, lineWidth: 2)
            )
            .scaleEffect(isGamepadFocused ? 1.04 : 1.0)
            .animation(.easeOut(duration: 0.12), value: isGamepadFocused)
        }
        .buttonStyle(.plain)
        .focusable()
        .focused($isFocused)
    }
}

/// Shown until the library gains its first source.
struct EmptyLibraryView: View {
    let title: String

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "film.stack")
                .font(.system(size: 54))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title2.weight(.semibold))
            Text("Henüz içerik yok. Ayarlar’dan bir klasör ekleyin ya da ⌘O ile bir video açın.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct PlaceholderView: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 10) {
            Text(title).font(.title2.weight(.semibold))
            Text(detail).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A compact, slightly frosted search box that lives in the content — not the
/// window toolbar — so it looks the same in windowed and fullscreen.
struct SearchField: View {
    @Binding var text: String
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            TextField("Ara", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($isFocused)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .frame(maxWidth: 300)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(
            Capsule().strokeBorder(.white.opacity(isFocused ? 0.28 : 0.12), lineWidth: 1)
        )
    }
}

/// Reaches the host `NSWindow` to make its title bar transparent and seamless.
///
/// `.windowStyle(.hiddenTitleBar)` handles the windowed case, but fullscreen
/// still left a grey toolbar band and a separator line at the top. Clearing the
/// separator and keeping the content full-size makes fullscreen look like the
/// windowed chrome — the gradient runs straight to the top edge.
private struct WindowConfigurator: NSViewRepresentable {
    /// Painted behind the transparent title bar so fullscreen shows the app's
    /// own colour there, not macOS grey.
    let backgroundColor: NSColor
    /// The toolbar is hidden only here, so its grey strip vanishes in fullscreen
    /// while the windowed title bar (and its traffic-light buttons) stays intact.
    let isFullscreen: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { configure(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { configure(nsView.window) }
    }

    private func configure(_ window: NSWindow?) {
        guard let window else { return }
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarSeparatorStyle = .none
        window.backgroundColor = backgroundColor
        window.toolbar?.showsBaselineSeparator = false
        // Windowed: toolbar visible → the title bar keeps its height and the
        // traffic-light buttons show. Fullscreen: toolbar hidden → no grey strip
        // (there are no traffic lights in fullscreen anyway).
        window.toolbar?.isVisible = !isFullscreen
        window.standardWindowButton(.closeButton)?.isHidden = false
        window.standardWindowButton(.miniaturizeButton)?.isHidden = false
        window.standardWindowButton(.zoomButton)?.isHidden = false
    }
}

/// PlayStation / Gamepad bağlandığında gösterilen ikonlar ve kılavuz çubuğu.
struct GamepadLegendHUD: View {
    var body: some View {
        HStack(spacing: 12) {
            shoulderBadge(text: "L1", label: "Sol Menü")
            shoulderBadge(text: "R1", label: "İçerik")
            badge(icon: "multiply", color: .blue, text: "Seç / Oynat")
            badge(icon: "circle", color: .red, text: "Geri")
            badge(icon: "triangle", color: .green, text: "Arama")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.15), lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
    }

    private func shoulderBadge(text: String, label: String) -> some View {
        HStack(spacing: 4) {
            Text(text)
                .font(.system(size: 9, weight: .black))
                .foregroundStyle(.black)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Color.cyan, in: RoundedRectangle(cornerRadius: 4))
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
        }
    }

    private func badge(icon: String, color: Color, text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(color)
                .frame(width: 18, height: 18)
                .background(.white.opacity(0.12), in: Circle())
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
        }
    }
}

final class RootKeyMonitor {
    private var monitor: Any?

    func start(onEscape: @escaping () -> Void) {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            if event.keyCode == 53 {
                onEscape()
                return nil
            }
            return event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    deinit { stop() }
}
