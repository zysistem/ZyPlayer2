import SwiftUI
import WebKit

// MARK: - Embedded YouTube Trailer Player for macOS

/// Afişin arkasında oynayan YouTube fragmanı.
///
/// İki şey hıza doğrudan etki ediyor, ikisi de burada çözülüyor:
///
///   1. **Sayfa bir kez kuruluyor.** Fragman her değiştiğinde HTML'i baştan
///      yüklemek üç ardışık gidiş-dönüş demek (iframe API betiği → oynatıcı
///      iframe'i → videonun kendisi) ve her ok tuşunda saniyeler sürüyordu.
///      Kabuk bir kez kurulup sonraki fragmanlar `loadVideoById` ile
///      yükleniyor — oynatıcı ayakta kaldığı için neredeyse anında başlıyor.
///   2. **Gerçekten oynamaya başlayınca haber veriyor.** `onPlaying` tetiklenene
///      kadar afiş arka planda duruyor; fragman geç gelirse ya da hiç gelmezse
///      kullanıcı boş bir kutu değil filmin görselini görüyor.
struct TrailerWebView: NSViewRepresentable {
    let youtubeKey: String
    let isMuted: Bool
    /// Video gerçekten oynamaya başladığında (ya da durduğunda) çağrılıyor.
    var onPlayingChanged: (Bool) -> Void = { _ in }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsAirPlayForMediaPlayback = false
        config.preferences.setValue(true, forKey: "allowsInlineMediaPlayback")
        config.userContentController.add(context.coordinator, name: "zyTrailer")
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsBackForwardNavigationGestures = false
        return webView
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        nsView.configuration.userContentController
            .removeScriptMessageHandler(forName: "zyTrailer")
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        context.coordinator.onPlayingChanged = onPlayingChanged

        if context.coordinator.currentKey != youtubeKey {
            let isFirstLoad = context.coordinator.currentKey == nil
            context.coordinator.currentKey = youtubeKey
            context.coordinator.lastMuted = isMuted
            // Kabuk zaten kuruluysa sayfayı yeniden yükleme: ayakta duran
            // oynatıcıya yeni videoyu söylemek yeter.
            guard isFirstLoad else {
                let js = "if (window.zyLoad) { zyLoad('\(youtubeKey)', \(isMuted ? 1 : 0)); }"
                nsView.evaluateJavaScript(js, completionHandler: nil)
                return
            }
            let html = """
            <!DOCTYPE html>
            <html><head><meta charset="utf-8"><style>
            *{margin:0;padding:0;overflow:hidden;}
            html,body{width:100%;height:100%;background:transparent;}
            #player,iframe{position:absolute!important;top:50%!important;left:50%!important;width:100vw!important;height:56.25vw!important;min-height:100vh!important;min-width:177.78vh!important;transform:translate(-50%,-50%)!important;border:none!important;pointer-events:none!important;}
            </style></head><body>
            <div id="player"></div>
            <script src="https://www.youtube.com/iframe_api"></script>
            <script>
            function suppressMediaSession(){
              if(!navigator.mediaSession) return;
              navigator.mediaSession.metadata = null;
              navigator.mediaSession.playbackState = 'none';
              var actions = ['play','pause','seekbackward','seekforward','previoustrack','nexttrack','stop','seekto'];
              actions.forEach(function(a){
                try{ navigator.mediaSession.setActionHandler(a, null); }catch(e){}
              });
            }
            suppressMediaSession();

            function report(playing){
              try{ window.webkit.messageHandlers.zyTrailer.postMessage(playing ? 1 : 0); }catch(e){}
            }

            // API henüz hazır değilken gelen istek burada bekliyor; oynatıcı
            // kurulur kurulmaz uygulanıyor.
            window.zyPending = null;
            window.zyLoad = function(id, muted){
              report(false);
              if(!window.ytplayer || !window.ytplayer.loadVideoById){
                window.zyPending = { id: id, muted: muted };
                return;
              }
              if(muted){ window.ytplayer.mute(); } else { window.ytplayer.unMute(); }
              window.ytplayer.loadVideoById(id);
            };

            function onYouTubeIframeAPIReady(){
              window.ytplayer = new YT.Player('player',{
                videoId: '\(youtubeKey)',
                playerVars: {
                  autoplay: 1,
                  mute: \(isMuted ? 1 : 0),
                  controls: 0,
                  disablekb: 1,
                  fs: 0,
                  loop: 1,
                  playlist: '\(youtubeKey)',
                  modestbranding: 1,
                  rel: 0,
                  showinfo: 0,
                  iv_load_policy: 3,
                  playsinline: 1,
                  cc_load_policy: 0,
                  enablejsapi: 1,
                  origin: 'https://www.youtube-nocookie.com'
                },
                events: {
                  onReady: function(e){
                    e.target.playVideo();
                    suppressMediaSession();
                    if(window.zyPending){
                      var p = window.zyPending; window.zyPending = null;
                      window.zyLoad(p.id, p.muted);
                    }
                  },
                  // 1 = oynuyor. Afiş ancak bu geldiğinde fragmana geçiyor.
                  onStateChange: function(e){
                    suppressMediaSession();
                    report(e.data === 1);
                  },
                  // Video gömülemiyorsa (bölge kısıtı, kaldırılmış video) afiş
                  // görselinde kalınsın.
                  onError: function(){ report(false); }
                }
              });
            }
            setInterval(suppressMediaSession, 400);
            </script>
            </body></html>
            """
            nsView.loadHTMLString(html, baseURL: URL(string: "https://www.youtube-nocookie.com"))
        } else if context.coordinator.lastMuted != isMuted {
            context.coordinator.lastMuted = isMuted
            let js = isMuted
                ? "if(window.ytplayer && window.ytplayer.mute){ window.ytplayer.mute(); }"
                : "if(window.ytplayer && window.ytplayer.unMute){ window.ytplayer.unMute(); }"
            nsView.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator: NSObject, WKScriptMessageHandler {
        var currentKey: String?
        var lastMuted: Bool?
        var onPlayingChanged: (Bool) -> Void = { _ in }

        func userContentController(_ controller: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            let playing = (message.body as? Int).map { $0 == 1 }
                ?? ((message.body as? NSNumber)?.intValue == 1)
            onPlayingChanged(playing)
        }
    }
}

// MARK: - Category Genres

struct CategoryGenre: Identifiable, Hashable {
    let id: String
    let title: String
    let tmdbGenreID: Int
    let colors: [Color]
    let symbol: String

    static let allCases: [CategoryGenre] = [
        CategoryGenre(
            id: "action",
            title: "Aksiyon",
            tmdbGenreID: 28,
            colors: [Color(red: 0.95, green: 0.3, blue: 0.1), Color(red: 0.5, green: 0.05, blue: 0.0)],
            symbol: "flame.fill"
        ),
        CategoryGenre(
            id: "comedy",
            title: "Komedi",
            tmdbGenreID: 35,
            colors: [Color(red: 0.0, green: 0.8, blue: 0.75), Color(red: 0.0, green: 0.45, blue: 0.35)],
            symbol: "face.smiling.fill"
        ),
        CategoryGenre(
            id: "drama",
            title: "Dram",
            tmdbGenreID: 18,
            colors: [Color(red: 0.15, green: 0.45, blue: 0.85), Color(red: 0.05, green: 0.1, blue: 0.3)],
            symbol: "theatermasks.fill"
        ),
        CategoryGenre(
            id: "family",
            title: "Çocuk ve Aile",
            tmdbGenreID: 10751,
            colors: [Color(red: 0.9, green: 0.3, blue: 0.6), Color(red: 0.45, green: 0.15, blue: 0.45)],
            symbol: "figure.2.and.child.holdinghands"
        ),
        CategoryGenre(
            id: "horror",
            title: "Korku",
            tmdbGenreID: 27,
            colors: [Color(red: 0.85, green: 0.45, blue: 0.05), Color(red: 0.15, green: 0.05, blue: 0.02)],
            symbol: "house.fill"
        ),
        CategoryGenre(
            id: "thriller",
            title: "Gerilim",
            tmdbGenreID: 53,
            colors: [Color(red: 0.25, green: 0.28, blue: 0.35), Color(red: 0.55, green: 0.05, blue: 0.1)],
            symbol: "cloud.heavyrain.fill"
        ),
        CategoryGenre(
            id: "adventure",
            title: "Macera",
            tmdbGenreID: 12,
            colors: [Color(red: 0.65, green: 0.75, blue: 0.1), Color(red: 0.05, green: 0.35, blue: 0.25)],
            symbol: "compass.drawing"
        ),
        CategoryGenre(
            id: "fantasy",
            title: "Fantastik",
            tmdbGenreID: 14,
            colors: [Color(red: 0.2, green: 0.75, blue: 0.85), Color(red: 0.6, green: 0.15, blue: 0.1)],
            symbol: "wand.and.stars"
        ),
        CategoryGenre(
            id: "scifi",
            title: "Bilim Kurgu",
            tmdbGenreID: 878,
            colors: [Color(red: 0.1, green: 0.3, blue: 0.7), Color(red: 0.0, green: 0.1, blue: 0.35)],
            symbol: "sparkles"
        ),
        CategoryGenre(
            id: "romance",
            title: "Romantik",
            tmdbGenreID: 10749,
            colors: [Color(red: 0.95, green: 0.35, blue: 0.5), Color(red: 0.55, green: 0.1, blue: 0.25)],
            symbol: "heart.fill"
        ),
        CategoryGenre(
            id: "animation",
            title: "Animasyon",
            tmdbGenreID: 16,
            colors: [Color(red: 0.4, green: 0.85, blue: 0.4), Color(red: 0.1, green: 0.4, blue: 0.15)],
            symbol: "paintpalette.fill"
        ),
        CategoryGenre(
            id: "documentary",
            title: "Belgesel",
            tmdbGenreID: 99,
            colors: [Color(red: 0.55, green: 0.5, blue: 0.35), Color(red: 0.2, green: 0.15, blue: 0.08)],
            symbol: "book.fill"
        ),
        CategoryGenre(
            id: "history",
            title: "Tarih",
            tmdbGenreID: 36,
            colors: [Color(red: 0.7, green: 0.55, blue: 0.3), Color(red: 0.3, green: 0.2, blue: 0.08)],
            symbol: "building.columns.fill"
        ),
        CategoryGenre(
            id: "crime",
            title: "Suç",
            tmdbGenreID: 80,
            colors: [Color(red: 0.5, green: 0.15, blue: 0.15), Color(red: 0.18, green: 0.05, blue: 0.05)],
            symbol: "exclamationmark.triangle.fill"
        )
    ]
}

// MARK: - 1. Sinemadaki Filmler Hero Slider (With Auto-Play Trailer)

struct HeroCinemaBanner: View {
    let movies: [RemoteTitle]
    let library: LibraryStore
    let settings: AppSettings
    let actions: LibraryActions

    @State private var currentIndex = 0
    @State private var isMuted = true
    @State private var trailerKey: String? = nil
    @State private var isLoadingTrailer = false
    @State private var trailerCache: [Int: String?] = [:]
    /// Fragman gerçekten oynuyor mu? Afişten fragmana geçiş buna bakıyor.
    @State private var isTrailerPlaying = false

    private var currentMovie: RemoteTitle? {
        guard !movies.isEmpty else { return nil }
        return movies[min(currentIndex, movies.count - 1)]
    }

    var body: some View {
        ZStack {
            if let movie = currentMovie {
                bannerContent(for: movie)
            } else {
                placeholderBanner
            }
        }
        .frame(height: 840)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 20)
        .onChange(of: currentIndex) {
            fetchTrailerForCurrentMovie()
        }
        .onChange(of: trailerKey) {
            // Yeni fragman kendi "oynuyorum" haberini verene kadar afişe dön.
            isTrailerPlaying = false
        }
        .onChange(of: movies) {
            prefetchTrailers()
            fetchTrailerForCurrentMovie()
        }
        .onAppear {
            prefetchTrailers()
            fetchTrailerForCurrentMovie()
        }
    }

    @ViewBuilder
    private func bannerContent(for movie: RemoteTitle) -> some View {
        ZStack(alignment: .bottomLeading) {
            // Background Artwork / Trailer Video
            //
            // Afiş her zaman en altta duruyor; fragman ancak gerçekten oynamaya
            // başlayınca üstüne yumuşak geçişle biniyor. Böylece fragman geç
            // gelirse ya da hiç gelmezse boş bir kutu değil filmin görseli
            // kalıyor.
            GeometryReader { geo in
                ZStack {
                    if let backdropURL = movie.backdropURL {
                        CachedAsyncImage(url: backdropURL) { phase in
                            switch phase {
                            case .success(let image):
                                image.resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: geo.size.width, height: geo.size.height)
                                    .clipped()
                            default:
                                placeholderImage
                            }
                        }
                    } else {
                        placeholderImage
                    }

                    if settings.autoplayTrailers, let key = trailerKey {
                        TrailerWebView(youtubeKey: key, isMuted: isMuted) { playing in
                            withAnimation(.easeInOut(duration: 0.45)) {
                                isTrailerPlaying = playing
                            }
                        }
                        .allowsHitTesting(false)
                        .opacity(isTrailerPlaying ? 1 : 0)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()

            // Bottom gradient that blends into app background
            VStack(spacing: 0) {
                Spacer()
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black.opacity(0.3), location: 0.3),
                        .init(color: .black.opacity(0.7), location: 0.6),
                        .init(color: Color(red: 0.02, green: 0.04, blue: 0.09), location: 0.85),
                        .init(color: Color(red: 0.02, green: 0.04, blue: 0.09), location: 1.0)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 300)
            }

            // Top Right Controls (Mute Button) — yalnızca fragman gerçekten
            // oynarken; sessize alacak bir şey yokken düğme çıkmasın.
            if settings.autoplayTrailers && isTrailerPlaying {
                VStack {
                    HStack {
                        Spacer()
                        Button {
                            isMuted.toggle()
                        } label: {
                            Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 32, height: 32)
                                .background(.black.opacity(0.6), in: Circle())
                                .overlay(Circle().strokeBorder(.white.opacity(0.2), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .padding(16)
                        .help(isMuted ? "Sesi Aç" : "Sesi Kapat")
                    }
                    Spacer()
                }
            }

            // Navigation Arrows (Left & Right) — vertically centered
            if movies.count > 1 {
                HStack {
                    Button {
                        withAnimation {
                            currentIndex = (currentIndex - 1 + movies.count) % movies.count
                        }
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 38, height: 38)
                            .background(.black.opacity(0.45), in: Circle())
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    Button {
                        withAnimation {
                            currentIndex = (currentIndex + 1) % movies.count
                        }
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 38, height: 38)
                            .background(.black.opacity(0.45), in: Circle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .frame(maxHeight: .infinity, alignment: .center)
            }

            // Left Side Information & Action Buttons
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(movie.title)
                        .font(.system(size: 40, weight: .heavy))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .shadow(color: .black.opacity(0.6), radius: 8, x: 0, y: 3)

                    HStack(spacing: 8) {
                        HStack(spacing: 4) {
                            Image(systemName: "house.fill")
                                .font(.system(size: 14))
                            Text("Film")
                                .font(.system(size: 15, weight: .semibold))
                        }
                        .foregroundStyle(.white.opacity(0.9))

                        if let year = movie.year {
                            Text("•")
                                .foregroundStyle(.white.opacity(0.5))
                            Text(String(year))
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(.white.opacity(0.85))
                        }

                        if let rating = movie.rating, rating > 0 {
                            Text("•")
                                .foregroundStyle(.white.opacity(0.5))
                            HStack(spacing: 4) {
                                Image(systemName: "star.fill")
                                    .font(.system(size: 14))
                                    .foregroundStyle(.yellow)
                                Text(String(format: "%.1f", rating))
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                        }
                    }
                }

                if let overview = movie.overview, !overview.isEmpty {
                    Text(overview)
                        .font(.system(size: 15))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(3)
                        .frame(maxWidth: 560, alignment: .leading)
                        .shadow(color: .black.opacity(0.6), radius: 4)
                }

                HStack(spacing: 12) {
                    Button {
                        actions.selectRemote(movie)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "info.circle.fill")
                                .font(.system(size: 16, weight: .semibold))
                            Text("Daha Fazla Bilgi")
                                .font(.system(size: 15, weight: .bold))
                        }
                        .foregroundStyle(.black)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 10)
                        .background(.white, in: Capsule())
                        .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
                    }
                    .buttonStyle(.plain)

                    Button {
                        let isOwned = library.ownedMovieTMDBIDs.contains(movie.tmdbID)
                        if !isOwned {
                            let item = library.remoteFavorites.first(where: { $0.tmdbID == movie.tmdbID })
                            if item != nil {
                                library.removeRemoteFavorite(movie)
                            } else {
                                library.addRemoteFavorite(movie)
                            }
                        }
                    } label: {
                        Image(systemName: library.remoteFavorites.contains(where: { $0.tmdbID == movie.tmdbID }) ? "checkmark" : "plus")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 38, height: 38)
                            .background(.black.opacity(0.6), in: Circle())
                            .overlay(Circle().strokeBorder(.white.opacity(0.3), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .help("İzleme Listeme Ekle / Çıkar")
                }

                // Pagination Dots
                if movies.count > 1 {
                    HStack(spacing: 6) {
                        ForEach(0..<movies.count, id: \.self) { index in
                            Circle()
                                .fill(index == currentIndex ? Color.white : Color.white.opacity(0.35))
                                .frame(width: index == currentIndex ? 8 : 6, height: index == currentIndex ? 8 : 6)
                                .onTapGesture {
                                    withAnimation { currentIndex = index }
                                }
                        }
                    }
                    .padding(.top, 4)
                }
            }
            .padding(32)
        }
    }

    private var placeholderBanner: some View {
        ZStack {
            LinearGradient(
                colors: [Color(white: 0.2), Color(white: 0.1)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            VStack(spacing: 8) {
                Image(systemName: "popcorn.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
                Text("Sinemadaki Filmler Yükleniyor...")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var placeholderImage: some View {
        ZStack {
            LinearGradient(
                colors: [Color(white: 0.2), Color(white: 0.1)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: "film")
                .font(.system(size: 40))
                .foregroundStyle(.white.opacity(0.2))
        }
    }

    private func fetchTrailerForCurrentMovie() {
        guard settings.hasTMDBToken, settings.autoplayTrailers, let movie = currentMovie else {
            trailerKey = nil
            return
        }

        if let cached = trailerCache[movie.tmdbID] {
            trailerKey = cached
            return
        }

        isLoadingTrailer = true
        Task {
            defer { isLoadingTrailer = false }
            let client = TMDBClient(token: settings.tmdbToken, language: settings.metadataLanguage)
            let key = (try? await client.trailers(movieID: movie.tmdbID))?
                .first(where: { $0.site?.lowercased() == "youtube" })?.key

            await MainActor.run {
                self.trailerCache[movie.tmdbID] = key
                if self.currentMovie?.tmdbID == movie.tmdbID {
                    self.trailerKey = key
                }
            }
        }
    }

    private func prefetchTrailers() {
        guard settings.hasTMDBToken, settings.autoplayTrailers, !movies.isEmpty else { return }
        let client = TMDBClient(token: settings.tmdbToken, language: settings.metadataLanguage)
        let list = Array(movies.prefix(8))
        Task {
            await withTaskGroup(of: (Int, String?).self) { group in
                for m in list {
                    if trailerCache[m.tmdbID] != nil { continue }
                    group.addTask {
                        let k = (try? await client.trailers(movieID: m.tmdbID))?
                            .first(where: { $0.site?.lowercased() == "youtube" })?.key
                        return (m.tmdbID, k)
                    }
                }
                for await (id, key) in group {
                    await MainActor.run {
                        self.trailerCache[id] = key
                        if self.currentMovie?.tmdbID == id {
                            self.trailerKey = key
                        }
                    }
                }
            }
        }
    }
}

/// Sıralama: en son güncellenen öne gelir (kütüphane öğeleri watchState.updatedAt bazlı).
struct ContinueWatchingRow: View {
    let items: [MediaItem]
    let library: LibraryStore
    let actions: LibraryActions
    let settings: AppSettings
    /// ZyStream ve torrent devam noktaları.
    var resumePoints: [ResumePoint] = []
    /// Torrent devam oynatma callback'i.
    var onResumeTorrent: ((ResumePoint) -> Void)?
    /// ZyStream doğrudan oynatma callback'i.
    var onResumeStream: ((ResumePoint) -> Void)?
    /// Kaldır seçeneği için callback
    var onRemoveResumePoint: ((ResumePoint) -> Void)?
    /// Karta basıldığında yapımın detay sayfasını açar.
    var onOpenResumeDetail: ((ResumePoint) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                Text("İzlemeyi Sürdür")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.primary)

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.secondary)

                Spacer()
            }
            .padding(.horizontal, 20)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    // 1. Kütüphane devam öğeleri
                    ForEach(items) { item in
                        ContinueWatchingCard(
                            item: item,
                            watchState: library.state(for: item) ?? WatchState(),
                            meta: item.seriesKey.flatMap { library.meta(forSeriesKey: $0) },
                            onOpenDetail: { actions.openDetail(item) },
                            onPlay: { actions.play(item) },
                            onRemove: { library.removeFromContinueWatching(item) },
                            onMarkWatched: { actions.markWatched(item, true) }
                        )
                    }

                    // 2. Stream ve torrent resume noktaları
                    ForEach(resumePoints) { point in
                        ResumePointCard(
                            point: point,
                            // Kayıtta geri dönülecek yapım yoksa (eski kayıtlar)
                            // açılacak sayfa da yok; kart oynatmaya düşer.
                            onOpenDetail: (point.remoteTitle != nil || point.streamHit != nil)
                                ? { onOpenResumeDetail?(point) }
                                : nil,
                            onPlay: {
                                if point.kind == .torrent {
                                    onResumeTorrent?(point)
                                } else {
                                    onResumeStream?(point)
                                }
                            },
                            onRemove: {
                                onRemoveResumePoint?(point)
                            },
                            settings: settings
                        )
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }
}



/// Kütüphane öğesi için "İzlemeyi Sürdür" kartı.
struct ContinueWatchingCard: View {
    let item: MediaItem
    let watchState: WatchState
    let meta: SeriesMeta?
    /// Karta basmak detay ekranını açar; oynatmaya oradan devam edilir.
    /// Doğrudan oynatma "…" menüsünde duruyor.
    let onOpenDetail: () -> Void
    let onPlay: () -> Void
    let onRemove: () -> Void
    let onMarkWatched: () -> Void

    @State private var isHovering = false
    @FocusState private var isFocused: Bool

    private var isHighlighted: Bool {
        isHovering || isFocused
    }

    private var displayTitle: String {
        if item.kind == .episode {
            return meta?.name ?? item.showTitle ?? item.title
        }
        return item.title
    }

    private var remainingText: String {
        let remaining = max(0, watchState.duration - watchState.position)
        let totalMins = Int(remaining / 60)
        if totalMins >= 60 {
            let hours = totalMins / 60
            let mins = totalMins % 60
            return mins > 0 ? "\(hours) sa. \(mins) dk." : "\(hours) sa."
        } else {
            return "\(max(1, totalMins)) dk."
        }
    }

    var body: some View {
        Button(action: onOpenDetail) {
            ZStack(alignment: .bottom) {
                // Background Artwork
                artwork
                    .frame(width: 270, height: 152)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(.white.opacity(isHighlighted ? 0.9 : 0.08), lineWidth: isHighlighted ? 2 : 1)
                    )

                // Dark Bottom Gradient
                LinearGradient(
                    colors: [.clear, .black.opacity(0.85)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                // Title Overlay (Top Left)
                VStack {
                    HStack {
                        Text(displayTitle)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .shadow(color: .black.opacity(0.8), radius: 3)
                        Spacer()
                    }
                    .padding(10)
                    Spacer()
                }

                // Bottom Control Bar
                HStack(spacing: 8) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)

                    // Progress Bar
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.3))
                            Capsule()
                                .fill(.white)
                                .frame(width: max(0, min(geo.size.width, geo.size.width * watchState.progress)))
                        }
                    }
                    .frame(height: 3)

                    Text(remainingText)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.95))
                        .layoutPriority(1)

                    Menu {
                        Button("Oynat", systemImage: "play.fill") { onPlay() }
                        Button("Listeden Çıkar", systemImage: "xmark") { onRemove() }
                        Button("İzlendi İşaretle", systemImage: "checkmark") { onMarkWatched() }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .frame(width: 20)
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
            .scaleEffect(isHighlighted ? 1.03 : 1)
            .shadow(color: .black.opacity(isHighlighted ? 0.4 : 0.1), radius: 10, y: 4)
            .animation(.easeOut(duration: 0.15), value: isHighlighted)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .focused($isFocused)
        .onHover { isHovering = $0 }
    }

    @ViewBuilder
    private var artwork: some View {
        if let backdropName = item.backdropFileName, let image = ArtworkCache.image(named: backdropName) {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
        } else if let posterName = item.posterFileName, let image = ArtworkCache.image(named: posterName) {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                LinearGradient(
                    colors: [Color(white: 0.25), Color(white: 0.15)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Image(systemName: "play.tv")
                    .font(.system(size: 32))
                    .foregroundStyle(.white.opacity(0.25))
            }
        }
    }
}

/// Stream ve torrent devam noktaları için kart — aynı stil, uzak poster veya renk gradient.
struct ResumePointCard: View {
    let point: ResumePoint
    /// Karta basmak detay ekranını açar. Kayıtta geri dönülecek yapım yoksa
    /// (eski kayıtlar) açılacak bir sayfa da yok; o durumda oynatmaya düşer.
    var onOpenDetail: (() -> Void)?
    let onPlay: () -> Void
    let onRemove: () -> Void
    let settings: AppSettings

    @State private var isHovering = false
    @State private var posterImage: NSImage?
    @FocusState private var isFocused: Bool

    private var isHighlighted: Bool {
        isHovering || isFocused
    }

    private var remainingText: String {
        let remaining = max(0, point.duration - point.position)
        let totalMins = Int(remaining / 60)
        if totalMins >= 60 {
            let hours = totalMins / 60; let mins = totalMins % 60
            return mins > 0 ? "\(hours) sa. \(mins) dk." : "\(hours) sa."
        }
        return "\(max(1, totalMins)) dk."
    }

    private var kindIcon: String {
        point.kind == .torrent ? "arrow.down.circle.fill" : "play.circle.fill"
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: { (onOpenDetail ?? onPlay)() }) {
                ZStack(alignment: .bottom) {
                    // Poster / gradient background
                    Group {
                        if let img = posterImage {
                            Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                        } else {
                            LinearGradient(
                                colors: [Color(white: 0.28), Color(white: 0.16)],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            )
                        }
                    }
                    .frame(width: 270, height: 152)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(.white.opacity(isHighlighted ? 0.9 : 0.08), lineWidth: isHighlighted ? 2 : 1)
                    )

                    // Gradient overlay
                    LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .top, endPoint: .bottom)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                    // Title + kind badge (top)
                    VStack {
                        HStack(alignment: .top) {
                            Text(point.title)
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(.white)
                                .lineLimit(2)
                                .shadow(color: .black.opacity(0.8), radius: 3)
                            Spacer()
                            if !isHighlighted {
                                Image(systemName: kindIcon)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.white.opacity(0.7))
                            }
                        }
                        .padding(10)
                        Spacer()
                    }

                    // Bottom bar: play + progress + time + menu
                    HStack(spacing: 8) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)

                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(.white.opacity(0.3))
                                Capsule()
                                    .fill(point.kind == .torrent ? Color.orange : Color.blue)
                                    .frame(width: max(0, geo.size.width * point.progress))
                            }
                        }
                        .frame(height: 3)

                        Text(remainingText)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.95))
                            .layoutPriority(1)

                        Menu {
                            Button("Oynat", systemImage: "play.fill") { onPlay() }
                            Button("Listeden Çıkar", systemImage: "xmark") { onRemove() }
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 20, height: 20)
                                .contentShape(Rectangle())
                        }
                        .menuStyle(.borderlessButton)
                        .frame(width: 20)
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                }
                .scaleEffect(isHighlighted ? 1.03 : 1)
                .shadow(color: .black.opacity(isHighlighted ? 0.4 : 0.1), radius: 10, y: 4)
                .animation(.easeOut(duration: 0.15), value: isHighlighted)
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .focused($isFocused)

            if isHighlighted {
                PosterCard.removeButton(onRemove)
                    .transition(.opacity)
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .task {
            guard let str = point.posterURLString, !str.isEmpty else { return }
            if str.hasPrefix("/") {
                let tmdbURL = TMDBClient.imageURL(path: str, size: "w342")
                if let (data, _) = try? await URLSession.shared.data(from: tmdbURL),
                   let img = NSImage(data: data) {
                    posterImage = img
                }
            } else if str.hasPrefix("http") {
                if let url = URL(string: str),
                   let (data, _) = try? await URLSession.shared.data(from: url),
                   let img = NSImage(data: data) {
                    posterImage = img
                }
            } else {
                posterImage = ArtworkCache.image(named: str)
            }
        }
    }
}

// MARK: - 3. Kategori Sistemi (Single-Row Horizontal Scroll)

/// Ana ekrandaki kategori kuşağı.
///
/// Eskiden tüm kategoriler pencere genişliğine bölünüp 70 puanlık dar, tek
/// tip gri kutulara sıkışıyordu: türe ait renkler hiç kullanılmıyor, uzun
/// başlıklar küçültülerek zar zor sığıyordu. Artık kartlar sabit ve rahat bir
/// boyutta, her tür kendi renk geçişini taşıyor, kuşak yatay kayıyor.
struct CategoryGridRow: View {
    let onSelectCategory: (CategoryGenre) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text("Kategoriler")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.primary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(CategoryGenre.allCases) { category in
                        CategoryCard(category: category) {
                            onSelectCategory(category)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 4)
            }
        }
    }
}

struct CategoryCard: View {
    let category: CategoryGenre
    let onSelect: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onSelect) {
            ZStack(alignment: .bottomLeading) {
                // Türün kendi renkleri: kuşak tek renk bir sıra kutu yerine
                // bakışta ayırt edilebilir bir şeye dönüşüyor.
                LinearGradient(colors: category.colors,
                               startPoint: .topLeading, endPoint: .bottomTrailing)

                // Simge sağ üstte, büyük ve soluk — arka plan dokusu gibi.
                Image(systemName: category.symbol)
                    .font(.system(size: 42, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.18))
                    .rotationEffect(.degrees(-12))
                    .offset(x: 42, y: -18)

                // Yazının okunması için alt tarafa koyu bir geçiş.
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.35),
                        .init(color: .black.opacity(0.45), location: 1)
                    ],
                    startPoint: .top, endPoint: .bottom
                )

                Text(category.title)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
                    .lineLimit(1)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            }
            .frame(width: 150, height: 86)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.white.opacity(isHovering ? 0.45 : 0.12), lineWidth: 1)
            )
            .shadow(color: .black.opacity(isHovering ? 0.35 : 0.18),
                    radius: isHovering ? 12 : 6, y: isHovering ? 6 : 3)
            .scaleEffect(isHovering ? 1.04 : 1)
            .animation(.spring(response: 0.28, dampingFraction: 0.7), value: isHovering)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

// MARK: - Category Detail View (Genre Filter Page)

struct CategoryDetailView: View {
    let genre: CategoryGenre
    let library: LibraryStore
    let settings: AppSettings
    let actions: LibraryActions
    let onBack: () -> Void

    @State private var remoteTitles: [RemoteTitle] = []
    @State private var isLoadingRemote = false

    private var matchingMovies: [MediaItem] {
        library.movies.filter { movie in
            movie.genres.contains { $0.localizedCaseInsensitiveContains(genre.title) }
        }
    }

    private var matchingShows: [Series] {
        library.shows.filter { series in
            series.meta?.genres.contains { $0.localizedCaseInsensitiveContains(genre.title) } ?? false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header Bar
            HStack(spacing: 12) {
                Button(action: onBack) {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Geri")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Text(genre.title)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.primary)

                Spacer()
            }
            .padding(.horizontal, 22)
            .padding(.top, 16)
            .padding(.bottom, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    if !matchingMovies.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Kütüphanedeki Filmler (\(matchingMovies.count))")
                                .font(.system(size: 16, weight: .semibold))
                            
                            PosterGrid(items: matchingMovies) { item, isGamepadSelected in
                                MediaCard(item: item, state: library.state(for: item), actions: actions, isGamepadSelected: isGamepadSelected)
                            }
                        }
                    }

                    if !matchingShows.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Kütüphanedeki Diziler (\(matchingShows.count))")
                                .font(.system(size: 16, weight: .semibold))

                            PosterGrid(items: matchingShows) { series, isGamepadSelected in
                                SeriesCard(series: series, actions: actions, isWatched: library.isSeriesFullyWatched(seriesKey: series.id), isGamepadSelected: isGamepadSelected)
                            }
                        }
                    }

                    if !remoteTitles.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("TMDB Keşfet (\(genre.title))")
                                .font(.system(size: 16, weight: .semibold))

                            let owned = library.ownedMovieTMDBIDs
                            PosterGrid(items: remoteTitles) { title, isGamepadSelected in
                                RemoteCard(
                                    title: title,
                                    isOwned: owned.contains(title.tmdbID),
                                    onSelect: { actions.selectRemote(title) },
                                    isGamepadSelected: isGamepadSelected
                                )
                            }
                        }
                    } else if isLoadingRemote {
                        ProgressView()
                            .frame(maxWidth: .infinity, minHeight: 120)
                    } else if matchingMovies.isEmpty && matchingShows.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: genre.symbol)
                                .font(.system(size: 44))
                                .foregroundStyle(.secondary)
                            Text("Bu kategoride içerik bulunamadı")
                                .font(.title3.weight(.semibold))
                            Text("TMDB jetonunuz Ayarlar menüsünden girildiyse yeni filmler yüklenecektir.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 200)
                    }
                }
                .padding(22)
            }
        }
        .task {
            await fetchRemoteTitles()
        }
    }

    private func fetchRemoteTitles() async {
        guard settings.hasTMDBToken else { return }
        
        // 1. Load from local cache immediately (0ms instant UI rendering!)
        loadCachedRemoteTitles()
        
        if remoteTitles.isEmpty {
            isLoadingRemote = true
        }
        defer { isLoadingRemote = false }

        let client = TMDBClient(token: settings.tmdbToken, language: settings.metadataLanguage)
        let pages = await withTaskGroup(of: (Int, [MovieResult]).self) { group in
            for page in 1...6 {
                group.addTask {
                    (page, (try? await client.discoverMovies(genreID: genre.tmdbGenreID,
                                                             page: page)) ?? [])
                }
            }
            var collected: [(Int, [MovieResult])] = []
            for await result in group { collected.append(result) }
            return collected.sorted { $0.0 < $1.0 }.flatMap(\.1)
        }
        var seen = Set<Int>()
        let freshTitles = pages
            .filter { seen.insert($0.id).inserted }
            .prefix(100)
            .map(RemoteTitle.init(movie:))
        
        if !freshTitles.isEmpty {
            remoteTitles = Array(freshTitles)
            saveCachedRemoteTitles(Array(freshTitles))
        }
    }

    private func loadCachedRemoteTitles() {
        let cacheKey = "category_genre_\(genre.tmdbGenreID)"
        if let data = UserDefaults.standard.data(forKey: cacheKey),
           let cached = try? JSONDecoder().decode([RemoteTitle].self, from: data) {
            self.remoteTitles = cached
        }
    }

    private func saveCachedRemoteTitles(_ titles: [RemoteTitle]) {
        let cacheKey = "category_genre_\(genre.tmdbGenreID)"
        if let data = try? JSONEncoder().encode(titles) {
            UserDefaults.standard.set(data, forKey: cacheKey)
        }
    }
}
