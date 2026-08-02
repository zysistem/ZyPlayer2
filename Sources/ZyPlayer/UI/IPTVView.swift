import SwiftUI

/// IPTV bölümü: canlı yayınlar, filmler ve diziler, sağlayıcının kendi
/// kategorileriyle.
struct IPTVView: View {
    let store: IPTVStore
    let settings: AppSettings
    /// Canlı kanal seçildiğinde: kanal ve o an görünen kanal listesi birlikte
    /// gider, oynatıcıdaki liste bunun üzerinden kuruluyor.
    var onPlayChannel: (IPTVChannel, [IPTVChannel]) -> Void
    var onPlayMovie: (IPTVMovie) -> Void
    var onOpenSeries: (IPTVSeries) -> Void

    @State private var section: IPTVSection = .live
    @State private var categoryID: String?
    @State private var search = ""
    @State private var categorySearch = ""

    var body: some View {
        Group {
            if !store.isConfigured {
                PlaceholderView(
                    title: "IPTV bilgileri girilmemiş",
                    detail: "Ayarlar → IP Tv bölümünden sağlayıcınızın adresini ya da "
                          + "kullanıcı adı/parolanızı ekleyin."
                )
            } else if store.catalog.isEmpty {
                loadingOrError
            } else {
                content
            }
        }
        .task { await store.load() }
    }

    private var loadingOrError: some View {
        VStack(spacing: 14) {
            if store.isLoading {
                ProgressView().controlSize(.large)
                Text("İçerikler yükleniyor…")
                    .font(.system(size: 15, weight: .semibold))
                Text("Katalog büyük; ilk yükleme biraz sürebilir, sonrası önbellekten açılır.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "antenna.radiowaves.left.and.right.slash")
                    .font(.system(size: 46))
                    .foregroundStyle(.secondary)
                Text(store.statusMessage.isEmpty ? "İçerik yok" : store.statusMessage)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Button("Yeniden Dene") { Task { await store.load(force: true) } }
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }

    // MARK: - Düzen

    private var content: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.6)
            HStack(spacing: 0) {
                categoryPanel
                Divider().opacity(0.6)
                grid
                    .frame(maxWidth: .infinity)
            }
            .frame(maxHeight: .infinity)
        }
        // Bölüm pencerenin tamamını kaplasın: sarmalayıcı kendi içeriği kadar
        // yer kaplayınca ızgaranın yanında boş şeritler kalıyordu.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ForEach(IPTVSection.allCases) { item in
                    sectionTab(item)
                }

                Spacer(minLength: 12)

                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    TextField("\(section.title) içinde ara", text: $search)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .frame(width: 190)
                    if !search.isEmpty {
                        Button { search = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 11)
                .frame(height: 30)
                .background(.quaternary.opacity(0.45), in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.07), lineWidth: 1))
            }

            HStack(spacing: 8) {
                Text("\(visibleCount) içerik")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                if let name = selectedCategoryName {
                    Text("·").foregroundStyle(.tertiary)
                    Text(name)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if store.isLoading {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                }
                Spacer(minLength: 8)
                if !store.accountLine.isEmpty {
                    Text(store.accountLine)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .padding(.bottom, 12)
    }

    private func sectionTab(_ item: IPTVSection) -> some View {
        let isActive = section == item
        return Button {
            withAnimation(.easeOut(duration: 0.15)) {
                section = item
                categoryID = nil
                search = ""
                categorySearch = ""
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: item.symbol)
                    .font(.system(size: 12, weight: .semibold))
                Text(item.title)
                    .font(.system(size: 13, weight: isActive ? .bold : .medium))
            }
            .foregroundStyle(isActive ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 14)
            .frame(height: 32)
            .background {
                Capsule().fill(isActive
                               ? AnyShapeStyle(Color.accentColor)
                               : AnyShapeStyle(.quaternary.opacity(0.4)))
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Kategoriler

    private var categoryPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                TextField("Kategori ara", text: $categorySearch)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 7))
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 8)

            ScrollView {
                LazyVStack(spacing: 3) {
                    categoryRow(code: nil, name: "Tümü", count: totalCount, id: nil)
                    ForEach(visibleCategories) { category in
                        let parts = IPTVNaming.split(category.name)
                        categoryRow(code: parts.code, name: parts.name,
                                    count: count(in: category.id), id: category.id)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
            }
        }
        .frame(width: 224)
    }

    private func categoryRow(code: String?, name: String, count: Int, id: String?) -> some View {
        let isActive = categoryID == id
        return Button {
            categoryID = id
        } label: {
            HStack(spacing: 7) {
                if let code {
                    Text(code)
                        .font(.system(size: 8.5, weight: .bold))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(isActive ? Color.white.opacity(0.25)
                                               : Color.accentColor.opacity(0.22))
                        )
                        .foregroundStyle(isActive ? AnyShapeStyle(.white) : AnyShapeStyle(.tint))
                }
                Text(name)
                    .font(.system(size: 11.5, weight: isActive ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Text("\(count)")
                    .font(.system(size: 9.5, weight: .medium, design: .rounded))
                    .foregroundStyle(isActive ? AnyShapeStyle(.white.opacity(0.85))
                                              : AnyShapeStyle(.tertiary))
            }
            .foregroundStyle(isActive ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background {
                RoundedRectangle(cornerRadius: 7)
                    .fill(isActive ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.clear))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Izgara

    @ViewBuilder
    private var grid: some View {
        if visibleCount == 0 {
            VStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 34))
                    .foregroundStyle(.tertiary)
                Text(search.isEmpty ? "Bu kategoride içerik yok" : "“\(search)” için sonuç yok")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: section == .live ? 14 : 20) {
                    switch section {
                    case .live:
                        ForEach(filteredChannels) { channel in
                            ChannelTile(channel: channel) {
                                onPlayChannel(channel, filteredChannels)
                            }
                        }
                    case .movies:
                        ForEach(filteredMovies) { movie in
                            PosterTile(title: movie.name, imageURL: movie.iconURL,
                                       rating: movie.rating) {
                                onPlayMovie(movie)
                            }
                        }
                    case .series:
                        ForEach(filteredSeries) { item in
                            PosterTile(title: item.name, imageURL: item.coverURL,
                                       rating: item.rating) {
                                onOpenSeries(item)
                            }
                        }
                    }
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 20)
            }
        }
    }

    /// Sütun sayısı sabit değil, kart genişliğinden çıkıyor: sabit sayıda
    /// sütun dar pencerede kartları okunmaz hâle getiriyor, geniş pencerede de
    /// kenarlarda boşluk bırakıyordu. Kartlar en az bu genişlikte kalıyor,
    /// pencere büyüdükçe yan yana daha çoğu diziliyor.
    private var columns: [GridItem] {
        let minimum: CGFloat = section == .live ? 230 : 165
        return [GridItem(.adaptive(minimum: minimum), spacing: 16)]
    }

    // MARK: - Süzme

    private func matches(_ name: String) -> Bool {
        let trimmed = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        return name.localizedCaseInsensitiveContains(trimmed)
    }

    private var visibleCategories: [IPTVCategory] {
        let all = store.categories(for: section)
        let trimmed = categorySearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
    }

    private var filteredChannels: [IPTVChannel] {
        store.channels(categoryID: categoryID).filter { matches($0.name) }
    }
    private var filteredMovies: [IPTVMovie] {
        store.movies(categoryID: categoryID).filter { matches($0.name) }
    }
    private var filteredSeries: [IPTVSeries] {
        store.series(categoryID: categoryID).filter { matches($0.name) }
    }

    private var visibleCount: Int {
        switch section {
        case .live: filteredChannels.count
        case .movies: filteredMovies.count
        case .series: filteredSeries.count
        }
    }

    private var totalCount: Int {
        switch section {
        case .live: store.catalog.channels.count
        case .movies: store.catalog.movies.count
        case .series: store.catalog.series.count
        }
    }

    private func count(in categoryID: String) -> Int {
        switch section {
        case .live: store.channels(categoryID: categoryID).count
        case .movies: store.movies(categoryID: categoryID).count
        case .series: store.series(categoryID: categoryID).count
        }
    }

    private var selectedCategoryName: String? {
        guard let categoryID,
              let category = store.categories(for: section).first(where: { $0.id == categoryID })
        else { return nil }
        return IPTVNaming.split(category.name).name
    }
}

// MARK: - Kartlar

/// Canlı kanal. Logolar saydam ve çoğu koyu zemin için çizilmiş; koyu bir
/// yüzeye ortalanıyor, afiş gibi kırpılmıyor.
private struct ChannelTile: View {
    let channel: IPTVChannel
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        let parts = IPTVNaming.split(channel.name)
        let quality = IPTVNaming.splitQuality(parts.name)

        Button(action: action) {
            VStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.black.opacity(0.35))

                    if let url = channel.iconURL {
                        CachedAsyncImage(url: url) { image in
                            image.resizable().aspectRatio(contentMode: .fit).padding(14)
                        } placeholder: {
                            Image(systemName: "tv")
                                .font(.system(size: 20))
                                .foregroundStyle(.tertiary)
                        }
                    } else {
                        Image(systemName: "tv")
                            .font(.system(size: 20))
                            .foregroundStyle(.tertiary)
                    }

                    if isHovering {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(.black.opacity(0.35))
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(.white)
                    }
                }
                // Logolar 16:9'a yakın çizilmiş; oranı karta bırakmak yerine
                // sabitlemek, farklı boyuttaki logoların aynı hizada durmasını
                // sağlıyor.
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(isHovering ? Color.accentColor : .white.opacity(0.08),
                                      lineWidth: isHovering ? 2 : 1)
                )

                HStack(spacing: 5) {
                    Text(quality.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let tag = quality.quality {
                        Text(tag)
                            .font(.system(size: 8, weight: .bold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1.5)
                            .background(Color.accentColor.opacity(0.9),
                                        in: RoundedRectangle(cornerRadius: 3))
                            .foregroundStyle(.white)
                    }
                    Spacer(minLength: 0)
                }
            }
            .scaleEffect(isHovering ? 1.04 : 1)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
        }
    }
}

/// Film ve dizi afişi: 2:3 oran, üzerine gelince oynat işareti.
private struct PosterTile: View {
    let title: String
    let imageURL: URL?
    let rating: Double?
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 7) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.quaternary.opacity(0.5))

                    if let imageURL {
                        CachedAsyncImage(url: imageURL) { image in
                            image.resizable().aspectRatio(contentMode: .fill)
                        } placeholder: {
                            Image(systemName: "film")
                                .font(.system(size: 22))
                                .foregroundStyle(.tertiary)
                        }
                    } else {
                        Image(systemName: "film")
                            .font(.system(size: 22))
                            .foregroundStyle(.tertiary)
                    }

                    if isHovering {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(.black.opacity(0.35))
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(.white)
                    }
                }
                .aspectRatio(2.0 / 3.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(isHovering ? Color.accentColor : .white.opacity(0.08),
                                      lineWidth: isHovering ? 2 : 1)
                )
                .overlay(alignment: .topTrailing) {
                    if let rating, rating > 0 {
                        Text(String(format: "%.1f", rating))
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(.black.opacity(0.65), in: Capsule())
                            .foregroundStyle(.yellow)
                            .padding(6)
                    }
                }
                .shadow(color: .black.opacity(isHovering ? 0.35 : 0), radius: 10, y: 4)

                Text(IPTVNaming.split(title).name)
                    .font(.system(size: 12))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scaleEffect(isHovering ? 1.03 : 1)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
        }
    }
}

/// Bir IPTV dizisinin sezon/bölüm listesi.
struct IPTVEpisodePicker: View {
    let series: IPTVSeries
    let store: IPTVStore
    let onPlay: (IPTVEpisode) -> Void
    let onClose: () -> Void

    @State private var seasons: [Int: [IPTVEpisode]] = [:]
    @State private var selectedSeason: Int?
    @State private var isLoading = true

    private var seasonNumbers: [Int] { seasons.keys.sorted() }
    private var current: Int { selectedSeason ?? seasonNumbers.first ?? 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                if let cover = series.coverURL {
                    CachedAsyncImage(url: cover) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Color.clear
                    }
                    .frame(width: 54, height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(IPTVNaming.split(series.name).name)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(2)
                    if let plot = series.plot, !plot.isEmpty {
                        Text(plot)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                }
                Spacer(minLength: 0)
                Button("Kapat") { onClose() }.keyboardShortcut(.cancelAction)
            }

            if isLoading {
                ProgressView("Bölümler alınıyor…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if seasons.isEmpty {
                Text("Bu dizi için bölüm bulunamadı.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                if seasonNumbers.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 7) {
                            ForEach(seasonNumbers, id: \.self) { number in
                                let isActive = number == current
                                Button {
                                    selectedSeason = number
                                } label: {
                                    Text("Sezon \(number)")
                                        .font(.system(size: 11, weight: isActive ? .bold : .medium))
                                        .padding(.horizontal, 11)
                                        .frame(height: 26)
                                        .background {
                                            Capsule().fill(isActive
                                                           ? AnyShapeStyle(Color.accentColor)
                                                           : AnyShapeStyle(.quaternary.opacity(0.5)))
                                        }
                                        .foregroundStyle(isActive ? AnyShapeStyle(.white)
                                                                  : AnyShapeStyle(.primary))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                ScrollView {
                    LazyVStack(spacing: 5) {
                        ForEach(seasons[current] ?? []) { episode in
                            EpisodeRow(episode: episode) { onPlay(episode) }
                        }
                    }
                }
            }
        }
        .padding(18)
        .frame(width: 600, height: 540)
        .task {
            seasons = await store.episodes(for: series)
            isLoading = false
        }
    }

    private struct EpisodeRow: View {
        let episode: IPTVEpisode
        let action: () -> Void
        @State private var isHovering = false

        var body: some View {
            Button(action: action) {
                HStack(spacing: 11) {
                    Text("\(episode.episode)")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .frame(width: 26)
                        .foregroundStyle(.secondary)
                    Text(episode.title)
                        .font(.system(size: 12))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "play.circle.fill")
                        .foregroundStyle(isHovering ? AnyShapeStyle(.tint)
                                                    : AnyShapeStyle(.tertiary))
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isHovering ? Color.accentColor.opacity(0.14)
                                         : Color.gray.opacity(0.12))
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }
        }
    }
}

/// Arama sonuçlarındaki IPTV kartı. Rozet zorunlu: aynı ad hem canlı kanal
/// hem film olarak çıkabildiği için hangisine bastığın belli olmalı.
struct IPTVSearchCard: View {
    let title: String
    let imageURL: URL?
    let badge: String
    let badgeColor: Color
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.black.opacity(0.3))
                    if let imageURL {
                        CachedAsyncImage(url: imageURL) { image in
                            image.resizable().aspectRatio(contentMode: .fit).padding(10)
                        } placeholder: {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .foregroundStyle(.tertiary)
                        }
                    } else {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .foregroundStyle(.tertiary)
                    }
                    if isHovering {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(.black.opacity(0.35))
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(.white)
                    }
                }
                .frame(height: 108)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(isHovering ? Color.accentColor : .white.opacity(0.08),
                                      lineWidth: isHovering ? 2 : 1)
                )
                .overlay(alignment: .topLeading) {
                    Text(badge)
                        .font(.system(size: 8.5, weight: .bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(badgeColor, in: Capsule())
                        .foregroundStyle(.white)
                        .padding(6)
                }

                Text(IPTVNaming.split(title).name)
                    .font(.system(size: 11))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scaleEffect(isHovering ? 1.03 : 1)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
        }
    }
}
