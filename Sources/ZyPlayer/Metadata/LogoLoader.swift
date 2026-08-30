import Foundation
import Observation

/// The transparent title logo for one film or show, fetched once per
/// identity. Mirrors `CreditsLoader`'s shape — a detail screen wants both,
/// side by side, without either blocking the other.
///
/// `hasChecked` exists so the caller never shows the plain-text title and
/// then swaps it for the logo a moment later: while a lookup is in flight the
/// title stays hidden, and it only appears once we know for certain there is
/// no logo to show instead.
@MainActor
@Observable
final class LogoLoader {
    private(set) var logoURL: URL?
    private(set) var hasChecked = false
    @ObservationIgnored private var loadedKey: String?

    func load(kind: RemoteKind, tmdbID: Int, settings: AppSettings) async {
        let key = "\(kind.rawValue)-\(tmdbID)"
        guard loadedKey != key else { return }
        loadedKey = key
        logoURL = nil
        hasChecked = false

        guard settings.hasTMDBToken else {
            hasChecked = true
            return
        }

        let client = TMDBClient(token: settings.tmdbToken, language: settings.metadataLanguage)
        let path: String?
        switch kind {
        case .movie: path = try? await client.movieLogoPath(id: tmdbID)
        case .tv: path = try? await client.tvLogoPath(id: tmdbID)
        }
        guard loadedKey == key else { return }
        logoURL = path.map { TMDBClient.imageURL(path: $0, size: "w500") }
        hasChecked = true
    }

    /// For a title with no TMDB id to look up at all (an unmatched ZyStream
    /// hit) — nothing to fetch, but the caller still needs to know the check
    /// is "done" so it can show the plain-text title.
    func markChecked() {
        loadedKey = nil
        logoURL = nil
        hasChecked = true
    }
}
