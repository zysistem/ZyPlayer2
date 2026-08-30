import SwiftUI

/// TurkTorrent RSS beslemesindeki güncel filmleri/dizileri listeler.
/// Başlıklar otomatik olarak TMDB üzerinde aranır ve afişlerle eşleştirilir.
struct ZyMovieView: View {
    let library: LibraryStore
    let store: ZyMovieStore
    let settings: AppSettings
    let player: PlayerModel
    let streamer: TorrentStreamer
    let torrents: TorrentStore
    /// İzlenen torrent'ler burada da devam noktası bıraksın diye — yoksa
    /// "İzledim" sekmesi bu içerikleri hiç göremiyordu.
    var resume: PlaybackResumeStore?

    var selectedIndex: Int = -1
    /// Kumandanın seçim tuşu sayacı. Hangi içeriğin seçili olduğunu bu ekran
    /// bilir (arama süzgeci listeyi değiştiriyor), bu yüzden seçimi RootView
    /// yapamaz: yalnızca "seç" der, öğeyi buradaki liste belirler.
    var selectTick: Int = 0
    var onOpenRemoteTitle: (RemoteTitle) -> Void = { _ in }
    
    @State private var hoveredHit: ZyMovieHit?
    @State private var selectedHit: ZyMovieHit?
    @State private var searchText = ""
    @State private var tmdbSearchResults: [ZyMovieHit] = []
    
    private var filteredHits: [ZyMovieHit] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return store.hits }
        let query = trimmed.lowercased()
        return store.hits.filter { hit in
            hit.rssTitle.lowercased().contains(query) ||
            (hit.remoteTitle?.title.lowercased().contains(query) ?? false)
        }
    }

    private var combinedHits: [ZyMovieHit] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return store.hits }
        
        var combined = filteredHits
        let localIDs = Set(combined.map(\.id))
        for item in tmdbSearchResults {
            if !localIDs.contains(item.id) {
                combined.append(item)
            }
        }
        return combined
    }

    private var filteredFavorites: [ZyMovieHit] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return store.favorites }
        let query = trimmed.lowercased()
        return store.favorites.filter { hit in
            hit.rssTitle.lowercased().contains(query) ||
            (hit.remoteTitle?.title.lowercased().contains(query) ?? false)
        }
    }

    var body: some View {
        ZStack {
            if store.isLoading && store.hits.isEmpty {
                ProgressView("RSS Yükleniyor...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = store.statusMessage {
                PlaceholderView(
                    title: "Hata",
                    detail: error
                )
            } else if store.hits.isEmpty {
                PlaceholderView(
                    title: "ZyMovie",
                    detail: "Gösterilecek içerik bulunamadı."
                )
            } else if let selected = selectedHit {
                ZyMovieDetailView(
                    hit: selected,
                    library: library,
                    store: store,
                    torrents: torrents,
                    streamer: streamer,
                    player: player,
                    resume: resume,
                    onBack: { selectedHit = nil },
                    onOpenRemoteTitle: { remote in
                        selectedHit = nil
                        onOpenRemoteTitle(remote)
                    }
                )
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        // ZyMovie Search & Category Header
                        headerAndFilterBar

                        if !filteredFavorites.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                HStack(spacing: 8) {
                                    Image(systemName: "star.fill")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(.yellow)
                                    Text("Favoriler")
                                        .font(.system(size: 17, weight: .semibold))
                                    Text("\(filteredFavorites.count) içerik")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                
                                // İmleç yalnızca aşağıdaki ana listede gezinir.
                                // Aynı indeksi buraya da vermek iki ızgarada
                                // birden kart vurguluyor, hangisinin seçileceği
                                // belirsiz kalıyordu.
                                PosterGrid(items: filteredFavorites, selectedIndex: -1, embedsInScrollView: false) { hit, isGamepadSelected in
                                    ZStack(alignment: .topTrailing) {
                                        Button {
                                            selectedHit = hit
                                        } label: {
                                            let titleText = hit.remoteTitle?.title ?? hit.rssTitle
                                            let subtitle = generateSubtitle(for: hit)
                                            let season = extractSeason(from: hit.rssTitle)
                                            let is4K = extractIs4K(from: hit.rssTitle)
                                            
                                            PosterCard(
                                                title: titleText,
                                                subtitle: subtitle,
                                                isFinished: WatchFlagsStore.shared.isFinished(hit.rssLink),
                                                seasonBadge: season,
                                                is4K: is4K,
                                                watchlisted: WatchFlagsStore.shared.isWantToWatch(hit.rssLink),
                                                posterURL: hit.remoteTitle?.posterURL,
                                                isFocused: false,
                                                isGamepadSelected: isGamepadSelected
                                            )
                                        }
                                        .buttonStyle(.plain)
                                        .focusEffectDisabled()
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
                                        Divider()
                                        Button(store.isFavorite(hit) ? "Favorilerden Çıkar" : "Favorilere Ekle") {
                                            store.toggleFavorite(hit)
                                        }
                                        Button("İndirmeyi Başlat") {
                                            Task { await torrents.add(hit.rssLink, library: library) }
                                        }
                                        Button("Hemen Oynat") {
                                            selectedHit = hit
                                        }
                                    }
                                }
                            }
                        }
                        
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 8) {
                                Image(systemName: "film.stack")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                Text(searchText.isEmpty ? "Güncel İçerikler" : "Arama Sonuçları")
                                    .font(.system(size: 17, weight: .semibold))
                                Text("\(combinedHits.count) içerik")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            
                            PosterGrid(items: combinedHits, selectedIndex: selectedIndex, embedsInScrollView: false) { hit, isGamepadSelected in
                                ZStack(alignment: .topTrailing) {
                                    Button {
                                        selectedHit = hit
                                    } label: {
                                        let titleText = hit.remoteTitle?.title ?? hit.rssTitle
                                        let subtitle = generateSubtitle(for: hit)
                                        let season = extractSeason(from: hit.rssTitle)
                                        let is4K = extractIs4K(from: hit.rssTitle)
                                        
                                        PosterCard(
                                            title: titleText,
                                            subtitle: subtitle,
                                            isFinished: WatchFlagsStore.shared.isFinished(hit.rssLink),
                                            seasonBadge: season,
                                            is4K: is4K,
                                            watchlisted: WatchFlagsStore.shared.isWantToWatch(hit.rssLink),
                                            posterURL: hit.remoteTitle?.posterURL,
                                            isFocused: false, // Local state handles hover
                                            isGamepadSelected: isGamepadSelected
                                        )
                                    }
                                    .buttonStyle(.plain)
                                    .focusEffectDisabled()

                                    // Torrent details hover tooltip
                                    if hoveredHit == hit {
                                        Text(hit.rssDescription)
                                            .font(.caption2)
                                            .padding(6)
                                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
                                            .offset(x: 10, y: -10)
                                    }
                                }
                                .onHover { isHovering in
                                    hoveredHit = isHovering ? hit : nil
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
                                    Divider()
                                    Button(store.isFavorite(hit) ? "Favorilerden Çıkar" : "Favorilere Ekle") {
                                        store.toggleFavorite(hit)
                                    }
                                    Button("İndirmeyi Başlat") {
                                        Task {
                                            await torrents.add(hit.rssLink, library: library)
                                        }
                                    }
                                    Button("Hemen Oynat") {
                                        selectedHit = hit
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.vertical, 18)
                }
            }
        }
        .task {
            await store.refresh(settings: settings)
        }
        .onChange(of: selectTick) { _, _ in
            // İmleç ana listenin üzerinde geziniyor; vurgulanan kart hangisiyse
            // o açılır. Kırpma PosterGrid'dekiyle aynı olmalı, yoksa görünen
            // kart ile açılan içerik ayrışır.
            guard selectedIndex >= 0, !combinedHits.isEmpty else { return }
            selectedHit = combinedHits[min(selectedIndex, combinedHits.count - 1)]
        }
        .onChange(of: searchText) { _, newValue in
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                tmdbSearchResults = []
                return
            }
            Task {
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard searchText == newValue else { return }
                let results = await store.searchTMDBHits(query: newValue, settings: settings)
                await MainActor.run {
                    self.tmdbSearchResults = results
                }
            }
        }
    }

    private var headerAndFilterBar: some View {
        VStack(spacing: 12) {
            // ZyMovie Search Bar
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)

                TextField("ZyMovie içinde ara... (Örn: Silo, Foundation, 4K)", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium))

                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.separator.opacity(0.5), lineWidth: 1)
            )

            // Category Filter Pills
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(ZyMovieCategory.allCases) { category in
                        let isSelected = store.selectedCategory == category
                        Button {
                            Task {
                                await store.selectCategory(category, settings: settings)
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: category.symbol)
                                    .font(.system(size: 11, weight: .bold))
                                Text(category.rawValue)
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            .foregroundStyle(isSelected ? .white : .secondary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(isSelected ? Color.blue : Color.white.opacity(0.08), in: Capsule())
                            .overlay(Capsule().strokeBorder(isSelected ? .blue.opacity(0.8) : .white.opacity(0.12), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 2)
            }
        }
    }
}

extension ZyMovieView {
    private func extractSeason(from title: String) -> String? {
        if let range = title.range(of: "S(\\d+)", options: .regularExpression) {
            let matched = String(title[range])
            let numStr = matched.dropFirst()
            if let num = Int(numStr) {
                return "SEZON \(num)"
            }
            return matched
        }
        return nil
    }

    private func extractIs4K(from title: String) -> Bool {
        title.localizedCaseInsensitiveContains("2160p") || title.localizedCaseInsensitiveContains("4k")
    }

    private func generateSubtitle(for hit: ZyMovieHit) -> String {
        var typeStr = ""
        if let kind = hit.remoteTitle?.kind {
            typeStr = kind == .movie ? "Film" : "Dizi"
        } else {
            typeStr = "Torrent"
        }
        
        var parts: [String] = []
        if let year = hit.remoteTitle?.year { parts.append(String(year)) }
        parts.append(typeStr)
        
        return parts.joined(separator: " · ")
    }
}
