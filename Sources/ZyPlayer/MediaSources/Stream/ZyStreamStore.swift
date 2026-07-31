import Foundation
import Observation

/// Drives the ZyStream page and the streaming-source playback flow.
///
/// Search fans out across every enabled provider in parallel; resolving a chosen
/// title runs the provider's `embeds` and then `StreamResolver`. The store never
/// touches the player directly — it hands a resolved stream back through
/// `onPlay`, which `RootView` wires to `PlayerModel.open`.
@MainActor
@Observable
final class ZyStreamStore {

    var query = ""
    private(set) var hits: [StreamHit] = []
    private(set) var isSearching = false
    private(set) var message: String?

    /// Set while a title is being turned into a playable URL, so the UI can show
    /// a spinner and block a second tap.
    private(set) var resolvingID: String?

    /// A series whose episode list is open, if any.
    private(set) var activeDetails: StreamDetails?
    private(set) var isLoadingDetails = false

    /// Oynatılan bölümün ait olduğu dizi. Player'daki bölüm seçici bunu okuyor:
    /// `activeDetails` oynatma başlarken kapanıyor, bu ise izleme boyunca duruyor.
    private(set) var playingDetails: StreamDetails?

    /// The landing-page rows (recent films/series), refreshed on each visit.
    private(set) var shelves: [StreamShelf] = []
    private(set) var isLoadingShelves = false

    /// Injected by `RootView`: `(stream, launch) in player.open(...)`.
    var onPlay: ((ResolvedStream, StreamLaunch) -> Void)?
    /// Resolves a provider id to a configured provider (with its current base URL).
    /// Set by `RootView` from settings so a domain change takes effect at once.
    var lookup: (String) -> StreamProvider? = { _ in nil }
    /// Continue-watching store, set by `RootView`.
    var resume: PlaybackResumeStore?

    /// Base URL of a provider, for loading its Cloudflare-gated posters.
    func baseURL(forProviderID id: String) -> String? { lookup(id)?.baseURL }

    @ObservationIgnored private let resolver = StreamResolver()
    /// Bumped on each search so a slow provider from an old query can't append
    /// its results over a newer one.
    @ObservationIgnored private var searchToken = 0

    // MARK: - Search

    func search(_ raw: String, providers: [StreamProvider], settings: AppSettings) async {
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        self.query = query
        guard query.count >= 2 else {
            hits = []; message = nil; isSearching = false
            return
        }
        guard !providers.isEmpty else {
            hits = []; message = "Açık akış kaynağı yok. Ayarlar’dan bir kaynak açın."
            return
        }

        searchToken += 1
        let token = searchToken
        isSearching = true
        message = nil
        hits = []

        // Each provider streams its results in as it returns, so the fastest site
        // fills the grid without waiting on the slowest.
        //
        // Hata ile "gerçekten sonuç yok" ayrı tutuluyor: site 503 döndüğünde
        // kullanıcıya "sonuç bulunamadı" demek yanıltıcı — içerik duruyor,
        // ulaşılamayan siteydi.
        var failures = 0
        await withTaskGroup(of: Result<[StreamHit], Error>.self) { group in
            for provider in providers {
                group.addTask {
                    do { return .success(try await provider.search(query)) }
                    catch { return .failure(error) }
                }
            }
            for await result in group {
                guard token == self.searchToken else { return }
                switch result {
                case .success(let found):
                    if !found.isEmpty { self.hits.append(contentsOf: found) }
                case .failure:
                    failures += 1
                }
            }
        }

        // Thin direct results: widen with the title TMDB thinks the user meant,
        // so a typo or a Turkish/original-name mismatch still finds the content.
        guard token == searchToken else { return }
        if hits.count < 8, settings.hasTMDBToken {
            await expandViaTMDB(query, providers: providers, settings: settings, token: token)
        }

        guard token == searchToken else { return }
        isSearching = false
        if hits.isEmpty {
            message = failures == providers.count
                ? "Kaynağa şu an ulaşılamıyor. Birazdan tekrar deneyin."
                : "‘\(query)’ için sonuç bulunamadı."
        }
    }

    private func expandViaTMDB(_ query: String, providers: [StreamProvider],
                               settings: AppSettings, token: Int) async {
        let client = TMDBClient(token: settings.tmdbToken, language: settings.metadataLanguage)
        guard let results = try? await client.searchMulti(query: query) else { return }
        let titles = results
            .compactMap { $0.title ?? $0.name }
            .filter { $0.localizedCaseInsensitiveCompare(query) != .orderedSame }
        var tried = Set<String>()
        for title in titles.prefix(3) {
            guard token == searchToken else { return }
            guard tried.insert(title.lowercased()).inserted else { continue }
            for provider in providers {
                guard let more = try? await provider.search(title) else { continue }
                guard token == searchToken else { return }
                let existing = Set(hits.map(\.id))
                hits.append(contentsOf: more.filter { !existing.contains($0.id) })
            }
        }
    }

    // MARK: - Discover (landing page)

    /// Loads the landing-page shelves fresh. Called on each visit so "Son Eklenen"
    /// stays current.
    func loadDiscover(providers: [StreamProvider]) async {
        guard !providers.isEmpty else { shelves = []; return }
        isLoadingShelves = true
        defer { isLoadingShelves = false }
        var collected: [StreamShelf] = []
        for provider in providers {
            if let rows = try? await provider.discover() {
                collected.append(contentsOf: rows)
            }
        }
        shelves = collected
    }

    // MARK: - Activate / play

    /// A card was tapped. A page with a player embed plays straight away; one
    /// without (a series landing page) opens its episode list. This is decided by
    /// what the page actually contains rather than by the hit's declared kind, so
    /// a series on a film-first site still opens correctly.
    func activate(_ hit: StreamHit) {
        Task { await openHit(hit) }
    }

    private func openHit(_ hit: StreamHit) async {
        guard let provider = lookup(hit.providerID) else { return }
        resolvingID = hit.id
        message = nil
        do {
            let embeds = try await provider.embeds(forPage: hit.pageURL)
            if let embed = embeds.first {
                // Sayfada oynatıcı varsa bu bir film; önceki dizinin bölüm
                // listesi player'a taşınmasın.
                playingDetails = nil
                await resolveAndPlay(embed: embed, pageURL: hit.pageURL, providerID: hit.providerID,
                                     title: hit.title, resolvingID: hit.id, posterURL: hit.posterURL)
                return
            }
        } catch StreamError.noEmbed {
            // No player on the page — it is a series landing page. Fall through to
            // its episode list.
        } catch {
            resolvingID = nil
            message = (error as? LocalizedError)?.errorDescription ?? "Oynatılamadı."
            return
        }
        resolvingID = nil
        await loadDetails(hit)
    }

    func loadDetails(_ hit: StreamHit) async {
        guard let provider = lookup(hit.providerID) else { return }
        isLoadingDetails = true
        activeDetails = nil
        defer { isLoadingDetails = false }
        do {
            let details = try await provider.details(hit)
            // A "series" that turned out to have no episode list is really a movie.
            if details.episodes.isEmpty, let page = details.moviePageURL {
                await playPage(page, providerID: hit.providerID, title: details.hit.title,
                               resolvingID: hit.id, posterURL: hit.posterURL)
            } else {
                activeDetails = details
            }
        } catch {
            message = error.localizedDescription
        }
    }

    func closeDetails() { activeDetails = nil }

    func playEpisode(_ episode: StreamEpisode, from details: StreamDetails) {
        let title = "\(details.hit.title) · S\(episode.season)B\(episode.episode)"
        Task {
            await playPage(episode.pageURL, providerID: details.hit.providerID,
                           title: title, resolvingID: episode.id,
                           posterURL: details.hit.posterURL, series: details)
        }
    }

    /// Re-launches a continue-watching entry: re-resolves its page and resumes.
    func resumeStream(_ point: ResumePoint) {
        guard let page = point.pageURL, let providerID = point.providerID else { return }
        Task {
            await playPage(page, providerID: providerID, title: point.title,
                           resolvingID: point.id, posterURL: point.posterURL)
        }
    }

    /// Resolves a movie/episode page to a media URL and hands it to `onPlay`.
    ///
    /// `series` bir bölüm oynatılırken o bölümün dizisini taşıyor; player'daki
    /// bölüm seçici bunu okuyor. Film oynatılırken nil kalıyor ve seçici çıkmıyor.
    func playPage(_ pageURL: String, providerID: String, title: String,
                  resolvingID: String, posterURL: URL?,
                  series: StreamDetails? = nil) async {
        guard let provider = lookup(providerID) else { return }
        playingDetails = series
        self.resolvingID = resolvingID
        message = nil
        do {
            let embeds = try await provider.embeds(forPage: pageURL)
            guard let embed = embeds.first else { throw StreamError.noEmbed }
            await resolveAndPlay(embed: embed, pageURL: pageURL, providerID: providerID,
                                 title: title, resolvingID: resolvingID, posterURL: posterURL)
        } catch {
            self.resolvingID = nil
            message = (error as? LocalizedError)?.errorDescription ?? "Oynatılamadı."
        }
    }

    /// Shared tail: resolve the embed, register a resume point, and play with the
    /// saved position. The resume key is the stable page URL, not the ephemeral
    /// media URL that actually streams.
    private func resolveAndPlay(embed: StreamEmbed, pageURL: String, providerID: String,
                                title: String, resolvingID: String, posterURL: URL?) async {
        do {
            let resolved = try await resolver.resolve(embed)
            resume?.begin(ResumePoint(
                id: pageURL, kind: .stream, title: title,
                posterURLString: posterURL?.absoluteString,
                providerID: providerID, pageURL: pageURL
            ))
            let resumeAt = resume?.position(forKey: pageURL) ?? 0
            let subtitle = resume?.point(forKey: pageURL)?.subtitleLabel
            onPlay?(resolved, StreamLaunch(title: title, resumeAt: resumeAt,
                                           resumeKey: pageURL, subtitleLabel: subtitle))
            activeDetails = nil
            self.resolvingID = nil
        } catch {
            self.resolvingID = nil
            message = (error as? LocalizedError)?.errorDescription ?? "Oynatılamadı."
        }
    }
}

/// What `RootView` needs to open a resolved stream in the player.
struct StreamLaunch {
    var title: String
    var resumeAt: Double
    var resumeKey: String
    var subtitleLabel: String?
}
