import SwiftUI

/// The ZyStream landing page: the enabled sites' "recently added" rows, refreshed
/// on each visit. Search happens through the app's main search box (which shows a
/// "ZyStream’de Bulunanlar" section), so there is no search field here.
///
/// The resolving overlay and the episode sheet are hosted by `RootView`, not
/// here, so playing a hit from the global search works the same way.
struct ZyStreamView: View {
    @Bindable var store: ZyStreamStore
    let library: LibraryStore
    let resume: PlaybackResumeStore
    let settings: AppSettings
    let onOpen: (StreamHit) -> Void

    var body: some View {
        content
            // No `id:` — the view is rebuilt when the sidebar re-enters ZyStream,
            // so this re-runs and the shelves come back fresh each visit.
            .task {
                // Rafları yüklemeden önce adresler denetlenir: site taşındıysa
                // eski adrese yapılacak istekler boş dönerdi ve ekran sebebini
                // söylemeden boş kalırdı.
                await StreamDomainTracker.refreshAll(settings: settings)
                await store.loadDiscover(providers: settings.enabledStreamProviders)
            }
    }

    @ViewBuilder
    private var content: some View {
        if !settings.hasEnabledStreamSources {
            PlaceholderView(
                title: "Akış kaynağı kapalı",
                detail: "Ayarlar → Akış Kaynakları’ndan HdFilmCehennemi veya ZySeries gibi bir kaynağı açın."
            )
        } else if store.shelves.isEmpty && resume.streamContinue.isEmpty {
            if store.isLoadingShelves {
                ProgressView("Yükleniyor…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                PlaceholderView(
                    title: "ZyStream",
                    detail: "İçerik alınamadı. Aramak için üstteki arama kutusunu kullanın."
                )
            }
        } else {
            ScrollView {
                // One full row per section: 10 across. The generous gap keeps the
                // rows reading as separate categories rather than one long grid.
                VStack(alignment: .leading, spacing: 64) {
                    let continueList = resume.streamContinue
                    if !continueList.isEmpty {
                        SectionBlock(title: "İzlemeye Devam Et", total: continueList.count,
                                     onShowAll: nil, columns: 10, limit: 20) {
                            ForEach(Array(continueList.prefix(20))) { point in
                                StreamHitCard(hit: hit(for: point), store: store, onOpen: onOpen,
                                              library: library, progress: point.progress,
                                              onRemove: { resume.remove(key: point.id) })
                            }
                        }
                    }

                    ForEach(store.shelves) { shelf in
                        SectionBlock(title: shelf.title, total: shelf.hits.count,
                                     onShowAll: nil, columns: 10, limit: 20) {
                            ForEach(Array(shelf.hits.prefix(20))) { hit in
                                StreamHitCard(hit: hit, store: store, onOpen: onOpen, library: library)
                            }
                        }
                    }
                }
                .padding(.vertical, 22)
            }
        }
    }

    /// Rebuilds a hit from a resume point so the shared card can play it.
    private func hit(for point: ResumePoint) -> StreamHit {
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

/// Sidebar'daki "Filmler" (kind: .movie) ve "Diziler" (kind: .series)
/// görünümleri: üstte akış sitelerinin kendi kategorileri tab olarak, altta
/// seçili kategorinin o türdeki kartları.
struct StreamCategoryBrowser: View {
    let kind: StreamKind
    @Bindable var store: ZyStreamStore
    let library: LibraryStore
    let resume: PlaybackResumeStore
    let settings: AppSettings
    let onOpen: (StreamHit) -> Void

    @State private var selected: StreamCategory?

    enum SortMode: String, CaseIterable { case none = "Varsayılan", year = "Yıl", rating = "Puan" }
    /// Sağdaki filtreler: en düşük yıl, en düşük IMDb puanı ve sıralama.
    @State private var minYear: Int?
    @State private var minRating: Double?
    @State private var sort: SortMode = .none

    /// Bu iki görünüm içeriğini yalnızca HdFilmCehennemi'nin kendi kategori
    /// sisteminden alıyor — Dizipal (ZySeries) buraya karışmıyor. Sağlayıcı
    /// ayarlardaki güncel adresle kuruluyor, site taşınırsa yeni adres kullanılır.
    private var hdfcProviders: [StreamProvider] {
        settings.enabledStreamProviders.filter { $0.id == "hdfilmcehennemi" }
    }

    /// Sabit 10 sütun: her satırda 10 içerik (ekran genişliğine göre 13 değil).
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 16), count: 10)

    /// Seçili kategorinin bu türdeki kartları — sağ panel filtreleri ve sıralaması
    /// uygulanmış hâlde.
    private var visibleHits: [StreamHit] {
        var hits = store.categoryHits.filter { $0.kind == kind }
        if let minYear { hits = hits.filter { ($0.year ?? 0) >= minYear } }
        if let minRating { hits = hits.filter { ($0.imdbRating ?? 0) >= minRating } }
        switch sort {
        case .none: break
        case .year: hits.sort { ($0.year ?? 0) > ($1.year ?? 0) }
        case .rating: hits.sort { ($0.imdbRating ?? 0) > ($1.imdbRating ?? 0) }
        }
        return hits
    }

    var body: some View {
        Group {
            if hdfcProviders.isEmpty {
                PlaceholderView(
                    title: "HdFilmCehennemi kapalı",
                    detail: "Bu bölümün içeriği HdFilmCehennemi’den gelir. Ayarlar → Akış Kaynakları’ndan açın."
                )
            } else {
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        categoryTabs
                        Divider().opacity(0.3)
                        grid
                    }
                    Divider().opacity(0.3)
                    filterPanel
                }
            }
        }
        .task {
            // Kategorileri yüklemeden önce adresler denetlenir: site taşındıysa
            // eski adrese yapılacak istekler boş dönerdi ve ekran sebebini
            // söylemeden boş kalırdı.
            await StreamDomainTracker.refreshAll(settings: settings)
            await store.loadCategories(for: kind, providers: hdfcProviders)
            if selected == nil { selected = store.categories(for: kind).first }
        }
        .task(id: selected) {
            guard let selected else { return }
            await store.loadCategoryHits(selected)
        }
    }

    @ViewBuilder
    private var categoryTabs: some View {
        if store.categories(for: kind).isEmpty {
            if store.isLoadingCategories {
                HStack { ProgressView().controlSize(.small); Text("Kategoriler yükleniyor…").font(.caption).foregroundStyle(.secondary) }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 22).padding(.vertical, 12)
            }
        } else {
            // Kategoriler yatay tek satırda taşıp ekran dışında kalıyordu; sarmalayan
            // (wrap) düzende hepsi görünür, gerekirse dikey kaydırılır.
            ScrollView(.vertical, showsIndicators: false) {
                FlowLayout(spacing: 8, lineSpacing: 8) {
                    ForEach(store.categories(for: kind)) { category in
                        let isActive = category.id == selected?.id
                        Button { selected = category } label: {
                            Text(category.title)
                                .font(.system(size: 12, weight: isActive ? .bold : .medium))
                                .padding(.horizontal, 13)
                                .frame(height: 30)
                                .background {
                                    Capsule().fill(isActive
                                                   ? AnyShapeStyle(Color.accentColor)
                                                   : AnyShapeStyle(.quaternary.opacity(0.5)))
                                }
                                .foregroundStyle(isActive ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 12)
            }
            .frame(maxHeight: 132)
        }
    }

    @ViewBuilder
    private var grid: some View {
        if store.isLoadingCategoryHits {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if visibleHits.isEmpty {
            PlaceholderView(
                title: kind == .movie ? "Bu kategoride film yok" : "Bu kategoride dizi yok",
                detail: "Başka bir kategori seçin."
            )
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 22) {
                    ForEach(visibleHits) { hit in
                        StreamHitCard(hit: hit, store: store, onOpen: onOpen, library: library)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 20)
            }
        }
    }

    // MARK: - Sağ filtre paneli

    private static let yearOptions: [(String, Int?)] = [
        ("Tümü", nil), ("2025+", 2025), ("2020+", 2020), ("2015+", 2015), ("2010+", 2010), ("2000+", 2000)
    ]
    private static let ratingOptions: [(String, Double?)] = [
        ("Tümü", nil), ("5+", 5), ("6+", 6), ("7+", 7), ("8+", 8)
    ]

    private var filterPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Filtrele")
                    .font(.system(size: 14, weight: .bold))

                filterGroup("Sırala") {
                    ForEach(SortMode.allCases, id: \.self) { mode in
                        chip(mode.rawValue, active: sort == mode) { sort = mode }
                    }
                }
                filterGroup("Yıl") {
                    ForEach(Self.yearOptions, id: \.0) { opt in
                        chip(opt.0, active: minYear == opt.1) { minYear = opt.1 }
                    }
                }
                filterGroup("IMDb Puanı") {
                    ForEach(Self.ratingOptions, id: \.0) { opt in
                        chip(opt.0, active: minRating == opt.1) { minRating = opt.1 }
                    }
                }

                if minYear != nil || minRating != nil || sort != .none {
                    Button("Sıfırla") { minYear = nil; minRating = nil; sort = .none }
                        .font(.system(size: 12, weight: .medium))
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(16)
        }
        .frame(width: 168)
    }

    @ViewBuilder
    private func filterGroup<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            FlowLayout(spacing: 6, lineSpacing: 6) { content() }
        }
    }

    private func chip(_ label: String, active: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: active ? .bold : .medium))
                .padding(.horizontal, 11)
                .frame(height: 26)
                .background {
                    Capsule().fill(active ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary.opacity(0.5)))
                }
                .foregroundStyle(active ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        }
        .buttonStyle(.plain)
    }
}

/// A streaming-site result card. Shared by the ZyStream page and the global
/// search's ZyStream section.
struct StreamHitCard: View {
    let hit: StreamHit
    let store: ZyStreamStore
    /// Opens the title's detail page.
    let onOpen: (StreamHit) -> Void
    /// Optional so callers without a library (rare) can omit favouriting.
    var library: LibraryStore?
    /// Continue-watching progress, drawn as a bar over the poster.
    var progress: Double = 0
    /// Set by the "İzlemeye Devam Et" row so its cards can be dropped.
    var onRemove: (() -> Void)?

    @State private var poster: NSImage?
    @State private var isHovering = false
    @FocusState private var isFocused: Bool

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button {
                onOpen(hit)
            } label: {
                PosterCard(
                    title: hit.title,
                    subtitle: hit.year.map(String.init) ?? hit.kind.label,
                    progress: progress,
                    isFinished: WatchFlagsStore.shared.isFinished(hit.id),
                    watchlisted: WatchFlagsStore.shared.isWantToWatch(hit.id),
                    posterImage: poster,
                    badge: {
                        let badge = StreamRegistry.badge(forProviderID: hit.providerID)
                        return .source(badge.name, tint: Color(hex: badge.hex))
                    }(),
                    audioLabel: hit.audioLabel,
                    imdbRating: hit.imdbRating,
                    isRemovable: onRemove != nil,
                    isFocused: isFocused
                )
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .focused($isFocused)

            if let onRemove, (isHovering || isFocused) {
                PosterCard.removeButton(onRemove)
                    .transition(.opacity)
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .task(id: hit.id) {
            guard let url = hit.posterURL,
                  let base = store.baseURL(forProviderID: hit.providerID) else { return }
            poster = await StreamImageLoader.shared.image(for: url, baseURL: base)
        }
        .contextMenu {
            Button("Aç") { onOpen(hit) }
            Divider()
            let watched = WatchFlagsStore.shared.isFinished(hit.id)
            Button(watched ? "İzlemedim olarak işaretle" : "İzledim") {
                WatchFlagsStore.shared.setFinished(hit.id, !watched, snapshot: .stream(hit))
            }
            let listed = WatchFlagsStore.shared.isWantToWatch(hit.id)
            Button(listed ? "İzleyeceklerimden çıkar" : "İzleyeceğim") {
                WatchFlagsStore.shared.setWantToWatch(hit.id, !listed, snapshot: .stream(hit))
            }
            if let library {
                Divider()
                let fav = library.isStreamFavorite(hit)
                Button(fav ? "Favorilerden çıkar" : "Favorilere ekle") {
                    library.toggleStreamFavorite(hit)
                }
            }
            if let onRemove {
                Divider()
                Button("İzlemeye Devam Et’ten kaldır", action: onRemove)
            }
        }
    }
}

/// Shown over the browser while a chosen title is turned into a playable URL.
struct StreamResolvingOverlay: View {
    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView().controlSize(.large)
                Text("Kaynak çözümleniyor…")
                    .font(.system(size: 13, weight: .medium))
                Text("Oynatıcı adresi siteden alınıyor, bu birkaç saniye sürebilir.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(28)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }
}

/// Season tabs plus an episode list for a series found on a streaming site.
struct StreamEpisodePicker: View {
    let details: StreamDetails
    @Bindable var store: ZyStreamStore
    let resume: PlaybackResumeStore

    @State private var season: Int = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(details.hit.title).font(.headline)
                    Text(details.hit.providerName).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Kapat") { store.closeDetails() }
            }
            .padding()

            if details.seasons.count > 1 {
                SeasonTabs(
                    seasons: details.seasons,
                    selected: effectiveSeason,
                    episodeCount: { details.episodes(inSeason: $0).count },
                    onSelect: { season = $0 }
                )
                .padding(.bottom, 8)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(details.episodes(inSeason: effectiveSeason)) { episode in
                        episodeRow(episode)
                    }
                }
            }

            if let message = store.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 560, height: 560)
    }

    /// Kullanıcının seçtiği sezon listede yoksa (dizi yeniden çözümlendiğinde
    /// olabiliyor) ilk sezona düşülür.
    private var effectiveSeason: Int {
        details.seasons.contains(season) ? season : (details.seasons.first ?? 1)
    }

    private func episodeRow(_ episode: StreamEpisode) -> some View {
        let point = resume.point(forKey: episode.pageURL)
        let progress = point?.progress ?? 0
        let isFinished = point?.isFinished ?? false

        return DetailEpisodeRow(
            stillURL: episode.thumbnailURL,
            number: episode.episode,
            title: episode.title ?? "Bölüm \(episode.episode)",
            duration: progress > 0.01 && !isFinished ? point?.position.asTimecode : nil,
            progress: progress,
            isWatched: isFinished,
            isLoading: store.resolvingID == episode.id
        ) {
            store.playEpisode(episode, from: details)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
    }
}

/// Basit sarmalayan (akış) yerleşim: öğeleri soldan sağa dizer, satıra sığmayınca
/// alt satıra geçer. Kategori etiketleri tek satırda taşıp ekran dışında
/// kalmasın diye — hepsi görünür, gerekirse dikey kaydırılır.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews: subviews, maxWidth: proposal.width ?? .infinity)
        let height = rows.reduce(0) { $0 + $1.height } + CGFloat(max(0, rows.count - 1)) * lineSpacing
        let width = proposal.width ?? rows.map(\.width).max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(subviews: subviews, maxWidth: bounds.width)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for index in row.items {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), anchor: .topLeading,
                                      proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row { var items: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(subviews: Subviews, maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = row.items.isEmpty ? size.width : row.width + spacing + size.width
            if needed > maxWidth, !row.items.isEmpty {
                rows.append(row)
                row = Row(items: [index], width: size.width, height: size.height)
            } else {
                if !row.items.isEmpty { row.width += spacing }
                row.items.append(index)
                row.width += size.width
                row.height = max(row.height, size.height)
            }
        }
        if !row.items.isEmpty { rows.append(row) }
        return rows
    }
}
