import Foundation

/// Bir IPTV aboneliğinin bağlantı bilgileri.
///
/// Sağlayıcılar bunu tek bir `get.php` adresi olarak veriyor; kullanıcı o
/// adresi yapıştırdığında parçalarına ayrılıyor, üç alanı elle doldurmak
/// gerekmiyor.
struct IPTVCredentials: Codable, Hashable {
    /// Şema ve gerekiyorsa kapı numarası dahil: "http://sunucu.example:8000"
    var host: String
    var username: String
    var password: String

    var isConfigured: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty
            && !username.isEmpty && !password.isEmpty
    }

    static let empty = IPTVCredentials(host: "", username: "", password: "")

    /// Sağlayıcının verdiği adresten bağlantı bilgilerini çıkarır.
    ///
    /// `http://sunucu:8000/get.php?username=A&password=B&type=m3u_plus` ya da
    /// `player_api.php` biçimindeki adresler kabul edilir; ikisi de aynı
    /// kullanıcı adı/parola çiftini taşıyor.
    static func parse(_ input: String) -> IPTVCredentials? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme, let host = components.host
        else { return nil }

        let items = components.queryItems ?? []
        guard let user = items.first(where: { $0.name.lowercased() == "username" })?.value,
              let pass = items.first(where: { $0.name.lowercased() == "password" })?.value,
              !user.isEmpty, !pass.isEmpty
        else { return nil }

        var base = "\(scheme)://\(host)"
        if let port = components.port { base += ":\(port)" }
        return IPTVCredentials(host: base, username: user, password: pass)
    }
}

/// Xtream Codes API'sini konuşur — IPTV Smarters ve benzerlerinin kullandığı
/// protokol. Sağlayıcı üç içerik türünü ayrı uçlardan veriyor.
struct IPTVClient {

    enum ClientError: LocalizedError {
        case notConfigured
        case badAddress
        case http(Int)
        case rejected(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured: "IPTV bilgileri girilmemiş."
            case .badAddress: "IPTV sunucu adresi geçersiz."
            case .http(let code): "IPTV sunucusuna ulaşılamadı (HTTP \(code))."
            case .rejected(let reason): reason
            }
        }
    }

    var credentials: IPTVCredentials

    /// Hesabın durumu — abonelik bitmişse liste çekmeden önce anlaşılır.
    struct Account {
        var isActive: Bool
        var expiresAt: Date?
        var maxConnections: Int?
        var message: String?
    }

    // MARK: - İstek

    private func endpoint(action: String? = nil, extra: [URLQueryItem] = []) throws -> URL {
        guard credentials.isConfigured else { throw ClientError.notConfigured }
        let base = credentials.host.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard var components = URLComponents(string: base + "/player_api.php") else {
            throw ClientError.badAddress
        }
        var items = [
            URLQueryItem(name: "username", value: credentials.username),
            URLQueryItem(name: "password", value: credentials.password)
        ]
        if let action { items.append(URLQueryItem(name: "action", value: action)) }
        items += extra
        components.queryItems = items
        guard let url = components.url else { throw ClientError.badAddress }
        return url
    }

    private func data(action: String? = nil, extra: [URLQueryItem] = [],
                      timeout: TimeInterval = 60) async throws -> Data {
        var request = URLRequest(url: try endpoint(action: action, extra: extra))
        // Listeler büyük (film kataloğu tek başına ~15 MB); kısa bir zaman aşımı
        // yavaş bir sunucuda katalogu hiç indirtmiyor.
        request.timeoutInterval = timeout
        request.setValue("ZyPlayer", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ClientError.http(http.statusCode)
        }
        return data
    }

    // MARK: - Hesap

    func account() async throws -> Account {
        let raw = try await data(timeout: 20)
        guard let object = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let info = object["user_info"] as? [String: Any]
        else { throw ClientError.rejected("Sunucu beklenmedik bir yanıt verdi.") }

        let status = (info["status"] as? String)?.lowercased() ?? ""
        let active = status == "active"
        var expires: Date?
        if let stamp = info["exp_date"] as? String, let seconds = TimeInterval(stamp) {
            expires = Date(timeIntervalSince1970: seconds)
        } else if let seconds = info["exp_date"] as? TimeInterval {
            expires = Date(timeIntervalSince1970: seconds)
        }
        let maxConnections = Int((info["max_connections"] as? String) ?? "")
            ?? (info["max_connections"] as? Int)

        return Account(
            isActive: active,
            expiresAt: expires,
            maxConnections: maxConnections,
            message: active ? nil : "Abonelik etkin değil (durum: \(status.isEmpty ? "bilinmiyor" : status))."
        )
    }

    // MARK: - Kategoriler

    func categories(for section: IPTVSection) async throws -> [IPTVCategory] {
        let action = switch section {
        case .live: "get_live_categories"
        case .movies: "get_vod_categories"
        case .series: "get_series_categories"
        }
        let raw = try await data(action: action, timeout: 30)
        let rows = (try? JSONSerialization.jsonObject(with: raw)) as? [[String: Any]] ?? []
        return rows.compactMap { row in
            guard let name = row["category_name"] as? String, !name.isEmpty else { return nil }
            let id = (row["category_id"] as? String)
                ?? (row["category_id"] as? Int).map(String.init)
            guard let id else { return nil }
            return IPTVCategory(id: id, name: name)
        }
    }

    // MARK: - İçerik

    func channels() async throws -> [IPTVChannel] {
        let rows = try await rows(action: "get_live_streams")
        return rows.compactMap { row in
            guard let id = Self.int(row, "stream_id"),
                  let name = Self.string(row, "name") else { return nil }
            return IPTVChannel(
                id: id, name: name,
                iconURLString: Self.string(row, "stream_icon"),
                categoryID: Self.string(row, "category_id"),
                epgChannelID: Self.string(row, "epg_channel_id")
            )
        }
    }

    func movies() async throws -> [IPTVMovie] {
        let rows = try await rows(action: "get_vod_streams", timeout: 120)
        return rows.compactMap { row in
            guard let id = Self.int(row, "stream_id"),
                  let name = Self.string(row, "name") else { return nil }
            return IPTVMovie(
                id: id, name: name,
                iconURLString: Self.string(row, "stream_icon"),
                categoryID: Self.string(row, "category_id"),
                containerExtension: Self.string(row, "container_extension") ?? "mp4",
                rating: Self.double(row, "rating")
            )
        }
    }

    func series() async throws -> [IPTVSeries] {
        let rows = try await rows(action: "get_series", timeout: 90)
        return rows.compactMap { row in
            guard let id = Self.int(row, "series_id"),
                  let name = Self.string(row, "name") else { return nil }
            return IPTVSeries(
                id: id, name: name,
                coverURLString: Self.string(row, "cover"),
                categoryID: Self.string(row, "category_id"),
                plot: Self.string(row, "plot"),
                rating: Self.double(row, "rating")
            )
        }
    }

    /// Bir filmin ayrıntıları.
    func movieDetail(vodID: Int) async throws -> IPTVDetail {
        let raw = try await data(action: "get_vod_info",
                                 extra: [URLQueryItem(name: "vod_id", value: String(vodID))],
                                 timeout: 30)
        let object = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] ?? [:]
        return Self.detail(from: object["info"] as? [String: Any] ?? [:])
    }

    /// Bir dizinin ayrıntıları ve bölümleri tek istekte gelir.
    func seriesDetail(seriesID: Int) async throws -> (detail: IPTVDetail, episodes: [Int: [IPTVEpisode]]) {
        let raw = try await data(action: "get_series_info",
                                 extra: [URLQueryItem(name: "series_id", value: String(seriesID))],
                                 timeout: 45)
        let object = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] ?? [:]
        let detail = Self.detail(from: object["info"] as? [String: Any] ?? [:])
        return (detail, Self.episodes(from: object))
    }

    private static func detail(from info: [String: Any]) -> IPTVDetail {
        // `backdrop_path` dizi olarak geliyor; ilki alınıyor.
        let backdrop = (info["backdrop_path"] as? [String])?.first
            ?? (info["backdrop_path"] as? String)
        return IPTVDetail(
            plot: string(info, "plot") ?? string(info, "description"),
            cast: string(info, "cast") ?? string(info, "actors"),
            director: string(info, "director"),
            genre: string(info, "genre"),
            rating: double(info, "rating"),
            releaseDate: string(info, "releasedate") ?? string(info, "release_date")
                ?? string(info, "releaseDate"),
            durationText: string(info, "duration"),
            coverURLString: string(info, "movie_image") ?? string(info, "cover")
                ?? string(info, "cover_big"),
            backdropURLString: backdrop,
            tmdbID: int(info, "tmdb_id")
        )
    }

    /// Bir dizinin bölümleri, sezona göre gruplanmış.
    func episodes(seriesID: Int) async throws -> [Int: [IPTVEpisode]] {
        let raw = try await data(action: "get_series_info",
                                 extra: [URLQueryItem(name: "series_id", value: String(seriesID))],
                                 timeout: 45)
        let object = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] ?? [:]
        return Self.episodes(from: object)
    }

    private static func episodes(from object: [String: Any]) -> [Int: [IPTVEpisode]] {
        guard let seasons = object["episodes"] as? [String: Any] else { return [:] }

        var result: [Int: [IPTVEpisode]] = [:]
        for (key, value) in seasons {
            guard let rows = value as? [[String: Any]] else { continue }
            let seasonNumber = Int(key) ?? 0
            let episodes: [IPTVEpisode] = rows.compactMap { row in
                let id = (row["id"] as? String) ?? (row["id"] as? Int).map(String.init)
                guard let id else { return nil }
                let number = Int((row["episode_num"] as? String) ?? "")
                    ?? (row["episode_num"] as? Int) ?? 0
                let title = (row["title"] as? String) ?? "Bölüm \(number)"
                let ext = (row["container_extension"] as? String) ?? "mp4"
                // Bölümün kendi görseli, özeti ve süresi `info` altında geliyor.
                let info = row["info"] as? [String: Any] ?? [:]
                return IPTVEpisode(
                    id: id, title: title, season: seasonNumber,
                    episode: number, containerExtension: ext,
                    stillURLString: string(info, "movie_image"),
                    plot: string(info, "plot"),
                    durationText: string(info, "duration")
                )
            }
            if !episodes.isEmpty {
                result[seasonNumber] = episodes.sorted { $0.episode < $1.episode }
            }
        }
        return result
    }

    // MARK: - Oynatma adresleri

    /// Canlı yayın. `.m3u8` seçiliyor: sunucu bu biçimi bildiriyor ve kesilen
    /// bir bağlantıdan sonra kendini toparlaması ham akıştan daha iyi.
    func liveURL(_ channel: IPTVChannel) -> URL? {
        url(path: "live", id: String(channel.id), extension: "m3u8")
    }

    func movieURL(_ movie: IPTVMovie) -> URL? {
        url(path: "movie", id: String(movie.id), extension: movie.containerExtension)
    }

    func episodeURL(_ episode: IPTVEpisode) -> URL? {
        url(path: "series", id: episode.id, extension: episode.containerExtension)
    }

    private func url(path: String, id: String, extension ext: String) -> URL? {
        let base = credentials.host.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let user = credentials.username.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? credentials.username
        let pass = credentials.password.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? credentials.password
        return URL(string: "\(base)/\(path)/\(user)/\(pass)/\(id).\(ext)")
    }

    // MARK: - Çözümleme yardımı
    //
    // Alanlar tek tek ve toleranslı okunuyor. Sebebi: Xtream sunucuları aynı
    // alanı kâh sayı kâh metin gönderiyor (`stream_id: 541` ile
    // `stream_id: "541"` aynı listede yan yana çıkabiliyor). Katı bir `Codable`
    // tek bir aykırı kayıt yüzünden binlerce satırlık listeyi düşürürdü.

    private func rows(action: String, timeout: TimeInterval = 60) async throws -> [[String: Any]] {
        let raw = try await data(action: action, timeout: timeout)
        return (try? JSONSerialization.jsonObject(with: raw)) as? [[String: Any]] ?? []
    }

    private static func int(_ row: [String: Any], _ key: String) -> Int? {
        if let value = row[key] as? Int { return value }
        if let text = row[key] as? String { return Int(text) }
        return nil
    }

    private static func double(_ row: [String: Any], _ key: String) -> Double? {
        if let value = row[key] as? Double { return value }
        if let text = row[key] as? String { return Double(text) }
        return nil
    }

    private static func string(_ row: [String: Any], _ key: String) -> String? {
        if let text = row[key] as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let value = row[key] as? Int { return String(value) }
        return nil
    }
}
