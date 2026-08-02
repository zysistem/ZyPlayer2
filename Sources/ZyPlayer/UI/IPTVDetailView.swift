import SwiftUI

/// Bir IPTV filminin ya da dizisinin detay sayfası.
///
/// Ayrıntıların çoğu sağlayıcıdan geliyor — özet, oyuncular, tür, süre ve
/// bölüm ekran fotoğrafları hazır. TMDB yalnızca afiş ve arka planı
/// tazelemek için kullanılıyor: sağlayıcının görselleri düşük çözünürlüklü.
struct IPTVDetailView: View {
    enum Target: Hashable {
        case movie(IPTVMovie)
        case series(IPTVSeries)
    }

    let target: Target
    let store: IPTVStore
    let onBack: () -> Void
    let onPlayMovie: (IPTVMovie) -> Void
    let onPlayEpisode: (IPTVEpisode, String) -> Void
    /// Fragman TMDB'den geliyor: sağlayıcının `youtube_trailer` alanı
    /// kataloğun tamamında boş. Kimlik bildirilmemişse düğme hiç çıkmıyor.
    var onTrailer: ((Int, Bool) -> Void)?
    var isTrailerLoading: Bool = false
    /// Kaldığı yer ve izlendi durumu.
    var resume: PlaybackResumeStore?

    @State private var detail: IPTVDetail?
    @State private var episodes: [Int: [IPTVEpisode]] = [:]
    @State private var selectedSeason: Int?
    @State private var isLoading = true

    private var title: String {
        switch target {
        case .movie(let movie): IPTVNaming.split(movie.name).name
        case .series(let series): IPTVNaming.split(series.name).name
        }
    }

    private var fallbackPoster: URL? {
        switch target {
        case .movie(let movie): movie.iconURL
        case .series(let series): series.coverURL
        }
    }

    private var favorite: IPTVFavorite {
        switch target {
        case .movie(let movie):
            IPTVFavorite(kind: .movie, streamID: movie.id, name: movie.name,
                         iconURLString: movie.iconURLString,
                         containerExtension: movie.containerExtension)
        case .series(let series):
            IPTVFavorite(kind: .series, streamID: series.id, name: series.name,
                         iconURLString: series.coverURLString)
        }
    }

    private var seasonNumbers: [Int] { episodes.keys.sorted() }
    private var currentSeason: Int { selectedSeason ?? seasonNumbers.first ?? 1 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                hero
                if case .series = target {
                    seasonPicker
                    episodeList
                }
            }
        }
        .task(id: target) { await load() }
    }

    // MARK: - Üst bölüm

    /// Arka plan bir `background` katmanı: içeriğin üstüne yerleştirilen sabit
    /// yükseklikli bir yığında, `fill` ile büyüyen görsel çerçeveden taşıp
    /// altındaki bölüm listesini bozuyor ve geri düğmesini örtüyordu. Yükseklik
    /// de sabit değil — özet ve oyuncu satırları uzayınca künye sıkışıyordu.
    private var hero: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                backButton
                Spacer(minLength: 0)
            }
            .padding(20)

            Spacer(minLength: 30)

            HStack(alignment: .bottom, spacing: 18) {
                poster
                info
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 22)
        }
        .frame(maxWidth: .infinity, minHeight: 430, alignment: .topLeading)
        .background {
            ZStack {
                backdrop
                LinearGradient(colors: [.black.opacity(0.25), .black.opacity(0.92)],
                               startPoint: .top, endPoint: .bottom)
            }
        }
        .clipped()
    }

    private var backButton: some View {
        Button(action: onBack) {
            HStack(spacing: 5) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .bold))
                Text("Geri")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(.black.opacity(0.55), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .keyboardShortcut(.cancelAction)
    }

    @ViewBuilder
    private var backdrop: some View {
        if let url = detail?.backdropURL {
            CachedAsyncImage(url: url) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                LinearGradient(colors: [Color(white: 0.2), Color(white: 0.08)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        } else {
            LinearGradient(colors: [Color(white: 0.2), Color(white: 0.08)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    private var poster: some View {
        CachedAsyncImage(url: detail?.posterURL ?? fallbackPoster) { image in
            image.resizable().aspectRatio(contentMode: .fill)
        } placeholder: {
            ZStack {
                Color(white: 0.16)
                Image(systemName: "film").font(.system(size: 26)).foregroundStyle(.secondary)
            }
        }
        .frame(width: 150, height: 225)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(.white.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.5), radius: 12, y: 6)
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 27, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(2)

            HStack(spacing: 10) {
                if let year = detail?.year {
                    metaChip(String(year))
                }
                if let genre = detail?.genre, !genre.isEmpty {
                    metaChip(genre)
                }
                if let duration = detail?.durationText, !duration.isEmpty {
                    metaChip(duration)
                }
                if let rating = detail?.rating, rating > 0 {
                    HStack(spacing: 3) {
                        Image(systemName: "star.fill").font(.system(size: 9))
                        Text(String(format: "%.1f", rating))
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(.yellow)
                }
                if isLoading { ProgressView().controlSize(.small).scaleEffect(0.7) }
            }

            if let plot = detail?.plot, !plot.isEmpty {
                Text(plot)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(4)
                    .frame(maxWidth: 560, alignment: .leading)
            }

            if let cast = detail?.castNames, !cast.isEmpty {
                Text("Oyuncular: " + cast.prefix(5).joined(separator: ", "))
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
            if let director = detail?.director, !director.isEmpty {
                Text("Yönetmen: " + director)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }

            HStack(spacing: 10) {
                if case .movie(let movie) = target {
                    let point = resume?.point(forKey: "iptv:movie:\(movie.id)")
                    Button {
                        onPlayMovie(movie)
                    } label: {
                        Label(point.map { $0.isFinished ? "Yeniden Oynat" : "Devam Et" } ?? "Oynat",
                              systemImage: "play.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .padding(.horizontal, 18)
                            .frame(height: 34)
                    }
                    .buttonStyle(.borderedProminent)
                    .focusEffectDisabled()
                }

                if let tmdbID = detail?.tmdbID, let onTrailer {
                    TrailerButton(isLoading: isTrailerLoading) {
                        if case .movie = target { onTrailer(tmdbID, true) }
                        else { onTrailer(tmdbID, false) }
                    }
                }

                let isFavorite = store.isFavorite(favorite)
                Button {
                    store.toggleFavorite(favorite)
                } label: {
                    Label(isFavorite ? "Favorilerde" : "Favorilere Ekle",
                          systemImage: isFavorite ? "star.fill" : "star")
                        .font(.system(size: 13, weight: .medium))
                        .padding(.horizontal, 14)
                        .frame(height: 34)
                }
                .buttonStyle(.bordered)
                .focusEffectDisabled()
            }
            .padding(.top, 4)
        }
    }

    private func metaChip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.white.opacity(0.16), in: Capsule())
    }

    // MARK: - Bölümler

    @ViewBuilder
    private var seasonPicker: some View {
        if seasonNumbers.count == 1, let only = seasonNumbers.first {
            // Tek sezonluk dizide sekme çizmenin anlamı yok ama başlıksız da
            // kalmamalı: aşağıdaki listenin neye ait olduğu yazsın.
            Text("Sezon \(only) · \(episodes[only]?.count ?? 0) bölüm")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 24)
                .padding(.top, 20)
        } else if seasonNumbers.count > 1 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(seasonNumbers, id: \.self) { number in
                        let isActive = number == currentSeason
                        Button {
                            selectedSeason = number
                        } label: {
                            Text("Sezon \(number)")
                                .font(.system(size: 12, weight: isActive ? .bold : .medium))
                                .padding(.horizontal, 13)
                                .frame(height: 30)
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
                .padding(.horizontal, 24)
            }
            .padding(.top, 20)
        }
    }

    @ViewBuilder
    private var episodeList: some View {
        if isLoading && episodes.isEmpty {
            ProgressView("Bölümler alınıyor…")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
        } else if episodes.isEmpty {
            Text("Bu dizi için bölüm bulunamadı.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
        } else {
            LazyVStack(spacing: 10) {
                ForEach(episodes[currentSeason] ?? []) { episode in
                    let point = resume?.point(forKey: "iptv:episode:\(episode.id)")
                    EpisodeRow(episode: episode,
                               progress: point?.progress ?? 0,
                               isWatched: point?.isFinished ?? false) {
                        onPlayEpisode(episode, title)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 18)
            .padding(.bottom, 28)
        }
    }

    /// Tek bölüm: solda ekran fotoğrafı, sağda adı ve özeti.
    private struct EpisodeRow: View {
        let episode: IPTVEpisode
        /// 0–1 arası izlenen kısım; izlendi işareti ayrı, çünkü sona yaklaşan
        /// bir bölüm de "izlendi" sayılıyor.
        var progress: Double = 0
        var isWatched: Bool = false
        let action: () -> Void

        @State private var isHovering = false

        var body: some View {
            Button(action: action) {
                HStack(alignment: .top, spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color(white: 0.14))
                        if let still = episode.stillURL {
                            CachedAsyncImage(url: still) { image in
                                image.resizable().aspectRatio(contentMode: .fill)
                            } placeholder: {
                                Image(systemName: "photo")
                                    .font(.system(size: 16))
                                    .foregroundStyle(.tertiary)
                            }
                        } else {
                            Image(systemName: "play.rectangle")
                                .font(.system(size: 18))
                                .foregroundStyle(.tertiary)
                        }
                        if isHovering {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(.black.opacity(0.4))
                            Image(systemName: "play.circle.fill")
                                .font(.system(size: 26))
                                .foregroundStyle(.white)
                        }
                    }
                    .frame(width: 168, height: 95)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(alignment: .bottom) {
                        // Kaldığı yer, ekran fotoğrafının altında ince bir şerit.
                        if progress > 0.01 && !isWatched {
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Rectangle().fill(.black.opacity(0.55))
                                    Rectangle().fill(Color.accentColor)
                                        .frame(width: geo.size.width * progress)
                                }
                            }
                            .frame(height: 4)
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        if isWatched {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 15))
                                .foregroundStyle(.white, .green)
                                .padding(5)
                        }
                    }
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(isHovering ? Color.accentColor : .white.opacity(0.08),
                                      lineWidth: isHovering ? 2 : 1))

                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 8) {
                            Text("\(episode.episode). Bölüm")
                                .font(.system(size: 13, weight: .semibold))
                            if let duration = episode.durationText, !duration.isEmpty {
                                Text(duration)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text(episode.title)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if let plot = episode.plot, !plot.isEmpty {
                            Text(plot)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                                .multilineTextAlignment(.leading)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(isHovering ? Color.accentColor.opacity(0.10) : Color.gray.opacity(0.10))
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
            }
        }
    }

    // MARK: - Yükleme

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        switch target {
        case .movie(let movie):
            detail = await store.detail(for: movie)
        case .series(let series):
            guard let result = await store.detail(for: series) else { return }
            detail = result.detail
            episodes = result.episodes
        }
    }
}
