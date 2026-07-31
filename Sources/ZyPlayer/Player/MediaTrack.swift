import Foundation

/// An audio, subtitle or video stream reported by mpv's `track-list`.
struct MediaTrack: Identifiable, Hashable {
    enum Kind: String {
        case video, audio, sub
    }

    var id: Int
    var kind: Kind
    var title: String?
    var lang: String?
    var codec: String?
    var isSelected: Bool
    var isDefault: Bool
    var isForced: Bool
    var channelCount: Int?
    var ffIndex: Int?
    /// Dış altyazının diskteki yolu. mpv, videonun yanındaki `.srt` dosyalarını
    /// kendiliğinden yüklüyor; bu izler uygulamanın kendi kayıtlarında olmadığı
    /// için kaynaklarını yalnızca buradan öğrenebiliyoruz.
    var externalFilename: String?

    init?(mpvEntry entry: [String: Any]) {
        guard let id = entry["id"] as? Int,
              let typeString = entry["type"] as? String,
              let kind = Kind(rawValue: typeString) else {
            return nil
        }
        self.id = id
        self.kind = kind
        self.title = entry["title"] as? String
        self.lang = entry["lang"] as? String
        self.codec = entry["codec"] as? String
        self.isSelected = entry["selected"] as? Bool ?? false
        self.isDefault = entry["default"] as? Bool ?? false
        self.isForced = entry["forced"] as? Bool ?? false
        self.channelCount = entry["demux-channel-count"] as? Int
        self.ffIndex = entry["ff-index"] as? Int
        self.externalFilename = entry["external-filename"] as? String
    }

    /// Human label: "Türkçe · AC3 5.1", "İngilizce · Zorunlu", or a fallback.
    var displayName: String {
        var parts: [String] = []
        let usableTitle = Self.meaningfulTitle(title)

        if let language = lang, let localized = Self.languageName(for: language) {
            parts.append(localized)
        } else if let usableTitle {
            parts.append(usableTitle)
        } else {
            parts.append("Parça \(id)")
        }

        // A descriptive title alongside a language is worth keeping ("Commentary").
        if let usableTitle, lang != nil, !parts.contains(usableTitle) {
            parts.append(usableTitle)
        }
        if isForced { parts.append("Zorunlu") }

        var suffix: [String] = []
        if let codec { suffix.append(codec.uppercased()) }
        if kind == .audio, let channelCount {
            suffix.append(channelCount == 6 ? "5.1" : channelCount == 8 ? "7.1" : "\(channelCount)ch")
        }

        let main = parts.joined(separator: " · ")
        return suffix.isEmpty ? main : "\(main) · \(suffix.joined(separator: " "))"
    }

    /// Release sites stamp their domain into track titles
    /// ("www.1TamilMV.tube - [DD 5.1 - 192Kbps]"), which is noise in a menu —
    /// and the bitrate part duplicates the codec we already show.
    private static func meaningfulTitle(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let siteLike = #"(?i)(www\.|https?://|\.(com|net|org|tv|tube|to|me|info|xyz)\b)"#
        if trimmed.range(of: siteLike, options: .regularExpression) != nil { return nil }

        // Strip a trailing "[DD 5.1 - 192Kbps]"-style tag.
        let cleaned = trimmed
            .replacingOccurrences(of: #"\s*[\[\(][^\]\)]*[\]\)]\s*$"#, with: "",
                                  options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " -–—·"))

        return cleaned.isEmpty ? nil : cleaned
    }

    /// Maps an ISO code to a Turkish language name.
    private static func languageName(for code: String) -> String? {
        let normalized = code.lowercased()
        if let known = manualNames[normalized] { return known }
        let locale = Locale(identifier: "tr")
        return locale.localizedString(forLanguageCode: normalized)?.capitalized
    }

    /// Three-letter codes Foundation does not resolve on its own.
    private static let manualNames: [String: String] = [
        "tur": "Türkçe", "tr": "Türkçe",
        "eng": "İngilizce", "en": "İngilizce",
        "ger": "Almanca", "deu": "Almanca", "de": "Almanca",
        "fre": "Fransızca", "fra": "Fransızca", "fr": "Fransızca",
        "spa": "İspanyolca", "es": "İspanyolca",
        "ita": "İtalyanca", "it": "İtalyanca",
        "rus": "Rusça", "ru": "Rusça",
        "ara": "Arapça", "ar": "Arapça",
        "jpn": "Japonca", "ja": "Japonca",
        "kor": "Korece", "ko": "Korece",
        "chi": "Çince", "zho": "Çince", "zh": "Çince",
        "por": "Portekizce", "pt": "Portekizce",
        "nld": "Felemenkçe", "dut": "Felemenkçe", "nl": "Felemenkçe",
        "pol": "Lehçe", "pl": "Lehçe",
        "swe": "İsveççe", "sv": "İsveççe",
        "und": "Bilinmeyen"
    ]
}
