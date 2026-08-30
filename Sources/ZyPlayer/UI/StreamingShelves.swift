import SwiftUI

extension StreamingBrand {
    /// Logo gelmeden önce çizilen yedek rozetin rengi ve harfi.
    var accentColor: Color {
        switch self {
        case .netflix: Color(red: 0.898, green: 0.035, blue: 0.078)     // #E50914
        case .primeVideo: Color(red: 0.0, green: 0.659, blue: 0.882)    // #00A8E1
        case .disneyPlus: Color(red: 0.043, green: 0.161, blue: 0.435)  // #0B2A6F
        case .hboMax: Color(red: 0.475, green: 0.129, blue: 0.980)      // #7921FA
        case .paramountPlus: Color(red: 0.0, green: 0.243, blue: 0.949) // #003EF2
        case .appleTVPlus: Color(red: 0.09, green: 0.09, blue: 0.1)     // Apple TV siyahı
        }
    }

    var initial: String {
        switch self {
        case .netflix: "N"
        case .primeVideo: "P"
        case .disneyPlus: "D"
        case .hboMax: "M"
        case .paramountPlus: "P+"
        case .appleTVPlus: "tv"
        }
    }
}

/// Raf başlığındaki marka logosu.
///
/// Görsel TMDB'den geliyor; inene kadar (ya da hiç inmezse) markanın kendi
/// renginde bir harf rozeti duruyor, böylece başlık hiçbir durumda boş kalmıyor.
struct StreamingBrandBadge: View {
    let brand: StreamingBrand
    let logoURL: URL?
    var size: CGFloat = 24

    var body: some View {
        Group {
            if let logoURL {
                CachedAsyncImage(url: logoURL) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        fallback
                    }
                }
            } else {
                fallback
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
        .accessibilityLabel(brand.displayName)
    }

    private var fallback: some View {
        ZStack {
            brand.accentColor
            Text(brand.initial)
                .font(.system(size: brand.initial.count > 1 ? size * 0.36 : size * 0.6, weight: .heavy))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .padding(.horizontal, 2)
        }
    }
}
