import Foundation
import Observation

struct ZyMovieTorrentFile: Identifiable, Hashable, Codable {
    var id: UUID = UUID()
    let index: Int
    let name: String
    let size: Int
}

/// Holds a single parsed RSS item matched to TMDB (if found).
struct ZyMovieHit: Identifiable, Hashable, Codable {
    var id: String { rssLink }
    
    let rssTitle: String
    let rssLink: String
    let rssDescription: String
    
    /// Matched TMDB title for poster and details. Nil if match failed.
    let remoteTitle: RemoteTitle?
    
    /// Cached parsed torrent video files for favorited items
    var cachedFiles: [ZyMovieTorrentFile]? = nil
}

enum ZyMovieCategory: String, CaseIterable, Identifiable, Codable {
    case all = "Tümü"
    case appleTV = "Apple TV+"
    case amazon = "Amazon"
    case bluTV = "BluTV"
    case disney = "Disney+"
    case hbo = "HBO"
    case netflixFilm = "Netflix Film"
    case netflixDizi = "Netflix Dizi"

    var id: String { rawValue }

    var categoriesParam: String {
        switch self {
        case .all: return "59,30,39,38,86,102,98,105,33,93,84"
        case .appleTV: return "102"
        case .amazon: return "86"
        case .bluTV: return "84"
        case .disney: return "98"
        case .hbo: return "105"
        case .netflixFilm: return "39"
        case .netflixDizi: return "38"
        }
    }

    var symbol: String {
        switch self {
        case .all: return "square.grid.2x2.fill"
        case .appleTV: return "apple.logo"
        case .amazon: return "play.square.fill"
        case .bluTV: return "play.tv.fill"
        case .disney: return "sparkles"
        case .hbo: return "tv.badge.wifi.fill"
        case .netflixFilm: return "film.fill"
        case .netflixDizi: return "tv.fill"
        }
    }
}

@Observable
final class ZyMovieStore {
    private(set) var hits: [ZyMovieHit] = []
    private(set) var favorites: [ZyMovieHit] = []
    private(set) var selectedCategory: ZyMovieCategory = .all
    private(set) var isLoading = false
    var statusMessage: String?
    
    // For episode picker in player
    var playingHit: ZyMovieHit?
    var playingFiles: [ZyMovieTorrentFile] = []
    
    private var rssURL: URL {
        URL(string: "https://turktorrent.us/?p=rss&categories=\(selectedCategory.categoriesParam)&pk=f5f6798511382f56dd393d91df0cfbe8f22e5508&limit=100")!
    }
    
    private var matchCache: [String: RemoteTitle] = [:]
    
    init() {
        if let data = UserDefaults.standard.data(forKey: "zyMovieFavorites"),
           let favs = try? JSONDecoder().decode([ZyMovieHit].self, from: data) {
            favorites = favs
        }
        if let cacheData = UserDefaults.standard.data(forKey: "zyMovieTMDBMatchCache"),
           let cache = try? JSONDecoder().decode([String: RemoteTitle].self, from: cacheData) {
            matchCache = cache
        }
    }

    @MainActor
    func selectCategory(_ category: ZyMovieCategory, settings: AppSettings) async {
        selectedCategory = category
        hits = []
        await refresh(settings: settings, force: true)
    }
    
    @MainActor
    func refresh(settings: AppSettings, force: Bool = false) async {
        guard !isLoading || force else { return }
        isLoading = true
        defer { isLoading = false }
        
        do {
            let (data, _) = try await URLSession.shared.data(from: rssURL)
            let parser = RSSParser()
            let rssItems = parser.parse(data: data)
            let topItems = Array(rssItems.prefix(100))
            
            let hasToken = settings.hasTMDBToken
            let token = settings.tmdbToken
            let lang = settings.metadataLanguage
            let localCache = matchCache
            
            // Perform TMDB matches in parallel for missing items
            let updatedMatches: [String: RemoteTitle?] = await withTaskGroup(of: (String, RemoteTitle?).self) { group in
                for item in topItems {
                    if let cached = localCache[item.title] {
                        group.addTask { (item.title, cached) }
                    } else if hasToken {
                        group.addTask {
                            let title = item.title
                            let clean = self.cleanReleaseName(title)
                            let tmdb = TMDBClient(token: token, language: lang)
                            
                            if let results = try? await tmdb.searchMulti(query: clean),
                               let bestMatch = results.first,
                               let remote = RemoteTitle(multi: bestMatch) {
                                return (title, remote)
                            }
                            let simpler = self.veryCleanTitle(title)
                            if simpler != clean,
                               let results = try? await tmdb.searchMulti(query: simpler),
                               let bestMatch = results.first,
                               let remote = RemoteTitle(multi: bestMatch) {
                                return (title, remote)
                            }
                            return (title, nil)
                        }
                    } else {
                        group.addTask { (item.title, nil) }
                    }
                }
                
                var results: [String: RemoteTitle?] = [:]
                for await (title, remote) in group {
                    results[title] = remote
                }
                return results
            }
            
            // Save new matches to persistent cache
            var newCache = matchCache
            for (title, remote) in updatedMatches {
                if let remote {
                    newCache[title] = remote
                }
            }
            self.matchCache = newCache
            if let encoded = try? JSONEncoder().encode(newCache) {
                UserDefaults.standard.set(encoded, forKey: "zyMovieTMDBMatchCache")
            }
            
            // Build hits list preserving original RSS order
            self.hits = topItems.map { item in
                ZyMovieHit(
                    rssTitle: item.title,
                    rssLink: item.link,
                    rssDescription: item.description,
                    remoteTitle: updatedMatches[item.title] ?? nil
                )
            }
            // Sync favorites with updated matched metadata
            self.favorites = self.favorites.map { fav in
                if let updatedRemote = updatedMatches[fav.rssTitle] ?? newCache[fav.rssTitle] {
                    return ZyMovieHit(rssTitle: fav.rssTitle, rssLink: fav.rssLink, rssDescription: fav.rssDescription, remoteTitle: updatedRemote)
                }
                return fav
            }
            saveFavorites()
            
            self.statusMessage = nil
        } catch {
            self.statusMessage = "RSS yüklenemedi: \(error.localizedDescription)"
        }
    }

    private func cleanReleaseName(_ name: String) -> String {
        var clean = name
        let tags = [
            "1080p", "2160p", "720p", "4k", "WEB-DL", "WEBRip", "BluRay",
            "DDP5.1", "Atmos", "H.264", "H.265", "HDR", "DV", "EN-TR", "TR",
            "TURG", "TT", "AMZN", "ATVP", "NF", "DSNP"
        ]
        
        // Remove known tags (case insensitive)
        for tag in tags {
            if let range = clean.range(of: tag, options: .caseInsensitive) {
                clean.removeSubrange(range)
            }
        }
        
        // Remove trailing hyphens or brackets
        clean = clean.replacingOccurrences(of: "\\[.*?\\]", with: "", options: .regularExpression)
        clean = clean.replacingOccurrences(of: "-+$", with: "", options: .regularExpression)
        
        return clean.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private func veryCleanTitle(_ name: String) -> String {
        // Stop at "S01", "1080p", or year like "(2024)"
        if let match = name.range(of: "( S\\d{2}| 1080p| 2160p| 720p| \\(\\d{4}\\))", options: .regularExpression) {
            return String(name[..<match.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return cleanReleaseName(name)
    }
    // MARK: - Favorites
    
    func isFavorite(_ hit: ZyMovieHit) -> Bool {
        favorites.contains { $0.id == hit.id }
    }
    
    func toggleFavorite(_ hit: ZyMovieHit) {
        let latestHit = hits.first(where: { $0.id == hit.id }) ?? hit
        if isFavorite(latestHit) {
            favorites.removeAll { $0.id == latestHit.id }
        } else {
            favorites.insert(latestHit, at: 0)
        }
        saveFavorites()
    }
    
    func updateFavoriteTorrentFiles(for hit: ZyMovieHit, files: [ZyMovieTorrentFile]) {
        guard !files.isEmpty else { return }
        if let idx = favorites.firstIndex(where: { $0.id == hit.id }) {
            var updated = favorites[idx]
            updated.cachedFiles = files
            favorites[idx] = updated
            saveFavorites()
        }
    }

    private func saveFavorites() {
        if let data = try? JSONEncoder().encode(favorites) {
            UserDefaults.standard.set(data, forKey: "zyMovieFavorites")
        }
    }

    func searchTMDBHits(query: String, settings: AppSettings) async -> [ZyMovieHit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, settings.hasTMDBToken else { return [] }
        
        let tmdb = TMDBClient(token: settings.tmdbToken, language: settings.metadataLanguage)
        guard let results = try? await tmdb.searchMulti(query: trimmed) else { return [] }
        
        return results.compactMap { result in
            guard let remote = RemoteTitle(multi: result) else { return nil }
            return ZyMovieHit(
                rssTitle: remote.title,
                rssLink: "tmdb_\(remote.id)",
                rssDescription: remote.overview ?? "",
                remoteTitle: remote
            )
        }
    }
}

// MARK: - RSS Parsing

struct RSSItem {
    var title: String = ""
    var link: String = ""
    var description: String = ""
}

final class RSSParser: NSObject, XMLParserDelegate {
    private var items: [RSSItem] = []
    private var currentItem: RSSItem?
    private var currentElement = ""
    private var currentString = ""
    
    func parse(data: Data) -> [RSSItem] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return items
    }
    
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        currentElement = elementName
        if elementName == "item" {
            currentItem = RSSItem()
        }
        currentString = ""
    }
    
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentString += string
    }
    
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if let string = String(data: CDATABlock, encoding: .utf8) {
            currentString += string
        }
    }
    
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard var item = currentItem else { return }
        
        let trimmed = currentString.trimmingCharacters(in: .whitespacesAndNewlines)
        
        switch elementName {
        case "title":
            item.title = trimmed
        case "link":
            item.link = trimmed
        case "description":
            item.description = trimmed
        case "item":
            items.append(item)
            currentItem = nil
        default:
            break
        }
        
        if currentItem != nil {
            currentItem = item
        }
    }
}
