import SwiftUI

/// Poster-shaped card. Artwork is a placeholder until TMDB lands in Phase 3.
struct PosterCard: View {
    let title: String
    let subtitle: String
    var progress: Double = 0
    var isFinished: Bool = false
    /// Season indicator tag (e.g. "S01", "S02") drawn on the top-left corner.
    var seasonBadge: String? = nil
    /// 4K indicator tag drawn on the top-right corner.
    var is4K: Bool = false
    /// Drawn as a bookmark tag when the item is on the watchlist and not yet
    /// watched.
    var watchlisted: Bool = false
    var posterFileName: String?
    /// Remote artwork, for cards that aren't library items (In Cinemas).
    var posterURL: URL?
    /// An already-decoded image, used by ZyStream — its posters are Cloudflare-
    /// gated and must be fetched through the cleared web view, not `AsyncImage`.
    var posterImage: NSImage?
    /// A corner tag such as "Kütüphanede" or a trending flame.
    var badge: PosterBadge?
    /// IMDb puanı; afişin sol alt köşesinde küçük bir etiket olarak çizilir.
    var imdbRating: Double?
    /// Set while a remove button is drawn over the card, so the badge underneath
    /// does not show through it.
    var isRemovable: Bool = false
    var isFocused: Bool = false
    var isGamepadSelected: Bool = false

    @State private var isHovering = false
    @FocusState private var isFocusState: Bool

    private var isGamepadFocused: Bool {
        GamepadManager.shared.isConnected && (isGamepadSelected || isFocused || isFocusState)
    }

    private var strokeColor: Color {
        if isGamepadFocused {
            return Color.cyan
        }
        return isHovering ? .white.opacity(0.8) : .white.opacity(0.08)
    }

    private var strokeWidth: CGFloat {
        isGamepadFocused ? 3.5 : (isHovering ? 1.5 : 1)
    }

    private var isHighlighted: Bool {
        isHovering || isGamepadFocused
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottom) {
                artwork
                    .aspectRatio(2.0 / 3.0, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(strokeColor, lineWidth: strokeWidth)
                    )
                    .shadow(color: isGamepadFocused ? .cyan.opacity(0.7) : .black.opacity(0), radius: isGamepadFocused ? 16 : 0)

                if progress > 0.01 && !isFinished {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Rectangle().fill(.black.opacity(0.5))
                            Rectangle()
                                .fill(isHighlighted ? Color.cyan : .white)
                                .frame(width: geo.size.width * progress)
                        }
                    }
                    .frame(height: 4)
                    .clipShape(RoundedRectangle(cornerRadius: 2))
                    .padding(.horizontal, 6)
                    .padding(.bottom, 6)
                }
            }
            .overlay(alignment: .topTrailing) {
                if isRemovable && isHighlighted {
                    EmptyView()
                } else if isFinished {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.white, .blue)
                        .padding(6)
                } else if is4K {
                    Text("4K")
                        .font(.system(size: 9, weight: .black))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2.5)
                        .background(
                            LinearGradient(colors: [Color(red: 1.0, green: 0.8, blue: 0.2), Color(red: 1.0, green: 0.6, blue: 0.0)], startPoint: .topLeading, endPoint: .bottomTrailing),
                            in: Capsule()
                        )
                        .shadow(radius: 2)
                        .padding(6)
                } else if watchlisted {
                    Image(systemName: "bookmark.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.white, .orange)
                        .shadow(radius: 2)
                        .padding(6)
                } else if let badge {
                    badge.label.padding(6)
                }
            }
            .overlay(alignment: .topLeading) {
                if let seasonBadge {
                    Text(seasonBadge)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2.5)
                        .background(Color.purple.opacity(0.9), in: Capsule())
                        .shadow(radius: 2)
                        .padding(6)
                } else if let imdbRating {
                    IMDbRatingTag(rating: imdbRating).padding(6)
                }
            }

            Text(title)
                .font(.system(size: 12, weight: isGamepadFocused ? .bold : .medium))
                .foregroundStyle(isGamepadFocused ? AnyShapeStyle(Color.cyan) : AnyShapeStyle(.primary))
                .lineLimit(1)
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .scaleEffect(isGamepadFocused ? 1.07 : (isHovering ? 1.03 : 1.0))
        .shadow(color: .black.opacity(isHighlighted ? 0.6 : 0), radius: 14, y: 6)
        .animation(.easeOut(duration: 0.15), value: isHighlighted)
        .focusable()
        .focused($isFocusState)
        .onHover { isHovering = $0 }
    }

    /// Drawn by the card's owner rather than here: a button nested inside another
    /// button's label never receives the click on macOS.
    static func removeButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(.black.opacity(0.7), in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.3), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .padding(6)
        .help("İzlemeye Devam Et listesinden kaldır")
    }

    @ViewBuilder
    private var artwork: some View {
        if let posterImage {
            Image(nsImage: posterImage).resizable()
        } else if let image = ArtworkCache.image(named: posterFileName) {
            Image(nsImage: image).resizable()
        } else if let posterURL {
            CachedAsyncImage(url: posterURL) { phase in
                switch phase {
                case .success(let image): image.resizable()
                default: placeholder
                }
            }
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(
                colors: [Color(white: 0.22), Color(white: 0.13)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: "film")
                .font(.system(size: 28))
                .foregroundStyle(.white.opacity(0.25))
        }
    }
}

/// Afişin sol üst köşesindeki IMDb puanı.
///
/// Sağ üst köşe "Kütüphanede" ve izleme listesi işaretlerinin, o yüzden puan
/// karşı köşede duruyor; ikisi aynı kartta çakışmıyor.
struct IMDbRatingTag: View {
    let rating: Double

    var body: some View {
        HStack(spacing: 4) {
            Text("IMDb")
                .font(.system(size: 12, weight: .heavy))
                .foregroundStyle(.black)
                .padding(.horizontal, 4)
                .padding(.vertical, 1.5)
                .background(Color(red: 0.96, green: 0.79, blue: 0.11), in: RoundedRectangle(cornerRadius: 3))
            Text(String(format: "%.1f", rating))
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(.black.opacity(0.65), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
    }
}

/// A pill drawn in a poster's top-right corner.
struct PosterBadge {
    let text: String
    let systemImage: String?
    let tint: Color
    /// Library/trending pills sit slightly translucent over the artwork; a source
    /// pill is opaque so its configured colour is the colour drawn.
    var tintOpacity: Double = 0.9

    static let inLibrary = PosterBadge(text: "Kütüphanede", systemImage: "checkmark", tint: .blue)
    static let trending = PosterBadge(text: "Trend", systemImage: "flame.fill", tint: .orange)

    /// Names the streaming source a card can be played from — "Zysistem",
    /// "ZySeries". Each source brings its own fill (from `StreamRegistry`) so they
    /// stay apart at a glance in a mixed grid, and drawn opaque so the colour lands
    /// exactly as configured.
    static func source(_ name: String, tint: Color) -> PosterBadge {
        PosterBadge(text: name, systemImage: "play.tv.fill", tint: tint, tintOpacity: 1)
    }

    var label: some View {
        HStack(spacing: 3) {
            if let systemImage {
                Image(systemName: systemImage).font(.system(size: 8, weight: .bold))
            }
            Text(text).font(.system(size: 9, weight: .bold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(tint.opacity(tintOpacity), in: Capsule())
        .shadow(radius: 2)
    }
}

/// Responsive poster grid used by Movies, Shows and search results.
struct PosterGrid<Item: Identifiable, Content: View>: View {
    let items: [Item]
    var selectedIndex: Int = -1
    var embedsInScrollView: Bool = true
    @ViewBuilder let content: (Item, Bool) -> Content

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 10)

    /// Vurgulanacak kart. İmleç listenin sonunu aştığında hiçbir kart eşleşmez
    /// ve kumanda "kayboldu" gibi görünür — indeks her zaman listenin içine
    /// kırpılır, böylece son karta yaslanıp orada durur.
    private var highlightedIndex: Int {
        guard selectedIndex >= 0, !items.isEmpty else { return -1 }
        return min(selectedIndex, items.count - 1)
    }

    var body: some View {
        if embedsInScrollView {
            ScrollViewReader { proxy in
                ScrollView {
                    gridBody
                }
                .onChange(of: highlightedIndex) { _, newIndex in
                    guard newIndex >= 0, newIndex < items.count else { return }
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(items[newIndex].id, anchor: .center)
                    }
                }
            }
        } else {
            gridBody
        }
    }

    private var gridBody: some View {
        LazyVGrid(columns: columns, spacing: 22) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                content(item, index == highlightedIndex)
                    .id(item.id)
            }
        }
        .padding(20)
    }
}

/// Horizontal shelf used on the Home screen.
struct PosterShelf<Item: Identifiable, Content: View>: View {
    let title: String
    let items: [Item]
    @ViewBuilder let content: (Item) -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .padding(.horizontal, 20)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(items) { item in
                        content(item).frame(width: 140)
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }
}
