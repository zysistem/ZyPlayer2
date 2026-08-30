import SwiftUI
import AppKit

/// Live preview of the subtitle style over a neutral backdrop.
struct SubtitlePreview: View {
    let style: SubtitleStyle

    /// The settings sheet is much smaller than a video frame, so the mpv size is
    /// scaled down to keep the preview representative rather than literal.
    private var previewSize: CGFloat { CGFloat(style.fontSize) * 0.38 }

    /// SwiftUI can render the full 400–900 ladder, unlike mpv's on/off bold —
    /// this preview is the only place the in-between steps are actually visible.
    private var previewWeight: Font.Weight {
        switch style.fontWeight {
        case ..<450: .regular
        case ..<550: .medium
        case ..<650: .semibold
        case ..<750: .bold
        case ..<850: .heavy
        default: .black
        }
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(white: 0.28), Color(white: 0.12)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack {
                Spacer(minLength: 0)
                Text("Örnek altyazı satırı — Ağğı, İıŞşÇç")
                    .font(.system(size: previewSize, weight: previewWeight))
                    .italic(style.isItalic)
                    .foregroundStyle(Color(hex: style.textColor))
                    .shadow(color: Color(hex: style.borderColor),
                            radius: style.edgeStyle.hasOutline ? style.borderSize * 0.6 : 0)
                    .shadow(color: Color(hex: style.shadowColor)
                                .opacity(style.edgeStyle.hasShadow ? style.shadowOpacity : 0),
                            radius: style.shadowBlur * 0.6,
                            x: style.shadowOffset, y: style.shadowOffset)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .padding(.bottom, bottomPadding)
            }
        }
        .frame(height: 108)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(.separator.opacity(0.6), lineWidth: 1)
        )
    }

    /// `sub-pos` counts down from the top, so 100 sits at the bottom edge.
    private var bottomPadding: CGFloat {
        CGFloat(100 - style.position) * 0.6 + 6
    }
}

extension Color {
    /// Accepts "#RRGGBB" or "RRGGBB"; falls back to white.
    init(hex: String) {
        let cleaned = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard cleaned.count == 6, let value = UInt32(cleaned, radix: 16) else {
            self = .white
            return
        }
        self = Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    /// "#RRGGBB" for storing in settings.
    var hexString: String {
        let nsColor = NSColor(self).usingColorSpace(.sRGB) ?? .white
        return String(
            format: "#%02X%02X%02X",
            Int((nsColor.redComponent * 255).rounded()),
            Int((nsColor.greenComponent * 255).rounded()),
            Int((nsColor.blueComponent * 255).rounded())
        )
    }
}
