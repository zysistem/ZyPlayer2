import Foundation

/// Minimal TMDB v3 client authenticated with a v4 read-access token.
struct TMDBClient {

    enum ClientError: LocalizedError {
        case missingToken
        case http(Int)

        var errorDescription: String? {
            switch self {
            case .missingToken: "TMDB jetonu girilmemiş."
            case .http(let code): "TMDB isteği başarısız (HTTP \(code))."
            }
        }
    }

    var token: String
    var language: String = "tr-TR"

    private static let base = URL(string: "https://api.themoviedb.org/3")!
    static let imageBase = URL(string: "https://image.tmdb.org/t/p")!

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    // MARK: - Requests

    /// `fresh: true` isteği önbelleği tümüyle atlar. Netflix/Prime "son eklenen"
    /// rafları gibi sık değişen listelerde şart: TMDB yanıtları `Cache-Control`
    /// başlığı taşıdığından, varsayılan önbellek politikasıyla ana ekran her
    /// açıldığında istek yeniden gitse bile aynı bayat liste dönüyordu.
    private func get<T: Decodable>(_ path: String, query: [String: String] = [:],
                                   fresh: Bool = false) async throws -> T {
        guard !token.isEmpty else { throw ClientError.missingToken }

        var components = URLComponents(
            url: Self.base.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        )!
        var items = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        items.append(URLQueryItem(name: "language", value: language))
        components.queryItems = items

        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.timeoutInterval = 20
        if fresh { request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData }

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ClientError.http(http.statusCode)
        }
        return try Self.decoder.decode(T.self, from: data)
    }

    // MARK: - Endpoints

    func searchMovie(title: String, year: Int?) async throws -> [MovieResult] {
        var query = ["query": title, "include_adult": "false"]
        if let year { query["year"] = String(year) }
        let response: SearchResponse<MovieResult> = try await get("search/movie", query: query)
        return response.results
    }

    func searchTV(name: String) async throws -> [TVResult] {
        let response: SearchResponse<TVResult> = try await get(
            "search/tv", query: ["query": name, "include_adult": "false"]
        )
        return response.results
    }

    /// Mixed film/show search, used when the query finds nothing in the library
    /// — the user still gets a result, straight from TMDB.
    func searchMulti(query: String) async throws -> [MultiResult] {
        let response: SearchResponse<MultiResult> = try await get(
            "search/multi", query: ["query": query, "include_adult": "false"]
        )
        return response.results
    }

    func movieDetail(id: Int) async throws -> MovieDetail {
        try await get("movie/\(id)", query: ["append_to_response": "credits"])
    }

    func tvDetail(id: Int) async throws -> TVDetail {
        try await get("tv/\(id)", query: ["append_to_response": "credits"])
    }

    func episodeDetail(showID: Int, season: Int, episode: Int) async throws -> EpisodeDetail {
        try await get("tv/\(showID)/season/\(season)/episode/\(episode)")
    }

    /// A whole season's episodes in one request, for showing a season the user
    /// does not own.
    func seasonDetail(showID: Int, season: Int) async throws -> SeasonDetail {
        try await get("tv/\(showID)/season/\(season)")
    }

    // MARK: - People

    /// Everything one person appeared in or worked on, films and shows together.
    func personCredits(id: Int) async throws -> CombinedCredits {
        try await get("person/\(id)/combined_credits")
    }

    func person(id: Int) async throws -> PersonDetail {
        try await get("person/\(id)")
    }

    /// A show's IMDb id, which subtitle addons key on.
    func externalIDs(tvID: Int) async throws -> ExternalIDs {
        try await get("tv/\(tvID)/external_ids")
    }

    /// Resolves an IMDb id (`tt…`) to its TMDB movie or show — an exact match,
    /// unlike a title search. Used by ZyStream, whose pages carry the IMDb link.
    func find(imdbID: String) async throws -> FindResponse {
        try await get("find/\(imdbID)", query: ["external_source": "imdb_id"])
    }

    // MARK: - Discover

    /// What the world is watching today. Used to surface the user's own titles
    /// that happen to be trending, so Home changes day to day.
    func trendingMovies() async throws -> [MovieResult] {
        let response: SearchResponse<MovieResult> = try await get("trending/movie/day")
        return response.results
    }

    func trendingShows() async throws -> [TVResult] {
        let response: SearchResponse<TVResult> = try await get("trending/tv/day")
        return response.results
    }

    /// In cinemas now. Unlike everything else here these are not library items —
    /// the user may own none of them.
    func nowPlaying(region: String = "US", page: Int = 1) async throws -> [MovieResult] {
        let response: SearchResponse<MovieResult> = try await get(
            "movie/now_playing", query: ["region": region, "page": String(page)]
        )
        return response.results
    }

    // MARK: - Apple TV+

    /// Apple TV+ originals, which TMDB models as a network rather than a
    /// provider: `with_watch_providers` would also return everything the
    /// service merely licenses.
    private static let appleTVNetwork = 2552
    /// Apple Studios. Films have no network, so the producer is the filter.
    private static let appleStudios = 194232

    func appleTVShows(page: Int = 1) async throws -> [TVResult] {
        let response: SearchResponse<TVResult> = try await get(
            "discover/tv",
            query: ["with_networks": String(Self.appleTVNetwork),
                    "sort_by": "popularity.desc",
                    "page": String(page)]
        )
        return response.results
    }

    func appleTVMovies(page: Int = 1) async throws -> [MovieResult] {
        let response: SearchResponse<MovieResult> = try await get(
            "discover/movie",
            query: ["with_companies": String(Self.appleStudios),
                    "sort_by": "popularity.desc",
                    "page": String(page)]
        )
        return response.results
    }

    // MARK: - Yayın platformları (Netflix, Prime Video…)

    /// Bir platformun kataloğundaki filmler, en yeni çıkandan başlayarak.
    ///
    /// `providerIDs` TMDB'nin `with_watch_providers` alanı: birden çok kimlik
    /// `|` ile VEYA'lanır (Prime Video kimi bölgede 9, kimi bölgede 119).
    /// `watch_region` zorunlu — platformun kataloğu ülkeye göre değişiyor.
    /// `flatrate` yalnızca aboneliğe dahil olanları bırakır, kiralık/satılık
    /// başlıkları eler.
    func providerMovies(providerIDs: String, region: String, page: Int = 1) async throws -> [MovieResult] {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        let response: SearchResponse<MovieResult> = try await get(
            "discover/movie",
            query: ["with_watch_providers": providerIDs,
                    "watch_region": region,
                    "with_watch_monetization_types": "flatrate",
                    "sort_by": "primary_release_date.desc",
                    "primary_release_date.lte": formatter.string(from: Date()),
                    // Oy eşiği koymuyoruz: yeni çıkan/yeni eklenen filmlerin henüz
                    // oyu olmuyor ve tam da göstermek istediğimiz "son eklenenler"
                    // eleniyordu. Çöpü afiş zorunluluğu (store'daki posterPath
                    // süzgeci) zaten temizliyor.
                    "include_adult": "false",
                    "page": String(page)],
            fresh: true
        )
        return response.results
    }

    /// Aynısının dizi hâli; ölçüt ilk yayın tarihi.
    func providerShows(providerIDs: String, region: String, page: Int = 1) async throws -> [TVResult] {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        let response: SearchResponse<TVResult> = try await get(
            "discover/tv",
            query: ["with_watch_providers": providerIDs,
                    "watch_region": region,
                    "with_watch_monetization_types": "flatrate",
                    "sort_by": "first_air_date.desc",
                    "first_air_date.lte": formatter.string(from: Date()),
                    // Oy eşiği yok — yeni eklenen diziler oysuz gelip eleniyordu.
                    "include_adult": "false",
                    "page": String(page)],
            fresh: true
        )
        return response.results
    }

    /// Platform kimliği → logo yolu. Logoyu elle gömmek yerine TMDB'den almak,
    /// marka görselini kendi kaynağından güncel tutuyor.
    func watchProviderLogos(region: String) async throws -> [Int: String] {
        let response: WatchProviderList = try await get(
            "watch/providers/movie", query: ["watch_region": region]
        )
        return Dictionary(
            response.results.compactMap { row in
                row.logoPath.map { (row.providerId, $0) }
            },
            uniquingKeysWith: { first, _ in first }
        )
    }

    func discoverMovies(genreID: Int, page: Int = 1) async throws -> [MovieResult] {
        let response: SearchResponse<MovieResult> = try await get(
            "discover/movie",
            query: ["with_genres": String(genreID),
                    "sort_by": "popularity.desc",
                    "page": String(page)]
        )
        return response.results
    }

    /// Hindistan yapımı filmler.
    ///
    /// Ölçüt ülke (`with_origin_country=IN`), dil değil: Hindistan sineması
    /// Hintçenin yanında Tamil, Telugu, Malayalam ve daha fazlasında üretiliyor,
    /// `with_original_language=hi` bunların hepsini dışarıda bırakırdı.
    ///
    /// `upcoming` true iken bugünden sonrası en yakın tarihten başlayarak,
    /// false iken çıkmış olanlar popülerlik sırasına göre gelir.
    func indianMovies(upcoming: Bool, page: Int = 1) async throws -> [MovieResult] {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        let today = formatter.string(from: Date())

        var query = [
            "with_origin_country": "IN",
            "page": String(page),
            // Afişsiz, oy almamış kayıtlar listeyi kirletiyor.
            "include_adult": "false"
        ]
        if upcoming {
            query["primary_release_date.gte"] = today
            query["sort_by"] = "primary_release_date.asc"
        } else {
            query["primary_release_date.lte"] = today
            query["sort_by"] = "popularity.desc"
        }

        let response: SearchResponse<MovieResult> = try await get("discover/movie", query: query)
        return response.results
    }

    func discoverShows(genreID: Int, page: Int = 1) async throws -> [TVResult] {
        let response: SearchResponse<TVResult> = try await get(
            "discover/tv",
            query: ["with_genres": String(genreID),
                    "sort_by": "popularity.desc",
                    "page": String(page)]
        )
        return response.results
    }

    /// Trailers and teasers. Falls back to English when the chosen language has
    /// none, which is common for Turkish.
    func trailers(movieID: Int) async throws -> [VideoResult] {
        if language.lowercased().hasPrefix("en") {
            let localized: VideoList = try await get("movie/\(movieID)/videos")
            return Self.pickTrailers(localized.results) ?? []
        }
        var english = self
        english.language = "en-US"
        async let localizedReq: VideoList = get("movie/\(movieID)/videos")
        async let englishReq: VideoList = english.get("movie/\(movieID)/videos")
        if let localizedList = try? await localizedReq,
           let best = Self.pickTrailers(localizedList.results), !best.isEmpty {
            return best
        }
        if let englishList = try? await englishReq,
           let best = Self.pickTrailers(englishList.results) {
            return best
        }
        return []
    }

    func trailers(tvID: Int) async throws -> [VideoResult] {
        if language.lowercased().hasPrefix("en") {
            let localized: VideoList = try await get("tv/\(tvID)/videos")
            return Self.pickTrailers(localized.results) ?? []
        }
        var english = self
        english.language = "en-US"
        async let localizedReq: VideoList = get("tv/\(tvID)/videos")
        async let englishReq: VideoList = english.get("tv/\(tvID)/videos")
        if let localizedList = try? await localizedReq,
           let best = Self.pickTrailers(localizedList.results), !best.isEmpty {
            return best
        }
        if let englishList = try? await englishReq,
           let best = Self.pickTrailers(englishList.results) {
            return best
        }
        return []
    }

    /// YouTube trailers first, then teasers; official ones lead.
    private static func pickTrailers(_ results: [VideoResult]) -> [VideoResult]? {
        let youtube = results.filter { $0.site?.lowercased() == "youtube" && $0.key != nil }
        guard !youtube.isEmpty else { return nil }
        let ranked = youtube.sorted { lhs, rhs in
            let order: (VideoResult) -> Int = { video in
                switch video.type?.lowercased() {
                case "trailer": 0
                case "teaser": 1
                default: 2
                }
            }
            if order(lhs) != order(rhs) { return order(lhs) < order(rhs) }
            return (lhs.official ?? false) && !(rhs.official ?? false)
        }
        return ranked
    }

    /// Full URL for a TMDB image path such as `/abc123.jpg`.
    static func imageURL(path: String, size: String = "w500") -> URL {
        imageBase.appendingPathComponent(size).appendingPathComponent(path)
    }
}

// MARK: - Response models

struct SearchResponse<T: Decodable>: Decodable {
    var results: [T]
}

/// `watch/providers/movie` yanıtı — yalnızca logo yolu için okunuyor.
struct WatchProviderList: Decodable {
    struct Row: Decodable {
        var providerId: Int
        var providerName: String?
        var logoPath: String?
    }
    var results: [Row]
}

struct MovieResult: Decodable {
    var id: Int
    var title: String
    var originalTitle: String?
    var overview: String?
    var releaseDate: String?
    var posterPath: String?
    var backdropPath: String?
    var voteAverage: Double?

    var year: Int? {
        guard let releaseDate, releaseDate.count >= 4 else { return nil }
        return Int(releaseDate.prefix(4))
    }
}

struct TVResult: Decodable {
    var id: Int
    var name: String
    var originalName: String?
    var overview: String?
    var firstAirDate: String?
    var posterPath: String?
    var backdropPath: String?
    var voteAverage: Double?

    var year: Int? {
        guard let firstAirDate, firstAirDate.count >= 4 else { return nil }
        return Int(firstAirDate.prefix(4))
    }
}

/// One row of `search/multi`. Films carry `title`/`release_date`, shows carry
/// `name`/`first_air_date`, and people carry neither.
struct MultiResult: Decodable {
    var id: Int
    var mediaType: String?
    var title: String?
    var name: String?
    var originalTitle: String?
    var originalName: String?
    var overview: String?
    var releaseDate: String?
    var firstAirDate: String?
    var posterPath: String?
    var backdropPath: String?
    var voteAverage: Double?
    /// People only.
    var profilePath: String?
    var knownForDepartment: String?

    func year(for kind: RemoteKind) -> Int? {
        let date = kind == .movie ? releaseDate : firstAirDate
        guard let date, date.count >= 4 else { return nil }
        return Int(date.prefix(4))
    }
}

struct Genre: Decodable {
    var id: Int
    var name: String
}

struct MovieDetail: Decodable {
    var id: Int
    var title: String
    /// Yapımın kendi dilindeki adı. Akış siteleri başlıkları çoğunlukla bununla
    /// listelediği için "akışlarda ara" yerel adın yanında bunu da deniyor.
    var originalTitle: String?
    /// `tt0111161`. TMDB includes it in the movie detail payload, so subtitle
    /// lookups need no extra request. TV has to ask `external_ids` separately.
    var imdbId: String?
    var overview: String?
    var posterPath: String?
    var backdropPath: String?
    var runtime: Int?
    var releaseDate: String?
    var voteAverage: Double?
    var genres: [Genre]?
    var credits: Credits?

    var year: Int? {
        guard let releaseDate, releaseDate.count >= 4 else { return nil }
        return Int(releaseDate.prefix(4))
    }
}

struct TVDetail: Decodable {
    var id: Int
    var name: String
    /// Dizinin kendi dilindeki adı — `MovieDetail.originalTitle` ile aynı gerekçe.
    var originalName: String?
    var overview: String?
    var posterPath: String?
    var backdropPath: String?
    var firstAirDate: String?
    var numberOfSeasons: Int?
    var voteAverage: Double?
    var genres: [Genre]?
    var credits: Credits?
    var seasons: [TVSeasonSummary]?

    var year: Int? {
        guard let firstAirDate, firstAirDate.count >= 4 else { return nil }
        return Int(firstAirDate.prefix(4))
    }
}

/// A season as listed on the show detail: enough for the season tabs, without a
/// request per season.
struct TVSeasonSummary: Decodable {
    var seasonNumber: Int?
    var episodeCount: Int?
    var name: String?
}

struct SeasonDetail: Decodable {
    var episodes: [EpisodeDetail]?
}

struct EpisodeDetail: Decodable {
    var id: Int
    var name: String?
    var overview: String?
    var stillPath: String?
    var airDate: String?
    var runtime: Int?
    var episodeNumber: Int?
    var seasonNumber: Int?
}

struct Credits: Decodable {
    var cast: [CastMember]?
    var crew: [CrewMember]?
}

struct CrewMember: Decodable {
    var id: Int
    var name: String
    var job: String?
    var department: String?
    var profilePath: String?
}

struct PersonDetail: Decodable {
    var id: Int
    var name: String
    var biography: String?
    var profilePath: String?
    var knownForDepartment: String?
    var birthday: String?
    var placeOfBirth: String?
}

/// A person's whole filmography. The same title comes back once per job, so
/// `crew` repeats: Nolan's *Odyssey* appears as Director, Writer and Producer.
struct CombinedCredits: Decodable {
    var cast: [CombinedCredit]?
    var crew: [CombinedCredit]?

    struct CombinedCredit: Decodable {
        var id: Int
        var mediaType: String?
        var title: String?
        var name: String?
        var overview: String?
        var posterPath: String?
        var backdropPath: String?
        var voteAverage: Double?
        var popularity: Double?
        var releaseDate: String?
        var firstAirDate: String?
        /// Set on cast rows.
        var character: String?
        /// Set on crew rows.
        var job: String?

        var kind: RemoteKind? {
            switch mediaType {
            case "movie": .movie
            case "tv": .tv
            default: nil
            }
        }

        var year: Int? {
            let date = kind == .movie ? releaseDate : firstAirDate
            guard let date, date.count >= 4 else { return nil }
            return Int(date.prefix(4))
        }
    }
}

struct ExternalIDs: Decodable {
    var imdbId: String?
}

/// `find/{external_id}` result: the movie or show behind an IMDb id.
///
/// Anahtarlara DİKKAT: bu dosyanın çözümleyicisi `.convertFromSnakeCase`
/// kullanır, yani gelen `movie_results` daha container'a girmeden
/// `movieResults`'a çevrilir. Buraya elle `case movieResults = "movie_results"`
/// yazmak — eskiden yazdığı gibi — hiçbir anahtarı eşleştiremez ve tüm
/// çözümleme `keyNotFound` ile düşer; çağıranlar `try?` kullandığı için de hata
/// sessizce yutulur, IMDb kimliğiyle arama hep boş döner.
struct FindResponse: Decodable {
    var movieResults: [MovieResult] = []
    var tvResults: [TVResult] = []

    private enum CodingKeys: String, CodingKey {
        case movieResults, tvResults
    }

    /// TMDB bir tür için hiç sonuç döndürmediğinde alan tümden gelmeyebilir;
    /// eksik anahtar boş liste demektir, hata değil.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        movieResults = c.value(.movieResults, [])
        tvResults = c.value(.tvResults, [])
    }
}

struct VideoList: Decodable {
    var results: [VideoResult]
}

struct VideoResult: Decodable, Identifiable {
    var id: String?
    var key: String?
    var name: String?
    var site: String?
    var type: String?
    var official: Bool?

    /// mpv resolves this through yt-dlp.
    var youtubeURL: URL? {
        guard let key else { return nil }
        return URL(string: "https://www.youtube.com/watch?v=\(key)")
    }
}

struct CastMember: Decodable {
    var id: Int
    var name: String
    var character: String?
    var profilePath: String?
}
