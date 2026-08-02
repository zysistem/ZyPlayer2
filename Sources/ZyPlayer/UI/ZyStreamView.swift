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
                    posterImage: poster,
                    badge: {
                        let badge = StreamRegistry.badge(forProviderID: hit.providerID)
                        return .source(badge.name, tint: Color(hex: badge.hex))
                    }(),
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
            if let library {
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
