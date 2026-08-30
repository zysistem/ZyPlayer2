import Foundation

/// Ana ekranın "Sizin İçin Öneriler" rafını besleyen ortak aday tipi —
/// kütüphane, ZyStream, Netflix/Prime ve sinema/Apple TV kataloglarının hepsi
/// buraya indirgeniyor ki tek bir öneri listesi hepsinden seçebilsin.
enum RecommendationCandidate: Identifiable {
    case movie(MediaItem)
    case series(Series)
    case stream(StreamHit)
    case remote(RemoteTitle)

    var id: String {
        switch self {
        case .movie(let item): return "movie:\(item.id.uuidString)"
        case .series(let series): return "series:\(series.id)"
        case .stream(let hit): return "stream:\(hit.id)"
        case .remote(let title): return "remote:\(title.id)"
        }
    }

    var title: String {
        switch self {
        case .movie(let item): return item.title
        case .series(let series): return series.displayName
        case .stream(let hit): return hit.title
        case .remote(let title): return title.title
        }
    }

    var year: Int? {
        switch self {
        case .movie(let item): return item.year
        case .series(let series): return series.meta?.year
        case .stream(let hit): return hit.year
        case .remote(let title): return title.year
        }
    }

    var genres: [String] {
        switch self {
        case .movie(let item): return item.genres
        case .series(let series): return series.meta?.genres ?? []
        case .stream, .remote: return []
        }
    }

    /// LLM'e gönderilen tek satır: "Başlık (yıl) [tür1, tür2]".
    var promptLine: String {
        var line = title
        if let year { line += " (\(year))" }
        if !genres.isEmpty { line += " [\(genres.prefix(3).joined(separator: ", "))]" }
        return line
    }
}

extension WatchSnapshot {
    /// Öneri motoruna izleme geçmişi olarak beslenen başlık.
    var recommendationTitle: String {
        switch self {
        case .stream(let hit): return hit.title
        case .iptv(let favorite): return favorite.name
        case .torrent(let hit): return hit.remoteTitle?.title ?? hit.rssTitle
        case .remote(let title): return title.title
        }
    }
}

/// NVIDIA NIM üzerinden (altyazı çevirisinde de kullanılan aynı motor),
/// izleme geçmişine bakıp KAPALI bir aday listesinden öneri seçtiriyoruz.
///
/// Serbest metin istemiyoruz: model uydurma bir başlık önerirse elimizde o
/// karta karşılık gelen gerçek bir içerik olmaz, kart açılamaz/oynatılamaz.
/// Bu yüzden altyazı çevirisindeki numaralı satır protokolüne benzer şekilde,
/// modelden yalnızca verdiğimiz numaralardan seçim istiyoruz.
enum NvidiaRecommender {
    struct Pick {
        var candidate: RecommendationCandidate
        var reason: String
    }

    static let maxPicks = 20

    /// `watched`: kullanıcının bitirdiği yapımların düz metin satırları
    /// ("Başlık (yıl) [türler]"). Kütüphane, ZyStream, IPTV ve torrent gibi
    /// farklı kaynaklardan geldiği için tek bir aday tipine sıkıştırmak yerine
    /// düz metin — yalnızca zevk sinyali olarak modele gidiyor, tıklanabilir
    /// bir kart değil.
    static func recommend(watched: [String], candidates: [RecommendationCandidate],
                           apiKey: String) async throws -> [Pick] {
        guard !watched.isEmpty, !candidates.isEmpty else { return [] }
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NSError(domain: "NVIDIA NIM", code: 401, userInfo: [
                NSLocalizedDescriptionKey: "NVIDIA NIM API anahtarı boş."
            ])
        }

        let watchedLines = watched.prefix(40).map { "- \($0)" }.joined(separator: "\n")
        let candidateLines = candidates.enumerated()
            .map { "\($0.offset + 1)|\($0.element.promptLine)" }
            .joined(separator: "\n")

        let system = "ÖNEMLİ: Yanıtının tamamı Türkçe olmalı, tek kelime bile İngilizce " +
            "yazma. Sen bir film/dizi öneri uzmanısın. Kullanıcının izleme geçmişine " +
            "bakıp, sana verilen KAPALI aday listesinden zevkine en uygun olanları " +
            "seçiyorsun. Listede olmayan bir başlık asla önermezsin, uydurmazsın. " +
            "Sadece istenen biçimde, sadece Türkçe çıktı verirsin; açıklama, not ya " +
            "da başlık eklemezsin."

        let user = """
        (Hatırlatma: yanıtın tamamı Türkçe olacak, İngilizce tek kelime bile yazma.)

        Kullanıcının daha önce izleyip beğendiği yapımlar:
        \(watchedLines)

        Aşağıda numaralı bir aday listesi var. Bu listeden, kullanıcının izleme
        zevkine (tür, tarz, atmosfer) en uygun EN FAZLA \(maxPicks) tanesini seç.
        Hepsi aynı türden olmasın, biraz çeşitlilik olsun. İzlediklerinin devamı
        ya da aynı serisi varsa öncelik ver.

        ADAYLAR:
        \(candidateLines)

        ÇIKTI KURALLARI (kesinlikle uy):
        1. Her satır "numara|kısa gerekçe" biçiminde olsun.
        2. Gerekçe en fazla 6-7 kelime, sadece Türkçe, kişisel bir tonda (ör.
           "Aksiyon sevginize göre", "İzlediğiniz X'e benziyor"). Tek kelime
           bile İngilizce olmasın.
        3. Gerekçede adayın başlığını, yılını ya da türünü TEKRAR ETME — bunlar
           zaten ekranda ayrıca gösteriliyor. Yalnızca "neden" kısmını yaz.
        4. Sadece yukarıdaki numaralardan seç, yeni numara ya da başlık uydurma.
        5. Açıklama, giriş cümlesi, başlık ya da kod bloğu yazma. Yalnızca
           satırları yaz.

        Örnek doğru satır: "3|İzlediğiniz korku filmlerine çok yakın"
        Örnek YANLIŞ satır: "3|Kötü Ruh (2026) [Korku] - İzlediğinize benziyor"
        """

        let content = try await NvidiaChatClient.request(
            messages: [
                ["role": "system", "content": system],
                ["role": "user", "content": user]
            ],
            apiKey: apiKey, temperature: 0.4, maxTokens: 1200
        )
        return parse(content, candidates: candidates)
    }

    private static func parse(_ content: String, candidates: [RecommendationCandidate]) -> [Pick] {
        var picks: [Pick] = []
        var seen = Set<Int>()
        for rawLine in content.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("```") else { continue }

            var digits = ""
            var cursor = line.startIndex
            while cursor < line.endIndex, line[cursor].isNumber {
                digits.append(line[cursor])
                cursor = line.index(after: cursor)
            }
            guard let number = Int(digits), number >= 1, number <= candidates.count,
                  !seen.contains(number), cursor < line.endIndex else { continue }

            let separators: Set<Character> = ["|", ".", ")", ":", "-", "–"]
            if separators.contains(line[cursor]) {
                cursor = line.index(after: cursor)
            }
            var reason = line[cursor...].trimmingCharacters(in: .whitespaces)
            guard !reason.isEmpty else { continue }

            // Model bazen kurala uymayıp gerekçeden önce adayın kendi satırını
            // ("Başlık (yıl) [tür]") tekrar ediyor — kart zaten başlığı
            // gösterdiğinden bu tekrarı ayıklıyoruz: " - " ile ayrılmış son
            // parçayı gerçek gerekçe say.
            if let range = reason.range(of: " - ", options: .backwards) {
                reason = String(reason[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
            guard !reason.isEmpty else { continue }

            seen.insert(number)
            picks.append(Pick(candidate: candidates[number - 1], reason: reason))
            if picks.count >= maxPicks { break }
        }
        return picks
    }

}

/// Ana ekranın "Sizin İçin Öneriler" rafı için TMDB'nin kendi tohum bazlı
/// öneri uç noktasını (`/movie/{id}/recommendations`, `/tv/{id}/recommendations`)
/// kullanan motor. NVIDIA NIM tabanlı `NvidiaRecommender`'ın aksine serbest
/// metin üretmiyor, TMDB kimliği taşıyan gerçek `RemoteTitle` sonuçlar döner —
/// bu yüzden yerel katalogda (kütüphane/ZyStream/Netflix vb.) bulunmayan
/// başlıklar da önerilebiliyor.
enum TMDBRecommender {
    struct Pick {
        var title: RemoteTitle
        var imdbRating: Double?
    }

    /// Ana ekran rafının en fazla göstereceği kart sayısı.
    static let maxPicks = 20
    /// Kaç tohumdan (izlenmiş/favori/izlenecek film-dizi) öneri istenecek —
    /// hepsini sormak gecikmeyi artırır; geniş bir alt küme zaten genelin
    /// izlenimini yakalamaya yetiyor.
    private static let maxSeeds = 12
    /// Rafta bundan eski yapım gösterilmiyor — tohumlar (izlenen/favori) eski
    /// olabilir, ama önerilen sonuçlar güncel kalsın diye eleniyor.
    private static let minYear = 2015

    /// `excluded`: kullanıcının zaten kütüphanesinde/izleme listesinde olan
    /// başlıkların `RemoteTitle.id` kümesi — TMDB'nin önerdiği ama zaten
    /// sahip olunan yapımlar rafa girmesin diye eleniyor.
    static func recommend(seeds: [TMDBRecommendationSeedBuilder.Seed], excluded: Set<String>,
                           settings: AppSettings) async -> [Pick] {
        guard settings.hasTMDBToken, !seeds.isEmpty else { return [] }
        let client = TMDBClient(token: settings.tmdbToken, language: settings.metadataLanguage)

        // Her açılışta tohumların rastgele bir alt kümesi seçiliyor ki raf
        // hep aynı birkaç filmin önerdiklerine sıkışıp kalmasın.
        let chosenSeeds = Array(seeds.shuffled().prefix(maxSeeds))

        let perSeed: [(seed: TMDBRecommendationSeedBuilder.Seed, titles: [RemoteTitle])] = await withTaskGroup(
            of: (TMDBRecommendationSeedBuilder.Seed, [RemoteTitle]).self
        ) { group in
            for seed in chosenSeeds {
                group.addTask {
                    switch seed.kind {
                    case .movie:
                        let results = (try? await client.movieRecommendations(id: seed.tmdbID))?
                            .map(RemoteTitle.init(movie:)) ?? []
                        return (seed, results)
                    case .tv:
                        let results = (try? await client.tvRecommendations(id: seed.tmdbID))?
                            .map(RemoteTitle.init(show:)) ?? []
                        return (seed, results)
                    }
                }
            }
            var collected: [(TMDBRecommendationSeedBuilder.Seed, [RemoteTitle])] = []
            for await item in group { collected.append(item) }
            return collected
        }

        // Sırayla her tohumdan bir tane alarak (round-robin) topluyoruz ki
        // "en çok önerilebilir" birkaç tohum listeyi tek başına doldurmasın.
        var seen = excluded
        var picks: [Pick] = []
        var cursors = [Int](repeating: 0, count: perSeed.count)
        var progressed = true
        while picks.count < maxPicks && progressed {
            progressed = false
            for i in perSeed.indices {
                guard cursors[i] < perSeed[i].titles.count else { continue }
                let title = perSeed[i].titles[cursors[i]]
                cursors[i] += 1
                progressed = true
                guard title.posterPath != nil, (title.year ?? 0) >= minYear,
                      seen.insert(title.id).inserted else { continue }
                picks.append(Pick(title: title, imdbRating: nil))
                if picks.count >= maxPicks { break }
            }
        }
        return await attachIMDbRatings(picks, client: client)
    }

    /// TMDB'nin öneri uç noktası IMDb kimliği taşımıyor — her sonuç için ayrı
    /// bir detay isteği gerekiyor. `BollywoodStore.loadIMDbRatings` ile aynı
    /// yöntem: sekizerli gruplar hâlinde, TMDB hız sınırına takılmadan.
    private static func attachIMDbRatings(_ picks: [Pick], client: TMDBClient) async -> [Pick] {
        guard !picks.isEmpty else { return [] }
        var imdbIDs: [String: String] = [:]

        await withTaskGroup(of: (String, String?).self) { group in
            var iterator = picks.makeIterator()

            func submitNext() {
                guard let pick = iterator.next() else { return }
                group.addTask {
                    let imdbID: String?
                    switch pick.title.kind {
                    case .movie:
                        imdbID = try? await client.movieDetail(id: pick.title.tmdbID).imdbId
                    case .tv:
                        imdbID = try? await client.externalIDs(tvID: pick.title.tmdbID).imdbId
                    }
                    return (pick.title.id, imdbID)
                }
            }
            for _ in 0..<8 { submitNext() }
            while let (id, imdbID) = await group.next() {
                if let imdbID, !imdbID.isEmpty { imdbIDs[id] = imdbID }
                submitNext()
            }
        }

        let ratings = await IMDbRatingStore.ratings(for: Array(imdbIDs.values))
        return picks.map { pick in
            var pick = pick
            if let imdbID = imdbIDs[pick.title.id] { pick.imdbRating = ratings[imdbID] }
            return pick
        }
    }
}

/// Ana ekran rafına tohum (TMDB kimliği bilinen film/dizi) ve dışlama
/// (kütüphanede zaten var olan/izlenmiş) listesi sağlar.
///
/// Tohumlar tek bir sinyale değil — İzledim, Favoriler ve İzleyeceğim'in
/// tümüne — bakıyor: yalnızca "izlendi"yi kullanmak, kullanıcının tek bir
/// filmi bitirmiş olduğu durumda bütün rafın o filmin önerdiklerine
/// sıkışmasına yol açıyordu. ZyStream/IPTV/torrent geçmişi TMDB kimliğiyle
/// eşlenmediği için burada yer almıyor — yalnızca kütüphane ve TMDB'den
/// favorilenmiş/işaretlenmiş uzak başlıklar tohum olabiliyor.
enum TMDBRecommendationSeedBuilder {
    struct Seed {
        var tmdbID: Int
        var kind: RemoteKind
        var title: String
    }

    @MainActor
    static func build(library: LibraryStore) -> (seeds: [Seed], excluded: Set<String>) {
        var seeds: [Seed] = []
        var excluded = Set<String>()
        var seenSeeds = Set<String>()

        func addSeed(tmdbID: Int, kind: RemoteKind, title: String) {
            guard seenSeeds.insert("\(kind.rawValue)-\(tmdbID)").inserted else { return }
            seeds.append(Seed(tmdbID: tmdbID, kind: kind, title: title))
        }

        for item in library.movies {
            guard let tmdbID = item.tmdbID else { continue }
            excluded.insert("movie-\(tmdbID)")
            if library.isWatched(item) || item.isFavorite || library.isWatchlisted(item) {
                addSeed(tmdbID: tmdbID, kind: .movie, title: item.title)
            }
        }
        for series in library.shows {
            guard let tmdbID = series.meta?.tmdbID else { continue }
            excluded.insert("tv-\(tmdbID)")
            let isSignal = library.isSeriesFullyWatched(seriesKey: series.id)
                || (series.meta?.isFavorite ?? false)
                || library.isSeriesWatchlisted(seriesKey: series.id)
            if isSignal {
                addSeed(tmdbID: tmdbID, kind: .tv, title: series.displayName)
            }
        }
        for title in library.remoteFavorites {
            excluded.insert(title.id)
            addSeed(tmdbID: title.tmdbID, kind: title.kind, title: title.title)
        }
        for (_, snapshot) in WatchFlagsStore.shared.finishedSnapshots {
            guard case .remote(let title) = snapshot else { continue }
            excluded.insert(title.id)
            addSeed(tmdbID: title.tmdbID, kind: title.kind, title: title.title)
        }
        for (_, snapshot) in WatchFlagsStore.shared.wantToWatchSnapshots {
            guard case .remote(let title) = snapshot else { continue }
            excluded.insert(title.id)
            addSeed(tmdbID: title.tmdbID, kind: title.kind, title: title.title)
        }

        return (seeds, excluded)
    }
}

/// Ana ekran rafı (`RecommendationsRow`) ve sohbet asistanının paylaştığı
/// aday havuzu — kütüphane, ZyStream, Netflix/Prime ve sinema/Apple TV
/// kataloglarından, izlenmemiş/benzersiz başlıklar.
enum RecommendationPoolBuilder {
    @MainActor
    static func build(library: LibraryStore, stream: ZyStreamStore, providers: StreamingProviderStore,
                       cinema: CinemaStore, appleTV: AppleTVStore) -> (watched: [String], candidates: [RecommendationCandidate]) {
        var watched: [String] = []
        var watchedTitles = Set<String>()

        for item in library.movies where library.isWatched(item) {
            watched.append(RecommendationCandidate.movie(item).promptLine)
            watchedTitles.insert(item.title.lowercased())
        }
        for series in library.shows where library.isSeriesFullyWatched(seriesKey: series.id) {
            watched.append(RecommendationCandidate.series(series).promptLine)
            watchedTitles.insert(series.displayName.lowercased())
        }
        // Kütüphane dışı kaynaklar (ZyStream/IPTV/torrent/uzak katalog) "İzledim"
        // işaretlenince yalnızca burada, WatchFlagsStore'da tutuluyor — kütüphanenin
        // kendi watchStates'i UUID'lerle çalışıyor ve tarama sonrası eskiyebiliyor,
        // bu yüzden zevk sinyalini yalnızca kütüphaneye bağlamak önerileri boş
        // bırakabilir.
        for (_, snapshot) in WatchFlagsStore.shared.finishedSnapshots {
            let title = snapshot.recommendationTitle
            watched.append(title)
            watchedTitles.insert(title.lowercased())
        }

        var candidates: [RecommendationCandidate] = []
        for item in library.movies where !library.isWatched(item) {
            candidates.append(.movie(item))
        }
        for series in library.shows where !library.isSeriesFullyWatched(seriesKey: series.id) {
            candidates.append(.series(series))
        }
        for shelf in stream.shelves {
            for hit in shelf.hits { candidates.append(.stream(hit)) }
        }
        for shelf in providers.shelves {
            for title in shelf.movies { candidates.append(.remote(title)) }
            for title in shelf.shows { candidates.append(.remote(title)) }
        }
        for movie in cinema.movies { candidates.append(.remote(movie)) }
        for movie in appleTV.movies { candidates.append(.remote(movie)) }
        for show in appleTV.shows { candidates.append(.remote(show)) }

        // Zaten izlenmiş bir başlıkla aynı adı taşıyan adayı tekrar önerme,
        // aynı başlık birden çok kaynaktan geldiyse yalnızca ilkini tut.
        var seenTitles = Set<String>()
        candidates = candidates.filter { candidate in
            let key = candidate.title.lowercased()
            guard !watchedTitles.contains(key) else { return false }
            return seenTitles.insert(key).inserted
        }

        return (watched, candidates)
    }
}
