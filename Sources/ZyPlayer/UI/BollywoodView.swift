import SwiftUI

/// Hindistan yapımı filmler: gelecek gösterimdekiler önce, çıkmış olanlar sonra.
///
/// Liste her açılışta yeniden çekiliyor (`.task` sekmeye her girişte çalışır),
/// böylece vizyon takvimi bayatlamıyor.
struct BollywoodView: View {
    let library: LibraryStore
    let store: BollywoodStore
    let settings: AppSettings
    let actions: LibraryActions

    var body: some View {
        Group {
            if store.all.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        if !store.upcoming.isEmpty {
                            section(
                                title: "Gelecek Gösterimde",
                                subtitle: "Vizyon tarihi yaklaşan \(store.upcoming.count) film",
                                symbol: "calendar",
                                titles: store.upcoming
                            )
                        }
                        if !store.released.isEmpty {
                            section(
                                title: "Gösterimde ve Çıkmış Olanlar",
                                subtitle: "Şu an en çok ilgi gören \(store.released.count) film",
                                symbol: "film",
                                titles: store.released
                            )
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.vertical, 18)
                }
            }
        }
        .task { await store.refresh(settings: settings) }
    }

    @ViewBuilder
    private func section(title: String, subtitle: String,
                         symbol: String, titles: [RemoteTitle]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            let owned = library.ownedMovieTMDBIDs
            PosterGrid(items: titles) { title in
                RemoteCard(
                    title: title,
                    isOwned: owned.contains(title.tmdbID),
                    library: library,
                    imdbRating: store.imdbRating(for: title.tmdbID),
                    onSelect: { actions.selectRemote(title) }
                )
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            if store.isLoading {
                ProgressView()
            } else {
                Image(systemName: "movieclapper")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)
                Text("İçerik alınamadı")
                    .font(.title3.weight(.semibold))
                Text("Bollywood listesi TMDB'den gelir; Ayarlar'dan jetonun girili olduğundan emin olun.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
