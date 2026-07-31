import Foundation

/// A subtitle source speaking the Stremio addon protocol.
///
/// The protocol needs no key: the addon server does the scraping and hands back
/// a ready-to-download subtitle URL. Several can be configured so one going down
/// does not take the feature with it.
struct SubtitleAddon: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String
    /// Root of the addon, without `/manifest.json` and without a trailing slash.
    var baseURL: String
    var isEnabled: Bool = true

    /// Stremio's own OpenSubtitles addon: no key, no configuration, plain UTF-8
    /// SRT. Seeded for every user so subtitles work out of the box.
    static var builtIn: SubtitleAddon {
        SubtitleAddon(name: "OpenSubtitles v3", baseURL: "https://opensubtitles-v3.strem.io")
    }

    var host: String {
        URL(string: baseURL)?.host ?? baseURL
    }

    init(id: UUID = UUID(), name: String, baseURL: String, isEnabled: Bool = true) {
        self.id = id
        self.name = name
        self.baseURL = Self.normalize(baseURL)
        self.isEnabled = isEnabled
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, UUID())
        name = c.value(.name, "Altyazı kaynağı")
        baseURL = c.value(.baseURL, "")
        isEnabled = c.value(.isEnabled, true)
    }

    /// Accepts what a user is likely to paste: a `stremio://` install link, a
    /// full `.../manifest.json`, or a bare host. Configuration segments such as
    /// `/<base64>/manifest.json` are kept — configurable addons need them.
    static func normalize(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("stremio://") {
            value = "https://" + value.dropFirst("stremio://".count)
        }
        if !value.hasPrefix("http://") && !value.hasPrefix("https://") {
            value = "https://" + value
        }
        if value.hasSuffix("/manifest.json") {
            value = String(value.dropLast("/manifest.json".count))
        }
        while value.hasSuffix("/") { value = String(value.dropLast()) }
        return value
    }
}

/// Maps between our two-letter settings codes and the three-letter codes the
/// addon protocol speaks.
///
/// The protocol is not self-consistent — one response carried `fre` (ISO 639-2/B)
/// next to `ron` and `ell` (639-2/T) — so `Locale`'s alpha3 conversion cannot be
/// trusted on its own. Languages we expect are listed explicitly with every
/// spelling that shows up; anything else falls back to `Locale`.
enum SubtitleLanguage {
    /// Two-letter code to every three-letter code that may appear in results.
    private static let table: [String: [String]] = [
        "tr": ["tur"], "en": ["eng"], "de": ["ger", "deu"], "fr": ["fre", "fra"],
        "es": ["spa"], "it": ["ita"], "pt": ["por", "pob"], "nl": ["dut", "nld"],
        "ru": ["rus"], "ar": ["ara"], "fa": ["per", "fas"], "el": ["gre", "ell"],
        "pl": ["pol"], "ro": ["rum", "ron"], "hu": ["hun"], "cs": ["cze", "ces"],
        "sv": ["swe"], "da": ["dan"], "fi": ["fin"], "no": ["nor"],
        "bg": ["bul"], "hr": ["hrv"], "sr": ["srp", "scc"], "sl": ["slv"],
        "sk": ["slo", "slk"], "uk": ["ukr"], "he": ["heb"], "hi": ["hin"],
        "ja": ["jpn"], "ko": ["kor"], "zh": ["chi", "zho"], "az": ["aze"],
        "ku": ["kur"], "vi": ["vie"], "th": ["tha"], "id": ["ind"]
    ]

    /// Every three-letter code matching a `"tr,en"` style preference list.
    static func codes(for preference: String) -> [String] {
        preference
            .split(whereSeparator: { $0 == "," || $0 == " " })
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
            .flatMap { alpha3(for: $0) }
    }

    static func alpha3(for twoLetter: String) -> [String] {
        if let known = table[twoLetter] { return known }
        if twoLetter.count == 3 { return [twoLetter] }
        if let derived = Locale.LanguageCode(twoLetter).identifier(.alpha3) as String? {
            return [derived]
        }
        return [twoLetter]
    }

    /// Resolves whatever an addon put in `lang` to a three-letter code.
    ///
    /// The protocol says "language code", but addons in the wild send `tur`,
    /// `tr`, `Turkish` and `Türkçe` interchangeably — and an unrecognised value
    /// used to be filtered out of results entirely.
    static func alpha3(forAnyForm raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty else { return nil }
        if table.values.contains(where: { $0.contains(value) }) { return value }
        if let known = table[value] { return known[0] }
        // A spelled-out name, in English or Turkish.
        for locale in ["en", "tr"] {
            let names = Locale(identifier: locale)
            if let match = table.first(where: {
                names.localizedString(forLanguageCode: $0.key)?.lowercased() == value
            }) {
                return match.value[0]
            }
        }
        return nil
    }

    /// Turkish display name for a three-letter code: `tur` → "Türkçe".
    static func displayName(alpha3 code: String) -> String {
        let lowered = code.lowercased()
        // Brazilian Portuguese is an OpenSubtitles-only code with no ISO entry.
        if lowered == "pob" { return "Portekizce (Brezilya)" }
        let twoLetter = table.first { $0.value.contains(lowered) }?.key
        let lookup = twoLetter ?? lowered
        return Locale(identifier: "tr").localizedString(forLanguageCode: lookup)?.capitalized
            ?? code.uppercased()
    }
}
