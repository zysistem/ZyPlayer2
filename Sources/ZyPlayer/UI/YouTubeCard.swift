import SwiftUI

/// Arama sonuçlarındaki bir YouTube videosu.
///
/// Afiş kartlarından ayrı bir görünüm: YouTube küçük resimleri 16:9, afişler 2:3.
/// Aynı karta sıkıştırmak resmi ya kırpar ya da kenarlarını boş bırakırdı.
struct YouTubeCard: View {
    let video: YouTubeVideo
    /// Devam noktası varsa küçük resmin altındaki çubuk.
    var progress: Double = 0
    let onPlay: (YouTubeVideo) -> Void

    @State private var isHovering = false
    @FocusState private var isFocused: Bool

    private var isHighlighted: Bool { isHovering || isFocused }

    var body: some View {
        Button {
            onPlay(video)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .bottom) {
                    thumbnail
                        .aspectRatio(16.0 / 9.0, contentMode: .fill)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(
                                    .white.opacity(isHighlighted ? 0.95 : 0.08),
                                    lineWidth: isHighlighted ? 2 : 1
                                )
                        )

                    if progress > 0.01 {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Rectangle().fill(.black.opacity(0.5))
                                Rectangle().fill(.red).frame(width: geo.size.width * progress)
                            }
                        }
                        .frame(height: 4)
                        .clipShape(RoundedRectangle(cornerRadius: 2))
                        .padding(.horizontal, 6)
                        .padding(.bottom, 6)
                    }
                }
                .overlay(alignment: .topLeading) {
                    YouTubeBadge().padding(6)
                }
                .overlay(alignment: .bottomTrailing) {
                    if !video.durationText.isEmpty {
                        Text(video.durationText)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 4))
                            .padding(6)
                    }
                }

                Text(video.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.leading)
                Text(video.subtitleLine)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .scaleEffect(isHighlighted ? 1.03 : 1)
            .shadow(color: .black.opacity(isHighlighted ? 0.45 : 0), radius: 12, y: 5)
            .animation(.easeOut(duration: 0.14), value: isHighlighted)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .focused($isFocused)
        .onHover { isHovering = $0 }
        .help(video.title)
        .contextMenu {
            Button("Oynat") { onPlay(video) }
            if let url = video.watchURL {
                Button("YouTube'da aç") { NSWorkspace.shared.open(url) }
            }
        }
    }

    /// Küçük resimler `i.ytimg.com` üzerinde açık; akış sitelerinin aksine
    /// Cloudflare kalkanı yok, `AsyncImage` doğrudan yükleyebiliyor.
    @ViewBuilder
    private var thumbnail: some View {
        CachedAsyncImage(url: video.thumbnailURL) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFill()
            default:
                ZStack {
                    Rectangle().fill(.quaternary)
                    Image(systemName: "play.rectangle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Kartın köşesindeki kaynak etiketi; ZyStream rozetleriyle aynı dilde.
struct YouTubeBadge: View {
    var body: some View {
        Text("YouTube")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color(red: 1.0, green: 0.0, blue: 0.0).opacity(0.9),
                        in: RoundedRectangle(cornerRadius: 4))
    }
}
