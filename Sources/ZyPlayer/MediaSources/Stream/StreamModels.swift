import Foundation

/// What a streaming source mostly carries. A site is not strictly one kind —
/// HdFilmCehennemi has a few series too — but the primary kind drives which
/// sidebar bucket and badge colour it gets.
enum StreamKind: String, Codable, Hashable {
    case movie, series, anime

    var label: String {
        switch self {
        case .movie: "Film"
        case .series: "Dizi"
        case .anime: "Anime"
        }
    }
}

/// One title found on a streaming site: enough to draw a card and to open its
/// page for the episode list or the embed. Codable so a favourited hit survives a
/// relaunch (there is no library row to hang it off).
struct StreamHit: Identifiable, Hashable, Codable {
    /// Stable across a session: provider plus the page it points at.
    var id: String { "\(providerID)|\(pageURL)" }
    var providerID: String
    var providerName: String
    var kind: StreamKind
    var title: String
    var year: Int?
    var posterURL: URL?
    /// The detail/watch page on the site, resolved to an episode list (series)
    /// or straight to embeds (movie).
    var pageURL: String
    /// Sitenin kart üzerinde gösterdiği IMDb puanı (varsa) — kartta rozet olarak
    /// çiziliyor. Opsiyonel: eski kayıtlar ve puan vermeyen kaynaklar için nil.
    var imdbRating: Double?
    /// "Dublaj" (Türkçe seslendirme var) ya da "Altyazılı" (yalnızca altyazı) —
    /// sitenin kartında bu bilgiyi taşıyan kaynaklarda (HdFilmCehennemi) dolu,
    /// diğerlerinde nil.
    var audioLabel: String?
}

/// A single episode on a series/anime page.
struct StreamEpisode: Identifiable, Hashable {
    var id: String { "s\(season)e\(episode)" }
    var season: Int
    var episode: Int
    var title: String?
    /// Thumbnail image URL scraped from the episode listing (if the site provides one).
    var thumbnailURL: URL?
    /// The page that holds this episode's embed(s).
    var pageURL: String
}

/// The result of opening a `StreamHit`'s page.
struct StreamDetails {
    var hit: StreamHit
    var overview: String?
    /// IMDb id (`tt…`) read from the page's IMDb link, for an exact TMDB match.
    var imdbID: String?
    /// Series/anime: episodes grouped by number. Empty for a movie.
    var episodes: [StreamEpisode]
    /// Movie: the watch page to pull embeds from. nil for a series.
    var moviePageURL: String?

    var seasons: [Int] { Array(Set(episodes.map(\.season))).sorted() }
    func episodes(inSeason season: Int) -> [StreamEpisode] {
        episodes.filter { $0.season == season }.sorted { $0.episode < $1.episode }
    }
}

/// A player embed found on a watch page. The real video URL still has to be
/// resolved out of it (usually an obfuscated JS player), which `StreamResolver`
/// does with a hidden web view.
struct StreamEmbed: Hashable {
    /// The iframe/player URL.
    var url: String
    /// Sent as `Referer` when loading the embed — most hosts 403 without it.
    var referer: String?
    /// "Türkçe Dublaj", "Altyazılı", or the embed host — shown when a page has
    /// more than one option.
    var label: String?
    /// Oynatıcı, sayfaya tıklanana kadar video listesini istemiyor (Dizipal'in
    /// Playerjs'i `$("body").click(initP)` bekliyor) — çözücü yüklemeden sonra
    /// gövdeye tıklatır.
    var tapToStart = false
    /// İç HLS listeleri, ffmpeg'in TLS parmak izini engelleyen bir WAF'ın
    /// arkasında: mpv master'ı açabiliyor ama varyantlar 403. Çözücü listeleri
    /// URLSession ile (Safari'yle aynı TLS) çekip yerel kopyasını verir.
    var localizePlaylists = false
}

/// An external subtitle track found alongside a stream.
struct StreamSubtitle: Hashable {
    var url: URL
    var label: String?
}

/// A ready-to-play stream: the direct media URL plus whatever headers mpv must
/// send to fetch it, and any external subtitle tracks the player also loaded.
struct ResolvedStream {
    var url: URL
    var headers: [String: String]
    var subtitles: [StreamSubtitle] = []
}

/// A titled row of results on the ZyStream landing page (e.g. "Son Eklenen
/// Filmler"), refreshed each visit.
struct StreamShelf: Identifiable {
    var id: String { title }
    var title: String
    var hits: [StreamHit]
}

/// Bir akış sitesinin kendi menüsündeki kategori (tür). Sidebar'daki "Filmler"
/// ve "Diziler" görünümlerinde tab olarak çıkıyor; içeriği o kategorinin liste
/// sayfasından kazınıyor. `providerID` taşınıyor çünkü sayfa o sağlayıcının
/// getiricisiyle yüklenmeli ve birden çok kaynak açıkken hangi siteye ait olduğu
/// bilinmeli.
struct StreamCategory: Identifiable, Hashable {
    var providerID: String
    var title: String
    var pageURL: String
    var id: String { "\(providerID)|\(pageURL)" }
}

/// On-disk shape of `stream-favorites.json`, kept apart from the library like
/// `RemoteFavoritesData`.
struct StreamFavoritesData: Codable {
    var hits: [StreamHit] = []
    init(hits: [StreamHit] = []) { self.hits = hits }
}

enum StreamError: LocalizedError {
    case badURL
    case http(Int)
    case notFound
    case noEmbed
    case resolveFailed

    var errorDescription: String? {
        switch self {
        case .badURL: "Kaynak adresi geçersiz."
        case .http(let code): "Kaynak yanıt vermedi (HTTP \(code))."
        case .notFound: "İçerik bu kaynakta bulunamadı."
        case .noEmbed: "Bu sayfada oynatılabilir bir kaynak bulunamadı."
        case .resolveFailed: "Video adresi çözümlenemedi."
        }
    }
}
