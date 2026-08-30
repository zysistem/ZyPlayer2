import Foundation

/// Subtitle appearance, mapped onto mpv's `sub-*` properties.
struct SubtitleStyle: Codable, Hashable {
    var fontName: String = "Helvetica Neue"
    var fontSize: Int = 46           // mpv's sub-font-size
    /// CSS-style weight scale; mpv only exposes a bold flag, so anything
    /// ≥700 renders bold and the rest renders regular. Kept numeric (rather
    /// than a plain isBold flag) so the UI can offer the familiar 500–900
    /// ladder even though playback itself only has two real states.
    var fontWeight: Int = 700
    var isItalic: Bool = false
    /// Hex without alpha, e.g. "#FFFFFF".
    var textColor: String = "#FFFFFF"
    var borderColor: String = "#000000"
    var borderSize: Double = 2.5
    var shadowColor: String = "#000000"
    var shadowOpacity: Double = 0.6
    var shadowOffset: Double = 0
    /// Gaussian blur on the shadow. 0 is a plain flat-black shadow, which is
    /// the expected default look; raise it for a soft glow instead.
    var shadowBlur: Double = 0
    /// Which of the outline/shadow are actually drawn — mirrors macOS's
    /// "Character Edge Style" choice (minus Raised/Depressed, which mpv's
    /// single outline+shadow renderer has no way to reproduce).
    var edgeStyle: EdgeStyle = .outlineAndShadow
    /// mpv `sub-pos`: 100 is the bottom edge.
    var position: Int = 100
    /// Extra delay in seconds, for out-of-sync files.
    var delay: Double = 0

    enum EdgeStyle: String, Codable, CaseIterable {
        case none, outline, dropShadow, outlineAndShadow

        var title: String {
            switch self {
            case .none: "Yok"
            case .outline: "Kenarlık"
            case .dropShadow: "Gölge"
            case .outlineAndShadow: "Kenarlık + Gölge"
            }
        }

        var hasOutline: Bool { self == .outline || self == .outlineAndShadow }
        var hasShadow: Bool { self == .dropShadow || self == .outlineAndShadow }
    }

    static let availableFonts = [
        "Helvetica Neue", "Helvetica", "Arial", "Avenir Next", "SF Pro Text",
        "Verdana", "Tahoma", "Georgia", "Trebuchet MS", "Futura"
    ]

    static let availableWeights = [400, 500, 600, 700, 800, 900]

    /// Practical maximum outline thickness before mpv's outline swallows the
    /// glyph itself. The settings slider maps `borderSize`'s real 0–6 range
    /// onto a friendlier 1–100 scale through this.
    static let maxBorderSize: Double = 6

    var isBold: Bool { fontWeight >= 700 }

    /// 1–100 UI scale for `borderSize` — dragging a mouse across a 0–6 slider
    /// makes landing on a precise 0.5 step hard; 100 discrete notches over the
    /// same visual range fixes that without changing what actually renders.
    var borderThicknessPercent: Int {
        get { min(100, max(1, Int((borderSize / Self.maxBorderSize * 100).rounded()))) }
        set { borderSize = (Double(min(100, max(1, newValue))) / 100) * Self.maxBorderSize }
    }

    /// mpv wants `#AARRGGBB`; the UI stores plain `#RRGGBB`.
    private func mpvColor(_ hex: String, alpha: Double = 1) -> String {
        let cleaned = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        let alphaByte = Int((max(0, min(1, alpha)) * 255).rounded())
        return String(format: "#%02X%@", alphaByte, cleaned.uppercased())
    }

    /// Property/value pairs to push into mpv.
    var mpvProperties: [(String, String)] {
        [
            ("sub-font", fontName),
            ("sub-font-size", String(fontSize)),
            ("sub-bold", isBold ? "yes" : "no"),
            ("sub-italic", isItalic ? "yes" : "no"),
            ("sub-color", mpvColor(textColor)),
            // Current names; `sub-border-*` still resolve but are the old spelling.
            ("sub-outline-color", mpvColor(borderColor)),
            ("sub-outline-size", edgeStyle.hasOutline ? String(format: "%.1f", borderSize) : "0"),
            ("sub-shadow-offset", edgeStyle.hasShadow ? String(format: "%.1f", shadowOffset) : "0"),
            ("sub-back-color", mpvColor(shadowColor, alpha: edgeStyle.hasShadow ? shadowOpacity : 0)),
            // mpv'nin sub-blur'ü asıl metni değil kenarlık katmanını bulanıklaştırır
            // (mpv-player/mpv#10784) — ama kenarlık genişliği 0'ken o katman
            // harfin kendi şekliyle aynı geometriye düşüyor, yani bulanıklık
            // doğrudan asıl yazıya bulaşıyor. Yalnızca gerçek bir kenarlık
            // (outline) varken bulanıklaştır; salt gölge modunda 0'da kalsın —
            // yoksa üstteki beyaz yazı da buğulanır.
            ("sub-blur", edgeStyle.hasOutline ? String(format: "%.1f", shadowBlur) : "0"),
            ("sub-pos", String(position)),
            ("sub-delay", String(format: "%.2f", delay))
        ]
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fontName = c.value(.fontName, "Helvetica Neue")
        fontSize = c.value(.fontSize, 46)
        // Older saves only had a boolean `isBold` — map it onto the new scale.
        if let weight = c.optional(.fontWeight) as Int? {
            fontWeight = weight
        } else {
            let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
            fontWeight = legacy.value(.isBold, true) ? 700 : 500
        }
        isItalic = c.value(.isItalic, false)
        textColor = c.value(.textColor, "#FFFFFF")
        borderColor = c.value(.borderColor, "#000000")
        borderSize = c.value(.borderSize, 2.5)
        shadowColor = c.value(.shadowColor, "#000000")
        shadowOpacity = c.value(.shadowOpacity, 0.6)
        shadowOffset = c.value(.shadowOffset, 0)
        shadowBlur = c.value(.shadowBlur, 0)
        // Older saves had no edge style; they always drew outline+shadow.
        edgeStyle = c.value(.edgeStyle, .outlineAndShadow)
        position = c.value(.position, 100)
        delay = c.value(.delay, 0)
    }

    private enum CodingKeys: String, CodingKey {
        case fontName, fontSize, fontWeight, isItalic, textColor, borderColor, borderSize,
             shadowColor, shadowOpacity, shadowOffset, shadowBlur, edgeStyle, position, delay
    }

    /// Fields only ever written by older versions of this app.
    private enum LegacyCodingKeys: String, CodingKey {
        case isBold
    }
}
