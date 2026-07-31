import Compression
import Foundation

/// IMDb puanlarını IMDb'nin **resmi veri kümesinden** okur.
///
/// Neden böyle: imdb.com sayfaları AWS WAF sınavının arkasında (düz istekler
/// gövdesiz 202 dönüyor), ücretsiz üçüncü taraf IMDb API'lerinin hepsi ölü ya da
/// güvenilmez, TMDB ise yalnızca kendi oyunu veriyor — ve ikisi ciddi biçimde
/// ayrışıyor (bir Telugu filminde IMDb 7,6'ya karşı TMDB 2,7).
///
/// `title.ratings.tsv.gz` anahtar istemiyor, günde bir güncelleniyor ve ~8 MB.
/// Tüm dosyayı bellekte tutmak yerine (1,7 milyon satır) yalnızca sorulan
/// kimlikler tek geçişte süzülüp küçük bir JSON'a yazılıyor.
enum IMDbRatingStore {
    private static let datasetURL = URL(string: "https://datasets.imdbws.com/title.ratings.tsv.gz")!

    private struct Cache: Codable {
        var ratings: [String: Double] = [:]
        /// Veri kümesinin en son ne zaman tarandığı.
        var updatedAt: Date = .distantPast
        /// Veri kümesinde aranıp bulunamayan kimlikler; her açılışta 8 MB'ı
        /// yeniden indirmemek için hatırlanıyor.
        var missing: [String] = []

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            ratings = (try? c.decode([String: Double].self, forKey: .ratings)) ?? [:]
            updatedAt = (try? c.decode(Date.self, forKey: .updatedAt)) ?? .distantPast
            missing = (try? c.decode([String].self, forKey: .missing)) ?? []
        }
    }

    private static let store = LocalStore(fileName: "imdb-ratings.json", defaultValue: Cache())

    /// Veri kümesi bu süre boyunca taze sayılır — IMDb'yi günde birden fazla
    /// yormaya gerek yok.
    private static let freshness: TimeInterval = 24 * 60 * 60

    /// Bilinen puanlar; ağa çıkmadan döner.
    static func known(_ ids: [String]) -> [String: Double] {
        let cached = store.value.ratings
        return ids.reduce(into: [:]) { result, id in
            if let rating = cached[id] { result[id] = rating }
        }
    }

    /// İstenen kimliklerin puanlarını döndürür; eksik olanlar için veri kümesini
    /// bir kez tarar.
    static func ratings(for ids: [String]) async -> [String: Double] {
        let cache = store.value
        let unknown = Set(ids).subtracting(cache.ratings.keys)
        // Daha önce arayıp bulamadıklarımızı, veri kümesi tazelenene dek
        // yeniden sormuyoruz.
        let stale = Date().timeIntervalSince(cache.updatedAt) > freshness
        let worthFetching = stale ? unknown : unknown.subtracting(cache.missing)

        guard !worthFetching.isEmpty else { return known(ids) }

        if let found = await scanDataset(for: worthFetching) {
            let notFound = worthFetching.subtracting(found.keys)
            store.update { current in
                current.ratings.merge(found) { _, new in new }
                current.updatedAt = Date()
                // Liste sınırsız büyümesin.
                current.missing = Array(Set(current.missing).union(notFound).prefix(5000))
            }
        }
        return known(ids)
    }

    /// Veri kümesini indirip yalnızca istenen satırları toplar.
    private static func scanDataset(for wanted: Set<String>) async -> [String: Double]? {
        guard let raw = try? await download(), let tsv = gunzip(raw) else { return nil }

        var found: [String: Double] = [:]
        var remaining = wanted

        // Satır satır dolaşmak yerine bayt üzerinde ilerliyoruz: 25 MB'lık metni
        // String'e çevirip bölmek hem yavaş hem bellek israfı olurdu.
        tsv.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            var lineStart = 0
            let count = buffer.count
            var index = 0
            while index < count, !remaining.isEmpty {
                guard buffer[index] == 0x0A else { index += 1; continue }
                // Sıra önemli: sonraki satır bu satır sonundan **bir** sonra
                // başlıyor. `index` önce artırılırsa her satır bir bayt kayar ve
                // hiçbir kimlik tutmaz.
                defer { lineStart = index + 1; index += 1 }

                // Satır: tconst \t averageRating \t numVotes
                let line = UnsafeRawBufferPointer(rebasing: buffer[lineStart..<index])
                guard let firstTab = line.firstIndex(of: 0x09) else { continue }
                let id = String(decoding: UnsafeRawBufferPointer(rebasing: line[0..<firstTab]),
                                as: UTF8.self)
                guard remaining.contains(id) else { continue }

                let rest = UnsafeRawBufferPointer(rebasing: line[(firstTab + 1)...])
                let end = rest.firstIndex(of: 0x09) ?? rest.count
                let value = String(decoding: UnsafeRawBufferPointer(rebasing: rest[0..<end]),
                                   as: UTF8.self)
                if let rating = Double(value) {
                    found[id] = rating
                    remaining.remove(id)
                }
            }
        }
        return found
    }

    private static func download() async throws -> Data {
        var request = URLRequest(url: datasetURL)
        request.timeoutInterval = 120
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    /// gzip → düz metin.
    ///
    /// Apple'ın `decompressed(using: .zlib)`'i başlıksız ham DEFLATE bekliyor,
    /// bu yüzden gzip başlığı elle atlanıyor. IMDb'nin dosyasında bayrak alanı
    /// boş (ne dosya adı ne ek alan), ama yine de bayraklar okunuyor —
    /// dosyanın biçimi bir gün değişirse sessizce bozulmasın.
    private static func gunzip(_ data: Data) -> Data? {
        guard data.count > 18, data[0] == 0x1F, data[1] == 0x8B, data[2] == 0x08 else {
            return nil
        }
        let flags = data[3]
        var offset = 10

        if flags & 0b0000_0100 != 0 {   // FEXTRA
            guard data.count > offset + 1 else { return nil }
            let length = Int(data[offset]) | (Int(data[offset + 1]) << 8)
            offset += 2 + length
        }
        for bit in [0b0000_1000, 0b0001_0000] where flags & UInt8(bit) != 0 {  // FNAME, FCOMMENT
            while offset < data.count, data[offset] != 0 { offset += 1 }
            offset += 1
        }
        if flags & 0b0000_0010 != 0 { offset += 2 }   // FHCRC

        guard offset < data.count else { return nil }
        let deflate = data.subdata(in: offset..<data.count)
        // Sıkıştırılmış boyutun ~4 katı yer ayrılıyor; yetmezse nil döner ve
        // puanlar bu turda görünmez, uygulama çalışmayı sürdürür.
        return try? (deflate as NSData).decompressed(using: .zlib) as Data
    }
}
