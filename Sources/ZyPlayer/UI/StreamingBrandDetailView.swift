import SwiftUI

/// Sidebar'daki tek bir yayın platformu sayfası (Netflix, Amazon Prime,
/// Disney+, HBO Max, Apple TV+): Filmler/Diziler sekmeleri, her birinde
/// TMDB'nin en yeni 50 başlığı.
struct StreamingBrandDetailView: View {
    let brand: StreamingBrand
    @Bindable var providers: StreamingProviderStore
    let library: LibraryStore
    let settings: AppSettings
    let actions: LibraryActions
    var selectedIndex: Int = -1

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

    private var detail: StreamingProviderStore.BrandDetail { providers.detail(for: brand) }

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
            case .movies: grid(detail.movies, owned: library.ownedMovieTMDBIDs)
            case .shows:  grid(detail.shows, owned: library.ownedShowTMDBIDs)
            }
        }
        // RootView'daki switch, dört marka için tek bir case dalını paylaşıyor;
        // `id` olmadan SwiftUI bunu aynı görünüm kimliği sayıp bir markadan
        // ötekine geçince `.task`'ı yeniden çalıştırmıyordu — yalnızca ilk
        // açılan markanın verisi geliyordu. `id(brand)` her markayı ayrı bir
        // görünüm kimliğine zorlayıp sekme seçimini de sıfırlıyor.
        .id(brand)
        .task(id: brand) { await providers.refreshDetail(for: brand, settings: settings) }
    }

    @ViewBuilder
    private func grid(_ titles: [RemoteTitle], owned: Set<Int>) -> some View {
        if titles.isEmpty {
            VStack(spacing: 12) {
                if detail.isLoading {
                    ProgressView()
                } else {
                    StreamingBrandBadge(brand: brand, logoURL: providers.logoURL(for: brand), size: 44)
                    Text("İçerik alınamadı")
                        .font(.title3.weight(.semibold))
                    Text("\(brand.displayName) listesi TMDB'den gelir; Ayarlar'dan jetonun girili olduğundan emin olun.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            PosterGrid(items: titles, selectedIndex: selectedIndex) { title, isGamepadSelected in
                RemoteCard(
                    title: title,
                    isOwned: owned.contains(title.tmdbID),
                    library: library,
                    onSelect: { actions.selectRemote(title) },
                    isGamepadSelected: isGamepadSelected
                )
            }
        }
    }
}
