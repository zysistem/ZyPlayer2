import Foundation
import Observation

/// A person on a detail screen or in search results.
struct PersonRef: Identifiable, Hashable {
    var id: Int
    var name: String
    var profilePath: String?
    /// The character played, or the job done — whatever the row is about.
    var role: String?
    /// `Directing`, `Acting`, … as TMDB files them.
    var department: String?

    var profileURL: URL? {
        profilePath.map { TMDBClient.imageURL(path: $0, size: "w185") }
    }

    var largeProfileURL: URL? {
        profilePath.map { TMDBClient.imageURL(path: $0, size: "h632") }
    }

    /// Initials, for the placeholder when TMDB has no photo.
    var initials: String {
        name.split(separator: " ").prefix(2).compactMap { $0.first }.map(String.init).joined()
    }

    init(id: Int, name: String, profilePath: String? = nil,
         role: String? = nil, department: String? = nil) {
        self.id = id
        self.name = name
        self.profilePath = profilePath
        self.role = role
        self.department = department
    }

    init?(multi: MultiResult) {
        guard multi.mediaType == "person", let name = multi.name else { return nil }
        self.init(id: multi.id, name: name, profilePath: multi.profilePath,
                  role: multi.knownForDepartment, department: multi.knownForDepartment)
    }
}

/// Who made a title. Loaded per detail screen rather than stored: the library
/// models keep names only, and adding people to them would mean migrating every
/// saved file for something one request answers.
@Observable
final class CreditsLoader {
    private(set) var directors: [PersonRef] = []
    private(set) var cast: [PersonRef] = []
    @ObservationIgnored private var loadedKey: String?

    /// Directors first, then the top of the billing — that is the order a detail
    /// screen reads in.
    var people: [PersonRef] { directors + cast }

    @MainActor
    func load(kind: RemoteKind, tmdbID: Int, settings: AppSettings) async {
        let key = "\(kind.rawValue)-\(tmdbID)"
        guard settings.hasTMDBToken, loadedKey != key else { return }
        loadedKey = key

        let client = TMDBClient(token: settings.tmdbToken, language: settings.metadataLanguage)
        let credits: Credits?
        switch kind {
        case .movie: credits = try? await client.movieDetail(id: tmdbID).credits
        case .tv:    credits = try? await client.tvDetail(id: tmdbID).credits
        }
        guard let credits else { return }

        // A show's "director" is whoever created it; films name a Director.
        let wanted = kind == .movie ? ["Director"] : ["Director", "Creator", "Executive Producer"]
        var seen = Set<Int>()
        directors = (credits.crew ?? [])
            .filter { wanted.contains($0.job ?? "") }
            .compactMap { member in
                guard seen.insert(member.id).inserted else { return nil }
                return PersonRef(id: member.id, name: member.name,
                                 profilePath: member.profilePath,
                                 role: Self.jobName(member.job),
                                 department: member.department)
            }
            .prefix(3)
            .map { $0 }

        cast = (credits.cast ?? [])
            .prefix(20)
            .compactMap { member in
                guard seen.insert(member.id).inserted else { return nil }
                return PersonRef(id: member.id, name: member.name,
                                 profilePath: member.profilePath,
                                 role: member.character,
                                 department: "Acting")
            }
    }

    private static func jobName(_ job: String?) -> String {
        switch job {
        case "Director": "Yönetmen"
        case "Creator": "Yaratıcı"
        case "Executive Producer": "Yönetici Yapımcı"
        default: job ?? ""
        }
    }
}

/// One person's page: their photo and biography, plus everything they were in.
@Observable
final class PersonFilmographyLoader {
    private(set) var detail: PersonDetail?
    private(set) var titles: [RemoteTitle] = []
    private(set) var roles: [String: String] = [:]
    private(set) var isLoading = false
    @ObservationIgnored private var loadedID: Int?

    @MainActor
    func load(_ person: PersonRef, settings: AppSettings) async {
        guard settings.hasTMDBToken, loadedID != person.id else { return }
        loadedID = person.id
        isLoading = true
        defer { isLoading = false }

        let client = TMDBClient(token: settings.tmdbToken, language: settings.metadataLanguage)
        detail = try? await client.person(id: person.id)
        guard let credits = try? await client.personCredits(id: person.id) else { return }

        // Crew credits repeat one row per job — Nolan's own films come back as
        // Director, Writer and Producer — so titles are collapsed by identity
        // and the roles merged into one line.
        var collected: [String: RemoteTitle] = [:]
        var order: [String] = []
        var rolesByTitle: [String: [String]] = [:]

        for credit in (credits.cast ?? []) + (credits.crew ?? []) {
            guard let kind = credit.kind else { continue }
            let name = kind == .movie ? credit.title : credit.name
            guard let name, !name.isEmpty else { continue }
            // Talk-show and awards-night appearances come back as "Self" and
            // bury the actual work — an actor collects hundreds of them. A film
            // credited as "Self" is usually a documentary, so those stay.
            if kind == .tv, credit.character?.lowercased().hasPrefix("self") == true { continue }

            let title = RemoteTitle(
                kind: kind, tmdbID: credit.id, title: name,
                overview: credit.overview, year: credit.year,
                rating: credit.voteAverage,
                posterPath: credit.posterPath, backdropPath: credit.backdropPath
            )
            if collected[title.id] == nil {
                collected[title.id] = title
                order.append(title.id)
            }
            let role = credit.character ?? credit.job
            if let role, !role.isEmpty,
               !(rolesByTitle[title.id] ?? []).contains(role) {
                rolesByTitle[title.id, default: []].append(role)
            }
        }

        // Newest first: a filmography is read from what they just did backwards.
        titles = order.compactMap { collected[$0] }
            .sorted { ($0.year ?? 0) > ($1.year ?? 0) }
        roles = rolesByTitle.mapValues { $0.prefix(2).joined(separator: ", ") }
    }
}
