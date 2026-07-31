import Foundation

/// Subtitle appearance, mapped onto mpv's `sub-*` properties.
struct SubtitleStyle: Codable, Hashable {
    var fontName: String = "Helvetica Neue"
    var fontSize: Int = 46           // mpv's sub-font-size
    var isBold: Bool = true
    var isItalic: Bool = false
    /// Hex without alpha, e.g. "#FFFFFF".
    var textColor: String = "#FFFFFF"
    var borderColor: String = "#000000"
    var borderSize: Double = 2.5
    var shadowOffset: Double = 0
    /// 0 = fully transparent background behind the text.
    var backgroundOpacity: Double = 0
    /// mpv `sub-pos`: 100 is the bottom edge.
    var position: Int = 100
    /// Extra delay in seconds, for out-of-sync files.
    var delay: Double = 0

    static let availableFonts = [
        "Helvetica Neue", "Helvetica", "Arial", "Avenir Next", "SF Pro Text",
        "Verdana", "Tahoma", "Georgia", "Trebuchet MS", "Futura"
    ]

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
            ("sub-outline-size", String(format: "%.1f", borderSize)),
            ("sub-shadow-offset", String(format: "%.1f", shadowOffset)),
            ("sub-back-color", mpvColor("#000000", alpha: backgroundOpacity)),
            ("sub-pos", String(position)),
            ("sub-delay", String(format: "%.2f", delay))
        ]
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fontName = c.value(.fontName, "Helvetica Neue")
        fontSize = c.value(.fontSize, 46)
        isBold = c.value(.isBold, true)
        isItalic = c.value(.isItalic, false)
        textColor = c.value(.textColor, "#FFFFFF")
        borderColor = c.value(.borderColor, "#000000")
        borderSize = c.value(.borderSize, 2.5)
        shadowOffset = c.value(.shadowOffset, 0)
        backgroundOpacity = c.value(.backgroundOpacity, 0)
        position = c.value(.position, 100)
        delay = c.value(.delay, 0)
    }
}
