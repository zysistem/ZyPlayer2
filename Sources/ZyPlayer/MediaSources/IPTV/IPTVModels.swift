import Foundation

/// IPTV içeriğinin üç türü. Sağlayıcı üçünü ayrı uçlardan veriyor ve
/// oynatma adresleri de ayrı biçimde kuruluyor.
enum IPTVSection: String, CaseIterable, Identifiable, Codable {
    case live, movies, series
    var id: String { rawValue }

    var title: String {
        switch self {
        case .live: "Canlı TV"
        case .movies: "Filmler"
        case .series: "Diziler"
        }
    }

    var symbol: String {
        switch self {
        case .live: "dot.radiowaves.left.and.right"
        case .movies: "film"
        case .series: "tv"
        }
    }
}

struct IPTVCategory: Identifiable, Codable, Hashable {
    var id: String
    var name: String
}

struct IPTVChannel: Identifiable, Codable, Hashable {
    var id: Int
    var name: String
    var iconURLString: String?
    var categoryID: String?
    /// Sağlayıcının EPG kimliği. Yayın akışı ileride buradan okunabilir.
    var epgChannelID: String?

    var iconURL: URL? { iconURLString.flatMap(URL.init(string:)) }
}

struct IPTVMovie: Identifiable, Codable, Hashable {
    var id: Int
    var name: String
    var iconURLString: String?
    var categoryID: String?
    /// Oynatma adresi bu uzantıyla kuruluyor: sağlayıcı mkv/mp4 karışık veriyor.
    var containerExtension: String
    var rating: Double?

    var iconURL: URL? { iconURLString.flatMap(URL.init(string:)) }
}

struct IPTVSeries: Identifiable, Codable, Hashable {
    var id: Int
    var name: String
    var coverURLString: String?
    var categoryID: String?
    var plot: String?
    var rating: Double?

    var coverURL: URL? { coverURLString.flatMap(URL.init(string:)) }
}

struct IPTVEpisode: Identifiable, Codable, Hashable {
    /// Bölüm kimliği metin: sağlayıcı kimi zaman sayı kimi zaman dize veriyor.
    var id: String
    var title: String
    var season: Int
    var episode: Int
    var containerExtension: String
    /// Bölümün kendi ekran fotoğrafı, özeti ve süresi — sağlayıcı bunları
    /// bölüm listesiyle birlikte veriyor, ayrıca TMDB'ye gitmeye gerek yok.
    var stillURLString: String?
    var plot: String?
    var durationText: String?

    var stillURL: URL? { stillURLString.flatMap(URL.init(string:)) }
}

/// Bir film ya da dizinin ayrıntıları. Sağlayıcı ikisini de aynı alanlarla
/// veriyor, tek bir tür ikisine de yetiyor.
struct IPTVDetail: Codable, Hashable {
    var plot: String?
    var cast: String?
    var director: String?
    var genre: String?
    var rating: Double?
    var releaseDate: String?
    var durationText: String?
    var coverURLString: String?
    var backdropURLString: String?
    /// Sağlayıcının bildirdiği TMDB kimliği. Afiş ve arka planı oradan almak
    /// için kullanılıyor: sağlayıcının kendi görselleri düşük çözünürlüklü ve
    /// kendi sunucusundan geliyor.
    var tmdbID: Int?
    /// TMDB'den alınan, sağlayıcınınkinin yerine geçen görseller.
    var tmdbPosterPath: String?
    var tmdbBackdropPath: String?

    var year: Int? {
        guard let releaseDate, releaseDate.count >= 4 else { return nil }
        return Int(releaseDate.prefix(4))
    }

    var posterURL: URL? {
        if let path = tmdbPosterPath { return TMDBClient.imageURL(path: path, size: "w500") }
        return coverURLString.flatMap(URL.init(string:))
    }

    var backdropURL: URL? {
        if let path = tmdbBackdropPath { return TMDBClient.imageURL(path: path, size: "w1280") }
        return backdropURLString.flatMap(URL.init(string:))
    }

    /// Virgülle ayrılmış oyuncu listesini kırpar.
    var castNames: [String] {
        (cast ?? "").split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

/// Sağlayıcı adlara ülke kodunu ve kalite ekini gömüyor: kategoriler
/// "[TR] HABER" ya da "|TR| 2026 FiLMLERi", kanallar "TR: TRT 1 HD" biçiminde
/// geliyor. Ekranda bu işaretler gürültü yapıyor ve her satırın başı birbirinin
/// aynı oluyor; ayrıştırılıp rozete alınıyorlar, geriye okunur bir ad kalıyor.
enum IPTVNaming {

    /// "[TR] HABER" → ("TR", "HABER");  "TR: TRT 1" → ("TR", "TRT 1")
    static func split(_ raw: String) -> (code: String?, name: String) {
        var name = raw.trimmingCharacters(in: .whitespaces)
        var code: String?

        // Baştaki önek: "[TR] HABER", "TR: TRT 1"
        let leading = [
            #"^[\[\|\(]\s*([A-Za-z]{2,4})\s*[\]\|\)]\s*(.+)$"#,
            #"^([A-Za-z]{2,4})\s*:\s*(.+)$"#
        ]
        for pattern in leading {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: name,
                                               range: NSRange(name.startIndex..., in: name)),
                  match.numberOfRanges > 2,
                  let codeRange = Range(match.range(at: 1), in: name),
                  let nameRange = Range(match.range(at: 2), in: name)
            else { continue }
            code = String(name[codeRange]).uppercased()
            name = String(name[nameRange]).trimmingCharacters(in: .whitespaces)
            break
        }

        // Sondaki etiketler: "Silo |TR|", "WondLa |4K|", bazen art arda birkaçı.
        // Bunlar temizlenmediğinde yalnızca ekranda çirkin durmuyorlar —
        // TMDB araması da adı bulamıyor, dolayısıyla fragman ve afiş gelmiyor.
        if let regex = try? NSRegularExpression(
            pattern: #"\s*[\[\|\(]\s*([A-Za-z0-9]{1,5})\s*[\]\|\)]\s*$"#
        ) {
            while true {
                let range = NSRange(name.startIndex..., in: name)
                guard let match = regex.firstMatch(in: name, range: range),
                      match.numberOfRanges > 1,
                      let tagRange = Range(match.range(at: 1), in: name),
                      let whole = Range(match.range, in: name)
                else { break }
                if code == nil { code = String(name[tagRange]).uppercased() }
                name = String(name[name.startIndex..<whole.lowerBound])
                    .trimmingCharacters(in: .whitespaces)
            }
        }

        return (code, name)
    }

    /// Kanal adının sonundaki kalite eki. "TRT 1 HD" ve "TRT 1 FHD" ayrı
    /// yayınlar; ek atılmıyor, rozete alınıyor ki ayrım korunsun.
    private static let qualityTags = ["4K", "UHD", "FHD", "HD", "SD"]

    /// Adın sonundaki yıl: "Batman: Pelerinli Savaşçı (2024)" → (ad, 2024).
    /// TMDB'de aramak için gerekiyor — sağlayıcı dizilerde kimlik bildirmiyor,
    /// ad da yılla birlikte geldiği için doğrudan aratmak sonuç düşürüyor.
    static func splitYear(_ raw: String) -> (name: String, year: Int?) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard let regex = try? NSRegularExpression(pattern: #"^(.+?)\s*\((\d{4})\)\s*$"#),
              let match = regex.firstMatch(in: trimmed,
                                           range: NSRange(trimmed.startIndex..., in: trimmed)),
              match.numberOfRanges > 2,
              let nameRange = Range(match.range(at: 1), in: trimmed),
              let yearRange = Range(match.range(at: 2), in: trimmed)
        else { return (trimmed, nil) }
        return (String(trimmed[nameRange]).trimmingCharacters(in: .whitespaces),
                Int(trimmed[yearRange]))
    }

    static func splitQuality(_ name: String) -> (name: String, quality: String?) {
        var base = name.trimmingCharacters(in: .whitespaces)
        for tag in qualityTags where base.uppercased().hasSuffix(" " + tag) {
            base = String(base.dropLast(tag.count + 1)).trimmingCharacters(in: .whitespaces)
            return (base, tag)
        }
        return (base, nil)
    }
}

/// Diske yazılan katalog. Liste her açılışta yeniden indirilemeyecek kadar
/// büyük (film kataloğu tek başına ~15 MB), bu yüzden saklanıp yaşına göre
/// tazeleniyor.
struct IPTVCatalog: Codable {
    var channels: [IPTVChannel] = []
    var movies: [IPTVMovie] = []
    var series: [IPTVSeries] = []
    var liveCategories: [IPTVCategory] = []
    var movieCategories: [IPTVCategory] = []
    var seriesCategories: [IPTVCategory] = []
    var updatedAt: Date?

    var isEmpty: Bool { channels.isEmpty && movies.isEmpty && series.isEmpty }

    /// Eski sürümlerde yazılmış, alanları eksik bir katalog da okunabilmeli.
    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        channels = c.value(.channels, [])
        movies = c.value(.movies, [])
        series = c.value(.series, [])
        liveCategories = c.value(.liveCategories, [])
        movieCategories = c.value(.movieCategories, [])
        seriesCategories = c.value(.seriesCategories, [])
        updatedAt = c.optional(.updatedAt)
    }
}

/// Favoriye alınmış bir IPTV içeriği.
///
/// Öğenin kendisi değil, yeniden kurmaya yetecek kadarı saklanıyor: katalog
/// tazelendiğinde nesneler değişiyor ama akış kimliği sabit kalıyor.
struct IPTVFavorite: Codable, Identifiable, Hashable {
    enum Kind: String, Codable { case channel, movie, series }

    var kind: Kind
    var streamID: Int
    var name: String
    var iconURLString: String?
    /// Filmlerde oynatma adresi bu uzantıyla kuruluyor.
    var containerExtension: String?
    var addedAt: Date = Date()

    var id: String { "\(kind.rawValue):\(streamID)" }

    var kindLabel: String {
        switch kind {
        case .channel: "Canlı yayın"
        case .movie: "Film"
        case .series: "Dizi"
        }
    }
    var iconURL: URL? { iconURLString.flatMap(URL.init(string:)) }

    init(kind: Kind, streamID: Int, name: String,
         iconURLString: String? = nil, containerExtension: String? = nil) {
        self.kind = kind
        self.streamID = streamID
        self.name = name
        self.iconURLString = iconURLString
        self.containerExtension = containerExtension
    }

    /// Eski kayıtlarda eksik alan olabilir; hiçbiri zorunlu değil.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = c.value(.kind, Kind.channel)
        streamID = c.value(.streamID, 0)
        name = c.value(.name, "")
        iconURLString = c.optional(.iconURLString)
        containerExtension = c.optional(.containerExtension)
        addedAt = c.value(.addedAt, Date())
    }
}

struct IPTVFavoritesData: Codable {
    var items: [IPTVFavorite] = []
    init(items: [IPTVFavorite] = []) { self.items = items }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = c.value(.items, [])
    }
}
