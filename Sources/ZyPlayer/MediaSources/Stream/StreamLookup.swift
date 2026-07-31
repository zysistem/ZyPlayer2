import Foundation
import Observation

/// Bir TMDB başlığını açık akış kaynaklarında arar.
///
/// `ZyStreamStore`'dan ayrı duruyor: o store ZyStream sayfasının kendi arama
/// durumunu (sonuç ızgarası, mesaj) tutuyor ve detay ekranından tetiklenen bir
/// arama o sayfayı silip süpürürdü. Buradaki arama tek bir başlığa ait ve
/// yalnızca açıldığı detay ekranında yaşıyor.
@MainActor
@Observable
final class StreamLookupLoader {

    enum State: Equatable {
        case idle
        case searching
        /// En az bir kaynakta bulundu.
        case found([StreamHit])
        /// Kaynaklar yanıt verdi ama eşleşen içerik yok.
        case empty
        /// Kaynakların tamamı hata verdi — "bulunamadı" demek yanıltıcı olurdu.
        case unreachable
    }

    private(set) var state: State = .idle

    /// Hangi başlık için arandığı. Detay ekranı başka bir yapıma geçtiğinde
    /// sonuçların taşınmaması için kullanılıyor.
    @ObservationIgnored private var searchedID: String?
    /// Eski bir aramanın geç gelen sonucu yenisinin üstüne yazmasın.
    @ObservationIgnored private var token = 0

    /// Ekran başka bir başlığa geçtiyse durumu sıfırlar.
    func reset(forTitleID id: String) {
        guard searchedID != id else { return }
        searchedID = id
        token += 1
        state = .idle
    }

    /// Yapımı açık kaynaklarda arar.
    ///
    /// Üç ad sırayla deneniyor — hangisinin tutacağı siteye göre değişiyor.
    /// Ölçtüğümüz örnek: HdFilmCehennemi'de "İtirafın Bedeli" (TMDB'nin Türkçe
    /// adı) 0 sonuç, "자백의 대가" (orijinal ad) 0 sonuç, "The Price of Confession"
    /// (İngilizce ad) 1 sonuç. Yani İngilizce ad olmadan bu dizi hiç bulunamıyor.
    func search(_ title: RemoteTitle, displayTitle: String, originalTitle: String?,
                settings: AppSettings, providers: [StreamProvider]) async {
        searchedID = title.id
        token += 1
        let current = token

        guard !providers.isEmpty else { state = .unreachable; return }
        state = .searching

        var raw = [displayTitle]
        if let english = await Self.englishTitle(title, settings: settings) {
            raw.append(english)
        }
        if let originalTitle { raw.append(originalTitle) }

        guard current == token else { return }
        let queries = Self.normalizedQueries(raw)
        guard !queries.isEmpty else { state = .empty; return }
        let year = title.year

        var collected: [StreamHit] = []
        var failures = 0

        await withTaskGroup(of: Result<[StreamHit], Error>.self) { group in
            for provider in providers {
                group.addTask {
                    do { return .success(try await Self.hits(from: provider, queries: queries)) }
                    catch { return .failure(error) }
                }
            }
            for await result in group {
                switch result {
                case .success(let hits): collected.append(contentsOf: hits)
                case .failure: failures += 1
                }
            }
        }

        guard current == token else { return }

        if collected.isEmpty {
            state = failures == providers.count ? .unreachable : .empty
            return
        }
        state = .found(Self.ranked(collected, queries: queries, year: year))
    }

    /// Bir kaynakta sorguları sırayla dener, ilk sonuç vereni döndürür. Sorguların
    /// hepsi hata verirse hata fırlatır ki "ulaşılamadı" ile "bulunamadı"
    /// ayrılabilsin.
    private static func hits(from provider: StreamProvider,
                             queries: [String]) async throws -> [StreamHit] {
        var lastError: Error?
        var didSucceed = false
        for query in queries {
            do {
                let found = try await provider.search(query)
                didSucceed = true
                if !found.isEmpty { return found }
            } catch {
                lastError = error
            }
        }
        // Yalnızca hiçbir sorgu tamamlanamadıysa kaynak "ulaşılamadı" sayılır;
        // bir sorgu boş dönmüşse bu geçerli bir "bulunamadı" cevabıdır.
        if !didSucceed, let lastError { throw lastError }
        return []
    }

    /// Yapımın İngilizce adı. Ayarlar zaten İngilizce ise ek istek atılmıyor.
    private static func englishTitle(_ title: RemoteTitle, settings: AppSettings) async -> String? {
        guard settings.hasTMDBToken, !settings.metadataLanguage.hasPrefix("en") else { return nil }
        let client = TMDBClient(token: settings.tmdbToken, language: "en-US")
        switch title.kind {
        case .movie: return try? await client.movieDetail(id: title.tmdbID).title
        case .tv:    return try? await client.tvDetail(id: title.tmdbID).name
        }
    }

    /// Boşları ve birbirinin aynısı olanları atar; en fazla üç sorgu kalır.
    private static func normalizedQueries(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for query in raw {
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 2, seen.insert(fold(trimmed)).inserted else { continue }
            out.append(trimmed)
        }
        return Array(out.prefix(3))
    }

    /// Aynı sayfaya işaret eden sonuçlar teke indirilir, sonra isim ve yıl
    /// yakınlığına göre sıralanır — kaynağın kendi sıralaması alakasız yapımları
    /// da getirebiliyor.
    private static func ranked(_ hits: [StreamHit], queries: [String], year: Int?) -> [StreamHit] {
        var seen = Set<String>()
        let unique = hits.filter { seen.insert($0.id).inserted }
        return unique.sorted { a, b in
            let sa = score(a, queries: queries, year: year)
            let sb = score(b, queries: queries, year: year)
            return sa == sb ? a.title < b.title : sa > sb
        }
    }

    /// Kaba bir yakınlık puanı: birebir ad > sorguyu içeren ad > diğerleri.
    /// Yıl tutuyorsa küçük bir ek puan.
    private static func score(_ hit: StreamHit, queries: [String], year: Int?) -> Int {
        let title = fold(hit.title)
        var best = 0
        for query in queries {
            let q = fold(query)
            if title == q { best = max(best, 3) }
            else if title.contains(q) || q.contains(title) { best = max(best, 2) }
        }
        if let year, let hitYear = hit.year, year == hitYear { best += 1 }
        return best
    }

    /// Karşılaştırma için sadeleştirme: küçük harf, Türkçe harfler latinleştirilmiş,
    /// harf-rakam dışındaki her şey atılmış.
    private static func fold(_ s: String) -> String {
        let lowered = s.lowercased()
            .replacingOccurrences(of: "ı", with: "i")
            .replacingOccurrences(of: "ş", with: "s")
            .replacingOccurrences(of: "ğ", with: "g")
            .replacingOccurrences(of: "ç", with: "c")
            .replacingOccurrences(of: "ö", with: "o")
            .replacingOccurrences(of: "ü", with: "u")
        return String(lowered.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        })
    }
}
