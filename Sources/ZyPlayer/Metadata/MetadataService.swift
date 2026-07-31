import Foundation

/// Matches library items against TMDB and caches the artwork they need.
///
/// Shows are matched once per series, then each episode gets its own title,
/// overview and still — matching every episode separately would burn requests
/// and produce inconsistent show names.
struct MetadataService {

    let client: TMDBClient

    struct MovieMatch {
        var tmdbID: Int
        var imdbID: String?
        var title: String
        var year: Int?
        var overview: String?
        var runtimeMinutes: Int?
        var rating: Double?
        var genres: [String]
        var posterFileName: String?
        var backdropFileName: String?
    }

    struct EpisodeMatch {
        var title: String?
        var overview: String?
        var stillFileName: String?
        var runtimeMinutes: Int?
    }

    // MARK: - Movies

    func matchMovie(title: String, year: Int?) async -> MovieMatch? {
        guard let candidates = try? await client.searchMovie(title: title, year: year),
              let best = bestMovie(from: candidates, title: title, year: year) else {
            // Retry without the year: filename years are often the release year
            // of the rip, not of the film.
            if year != nil,
               let fallback = try? await client.searchMovie(title: title, year: nil),
               let best = bestMovie(from: fallback, title: title, year: nil) {
                return await buildMovieMatch(id: best.id)
            }
            return nil
        }
        return await buildMovieMatch(id: best.id)
    }

    private func buildMovieMatch(id: Int) async -> MovieMatch? {
        guard let detail = try? await client.movieDetail(id: id) else { return nil }

        let poster = await ArtworkCache.fetch(
            path: detail.posterPath, size: "w500", key: "movie_\(detail.id)_poster"
        )
        let backdrop = await ArtworkCache.fetch(
            path: detail.backdropPath, size: "w1280", key: "movie_\(detail.id)_backdrop"
        )

        return MovieMatch(
            tmdbID: detail.id,
            imdbID: detail.imdbId,
            title: detail.title,
            year: detail.year,
            overview: detail.overview,
            runtimeMinutes: detail.runtime,
            rating: detail.voteAverage,
            genres: detail.genres?.map(\.name) ?? [],
            posterFileName: poster,
            backdropFileName: backdrop
        )
    }

    /// Prefers an exact title match, then a matching year, then TMDB's own order.
    private func bestMovie(from results: [MovieResult], title: String, year: Int?) -> MovieResult? {
        guard !results.isEmpty else { return nil }
        let normalized = normalize(title)

        if let exact = results.first(where: {
            normalize($0.title) == normalized || normalize($0.originalTitle ?? "") == normalized
        }) {
            return exact
        }
        if let year, let sameYear = results.first(where: { $0.year == year }) {
            return sameYear
        }
        return results.first
    }

    // MARK: - Series

    func matchSeries(name: String) async -> SeriesMeta? {
        guard let candidates = try? await client.searchTV(name: name),
              let best = bestShow(from: candidates, name: name),
              let detail = try? await client.tvDetail(id: best.id) else {
            return nil
        }

        let poster = await ArtworkCache.fetch(
            path: detail.posterPath, size: "w500", key: "tv_\(detail.id)_poster"
        )
        let backdrop = await ArtworkCache.fetch(
            path: detail.backdropPath, size: "w1280", key: "tv_\(detail.id)_backdrop"
        )
        // TV details omit the IMDb id; it lives behind `external_ids`.
        let imdbID = try? await client.externalIDs(tvID: detail.id).imdbId

        return SeriesMeta(
            tmdbID: detail.id,
            imdbID: imdbID,
            name: detail.name,
            overview: detail.overview,
            year: detail.year,
            posterFileName: poster,
            backdropFileName: backdrop,
            rating: detail.voteAverage,
            genres: detail.genres?.map(\.name) ?? [],
            cast: detail.credits?.cast?.prefix(10).map(\.name) ?? []
        )
    }

    private func bestShow(from results: [TVResult], name: String) -> TVResult? {
        guard !results.isEmpty else { return nil }
        let normalized = normalize(name)
        if let exact = results.first(where: {
            normalize($0.name) == normalized || normalize($0.originalName ?? "") == normalized
        }) {
            return exact
        }
        return results.first
    }

    func matchEpisode(showID: Int, season: Int, episode: Int) async -> EpisodeMatch? {
        guard let detail = try? await client.episodeDetail(
            showID: showID, season: season, episode: episode
        ) else { return nil }

        let still = await ArtworkCache.fetch(
            path: detail.stillPath, size: "w500",
            key: "ep_\(showID)_\(season)_\(episode)_still"
        )

        return EpisodeMatch(
            title: detail.name,
            overview: detail.overview,
            stillFileName: still,
            runtimeMinutes: detail.runtime
        )
    }

    // MARK: - Helpers

    /// Case/punctuation-insensitive comparison so "The Last Of Us" matches
    /// "The Last of Us" and "Percy Jackson and The Olympians" matches TMDB's name.
    private func normalize(_ value: String) -> String {
        value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
