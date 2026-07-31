import SwiftUI

/// Apple TV+ originals, split into films and shows.
struct AppleTVView: View {
    let library: LibraryStore
    let appleTV: AppleTVStore
    let actions: LibraryActions

    private enum Tab: String, CaseIterable, Identifiable {
        case movies, shows
        var id: String { rawValue }
        var title: String {
            switch self {
            case .movies: "Filmler"
            case .shows: "Diziler"
            }
        }
    }

    @State private var tab: Tab = .movies

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 260)
            .padding(.top, 16)
            .padding(.bottom, 4)

            switch tab {
            case .movies: grid(appleTV.movies, owned: library.ownedMovieTMDBIDs)
            case .shows:  grid(appleTV.shows, owned: library.ownedShowTMDBIDs)
            }
        }
    }

    @ViewBuilder
    private func grid(_ titles: [RemoteTitle], owned: Set<Int>) -> some View {
        if titles.isEmpty {
            VStack(spacing: 12) {
                if appleTV.isLoading {
                    ProgressView()
                } else {
                    Image(systemName: "appletv")
                        .font(.system(size: 44))
                        .foregroundStyle(.secondary)
                    Text("İçerik alınamadı")
                        .font(.title3.weight(.semibold))
                    Text("Apple TV listesi TMDB'den gelir; Ayarlar'dan jetonun girili olduğundan emin olun.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            PosterGrid(items: titles) { title in
                RemoteCard(
                    title: title,
                    isOwned: owned.contains(title.tmdbID),
                    library: library,
                    onSelect: { actions.selectRemote(title) }
                )
            }
        }
    }
}
