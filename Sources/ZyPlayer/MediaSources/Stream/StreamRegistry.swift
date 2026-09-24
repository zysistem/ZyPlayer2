import Foundation

private extension StringProtocol {
    /// Sondan başlayarak koşulu sağlayan parça — "dizipal2134" → "2134".
    func suffix(while predicate: (Character) -> Bool) -> String {
        String(reversed().prefix(while: predicate).reversed())
    }
}

/// A stored streaming source: its on/off flag and its current base URL. The URL
/// is persisted (and editable in Settings) because these sites move domains
/// often; the display name and kind come from the catalog.
struct StreamSourceToggle: Codable, Identifiable, Hashable {
    var id: String
    var isEnabled: Bool
    var baseURL: String

    init(id: String, isEnabled: Bool, baseURL: String) {
        self.id = id
        self.isEnabled = isEnabled
        self.baseURL = baseURL
    }

    /// Tolerant: a toggle saved before the URL field existed still decodes, and
    /// an abandoned "next address" key from the removed domain tracker is
    /// ignored (unknown JSON keys drop on the floor) rather than failing.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, "")
        isEnabled = c.value(.isEnabled, true)
        baseURL = c.value(.baseURL, "")
    }
}

/// What the app knows about one streaming site: its identity and how to build a
/// provider for a given base URL.
struct StreamProviderInfo: Identifiable {
    let id: String
    let displayName: String
    /// What a result card is stamped with. Not the display name: several sites can
    /// sit behind one badge ("Zysistem"), while a source the user thinks of as its
    /// own thing gets its own ("ZySeries").
    let badgeName: String
    /// "#RRGGBB" the badge is filled with, so the two sources stay apart at a
    /// glance in a mixed grid. Kept as a string to keep this file Foundation-only.
    let badgeHex: String
    let kind: StreamKind
    let defaultBaseURL: String
    let make: (String) -> StreamProvider
}

/// The catalog of streaming sites the app ships. Adding a site is one entry here
/// plus its `StreamProvider` file.
enum StreamRegistry {
    static let catalog: [StreamProviderInfo] = [
        StreamProviderInfo(
            id: "hdfilmcehennemi",
            displayName: "HdFilmCehennemi",
            badgeName: "HDFC",
            badgeHex: "#01258F",
            kind: .movie,
            defaultBaseURL: HdFilmCehennemiProvider.defaultBaseURL,
            make: { HdFilmCehennemiProvider(baseURL: $0) }
        ),
        StreamProviderInfo(
            id: "dizipal",
            displayName: "ZySeries",
            badgeName: "DiziPal",
            badgeHex: "#FF214A",
            kind: .series,
            defaultBaseURL: DizipalProvider.defaultBaseURL,
            make: { DizipalProvider(baseURL: $0) }
        )
    ]

    /// The badge a hit's card carries — name and "#RRGGBB" fill — falling back to
    /// the app-wide one for a provider that has since left the catalog (a stored
    /// favourite, say).
    static func badge(forProviderID id: String) -> (name: String, hex: String) {
        guard let info = info(id: id) else { return ("Zysistem", "#FFB33A") }
        return (info.badgeName, info.badgeHex)
    }

    static func info(id: String) -> StreamProviderInfo? {
        catalog.first { $0.id == id }
    }

    /// A fresh install defaults every source to enabled at its default URL.
    static var defaultToggles: [StreamSourceToggle] {
        catalog.map { StreamSourceToggle(id: $0.id, isEnabled: true, baseURL: $0.defaultBaseURL) }
    }

    /// Merges saved toggles with the catalog: known ids keep their saved state and
    /// URL (falling back to the default URL when blank), unknown ids drop out, and
    /// new sources are appended enabled. Preserves catalog order.
    static func reconcile(_ saved: [StreamSourceToggle]) -> [StreamSourceToggle] {
        let byID = Dictionary(saved.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return catalog.map { info in
            guard var toggle = byID[info.id] else {
                return StreamSourceToggle(id: info.id, isEnabled: true, baseURL: info.defaultBaseURL)
            }
            if toggle.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                toggle.baseURL = info.defaultBaseURL
            }
            // Otomatik adres takibi kaldırıldı; kayıtlı dizipal adresi hâlâ
            // takipçinin bıraktığı numaralı bir alan adıysa (dizipal2134 gibi)
            // varsayılana (dizipal1583) çekilir. Aynı aile dışında bir adres —
            // kullanıcının elle girdiği — olduğu gibi kalır.
            if toggle.baseURL != info.defaultBaseURL,
               let stored = Self.numberedDomain(of: toggle.baseURL),
               let fresh = Self.numberedDomain(of: info.defaultBaseURL),
               stored.stem == fresh.stem, stored.suffix == fresh.suffix {
                toggle.baseURL = info.defaultBaseURL
            }
            return toggle
        }
    }

    /// "https://dizipal2134.com" → ("dizipal", 2134, "com"). Numaralı taşınma
    /// ailesine ait adresleri tanır; sayı ile bitmeyen bir ad için nil.
    private static func numberedDomain(of baseURL: String) -> (stem: String, number: Int, suffix: String)? {
        guard var host = URL(string: baseURL)?.host?.lowercased() else { return nil }
        if host.hasPrefix("www.") { host = String(host.dropFirst(4)) }

        guard let dot = host.firstIndex(of: ".") else { return nil }
        let name = String(host[host.startIndex..<dot])
        let suffix = String(host[host.index(after: dot)...])

        let digits = name.suffix(while: \.isNumber)
        guard !digits.isEmpty, let number = Int(digits) else { return nil }
        let stem = String(name.dropLast(digits.count))
        guard !stem.isEmpty else { return nil }
        return (stem, number, suffix)
    }
}
