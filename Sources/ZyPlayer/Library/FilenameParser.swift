import Foundation

/// Turns a release-style filename into a title plus movie/episode metadata.
///
/// `Kuberaa.2025.1080p.WEB-DL.x265-GROUP.mkv`  → movie "Kuberaa" (2025)
/// `Severance.S02E07.Chikhai.Bardo.2160p.mkv`   → episode S2E7 of "Severance"
enum FilenameParser {

    struct Result {
        var kind: MediaKind
        var title: String
        var year: Int?
        var showTitle: String?
        var season: Int?
        var episode: Int?
    }

    /// Quality/source/codec noise that never belongs in a title.
    private static let noiseTokens: Set<String> = [
        "480p", "576p", "720p", "1080p", "1440p", "2160p", "4320p", "4k", "8k", "uhd", "hd", "sd",
        "bluray", "blu-ray", "brrip", "bdrip", "bdremux", "remux", "webrip", "web-dl", "webdl",
        "web", "hdtv", "dvdrip", "dvd", "hdrip", "camrip", "cam", "ts", "tc", "r5", "screener",
        "x264", "x265", "h264", "h265", "hevc", "avc", "xvid", "divx", "av1", "vp9",
        "aac", "aac2", "ac3", "eac3", "dd", "ddp", "dts", "dtshd", "truehd", "atmos", "flac",
        "mp3", "opus", "5", "1", "7", "2", "0", "hdr", "hdr10", "dv", "dovi", "sdr", "10bit",
        "8bit", "hlg", "imax", "extended", "unrated", "uncut", "directors", "proper", "repack",
        "internal", "limited", "festival", "retail", "complete", "multi", "dual", "dubbed",
        "subbed", "sub", "hardsub", "turkce", "türkçe", "tr", "eng", "ita", "spa", "fre", "ger",
        "amzn", "nf", "dsnp", "hmax", "atvp", "pcok", "stan", "hulu", "sample",
        // Fragments left behind once separators split compound tags apart:
        // "WEB-DL" → "web" + "dl", "DTS-HD.MA" → "dts" + "hd" + "ma".
        "dl", "ma", "hi10p", "10bits", "bit", "ita", "rus", "kor", "jpn"
    ]

    /// True for release noise, including numeric variants like `DDP5` or `AAC2`
    /// that a plain set lookup would miss.
    private static func isNoise(_ token: String) -> Bool {
        let lower = token.lowercased()
        if noiseTokens.contains(lower) { return true }

        // "ddp5" → "ddp", "aac2" → "aac"
        let stripped = lower.replacingOccurrences(
            of: #"\d+$"#, with: "", options: .regularExpression
        )
        if stripped.count >= 2 && noiseTokens.contains(stripped) { return true }

        // Resolutions, codecs, and stray channel/version numbers.
        if lower.range(of: #"^\d{3,4}p$"#, options: .regularExpression) != nil { return true }
        if lower.range(of: #"^[hx]\.?26[45]$"#, options: .regularExpression) != nil { return true }
        // 1-3 digits only: a 4-digit year is handled separately and titles like
        // "2012" must survive.
        if lower.range(of: #"^\d{1,3}$"#, options: .regularExpression) != nil { return true }

        return false
    }

    /// `S01E02`, `s1e2`, `S01.E02`, `S01 E02`
    private static let seasonEpisodeRegex = try! NSRegularExpression(
        pattern: #"[sS](\d{1,2})[\s._-]*[eE](\d{1,3})"#
    )
    /// `1x02`
    private static let crossRegex = try! NSRegularExpression(
        pattern: #"(?<![a-zA-Z0-9])(\d{1,2})[xX](\d{1,3})(?![a-zA-Z0-9])"#
    )
    /// `Season 1 Episode 2` / `Sezon 1 Bölüm 2`
    private static let wordyRegex = try! NSRegularExpression(
        pattern: #"(?:season|sezon)[\s._-]*(\d{1,2})[\s._-]*(?:episode|bölüm|bolum)[\s._-]*(\d{1,3})"#,
        options: .caseInsensitive
    )
    /// A 4-digit year in a plausible range, optionally bracketed.
    private static let yearRegex = try! NSRegularExpression(
        pattern: #"(?<!\d)(19\d{2}|20\d{2})(?!\d)"#
    )

    static func parse(url: URL) -> Result {
        // Some downloads keep percent-encoding in the actual filename on disk,
        // e.g. "American%20Born%20Chinese%20S01E01".
        let base = url.deletingPathExtension().lastPathComponent
        let raw = base.contains("%") ? (base.removingPercentEncoding ?? base) : base

        if let episode = parseEpisode(from: raw, url: url) {
            return episode
        }
        return parseMovie(from: raw)
    }

    // MARK: - Episodes

    private static func parseEpisode(from raw: String, url: URL) -> Result? {
        let range = NSRange(raw.startIndex..., in: raw)

        var match: NSTextCheckingResult?
        for regex in [seasonEpisodeRegex, wordyRegex, crossRegex] {
            if let found = regex.firstMatch(in: raw, range: range) {
                match = found
                break
            }
        }
        guard let match,
              let seasonRange = Range(match.range(at: 1), in: raw),
              let episodeRange = Range(match.range(at: 2), in: raw),
              let season = Int(raw[seasonRange]),
              let episode = Int(raw[episodeRange]) else {
            return nil
        }

        // Everything before the marker is the show name; everything after it is
        // usually the episode title followed by release noise.
        let beforeMarker = String(raw[raw.startIndex..<(Range(match.range, in: raw)?.lowerBound ?? raw.endIndex)])
        let afterMarker = String(raw[(Range(match.range, in: raw)?.upperBound ?? raw.endIndex)...])

        var showTitle = clean(beforeMarker)
        // Some releases put the show name only on the parent folder.
        if showTitle.isEmpty {
            showTitle = clean(url.deletingLastPathComponent().lastPathComponent)
        }
        // A trailing year disambiguates the release, it is not part of the name:
        // "Invasion 2021" and "Invasion" are one show and must group together.
        showTitle = showTitle.replacingOccurrences(
            of: #"\s+(19\d{2}|20\d{2})$"#,
            with: "",
            options: .regularExpression
        )

        let episodeTitle = clean(afterMarker)
        let displayTitle = episodeTitle.isEmpty ? showTitle : episodeTitle

        return Result(
            kind: .episode,
            title: displayTitle,
            year: nil,
            showTitle: showTitle.isEmpty ? nil : showTitle,
            season: season,
            episode: episode
        )
    }

    // MARK: - Movies

    private static func parseMovie(from raw: String) -> Result {
        let range = NSRange(raw.startIndex..., in: raw)
        var year: Int?
        var titlePart = raw

        // Use the last year in the string: "2012 (2009)" style names would
        // otherwise pick the title's own number.
        let yearMatches = yearRegex.matches(in: raw, range: range)
        if let last = yearMatches.last, let r = Range(last.range, in: raw) {
            year = Int(raw[r])
            titlePart = String(raw[raw.startIndex..<r.lowerBound])
        }

        // A title can collide with a codec name — the 2025 film "Opus" is also an
        // audio codec — so retry without noise filtering before giving up.
        var title = clean(titlePart)
        if title.isEmpty { title = clean(titlePart, lenient: true) }
        if title.isEmpty { title = clean(raw) }
        if title.isEmpty { title = raw }

        return Result(kind: .movie, title: title, year: year,
                      showTitle: nil, season: nil, episode: nil)
    }

    // MARK: - Cleanup

    /// Splits on separators, drops release noise, and restores spacing/case.
    /// `lenient` keeps every token, for names that are entirely noise-like.
    private static func clean(_ input: String, lenient: Bool = false) -> String {
        // Strip bracketed groups: [YTS], (1080p), {GROUP}
        var working = input.replacingOccurrences(
            of: #"[\[\(\{][^\]\)\}]*[\]\)\}]"#,
            with: " ",
            options: .regularExpression
        )
        // A trailing "-GROUP" is a release tag, not part of the title.
        working = working.replacingOccurrences(
            of: #"-[A-Za-z0-9]{2,}$"#,
            with: " ",
            options: .regularExpression
        )
        // Drop brackets left unpaired after the year was cut out of the middle,
        // e.g. "Kuberaa (2025)" → "Kuberaa (".
        working = working.replacingOccurrences(
            of: #"[\[\]\(\)\{\}]"#,
            with: " ",
            options: .regularExpression
        )

        let separators = CharacterSet(charactersIn: ".-_ +")
        let rawTokens = working.components(separatedBy: separators).filter { !$0.isEmpty }

        // Everything from the first noise token onward is release metadata, so
        // stop there. Skipping noise and continuing lets fragments like "DL" and
        // "DDP5" accumulate into titles such as "Dl Ddp5".
        var kept: [String] = []
        for token in rawTokens {
            if !lenient && isNoise(token) { break }
            kept.append(token)
        }

        let joined = kept.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return normalizeCase(joined)
    }

    /// `THE.MATRIX` → `The Matrix`, while leaving mixed-case titles alone.
    private static func normalizeCase(_ input: String) -> String {
        guard !input.isEmpty else { return input }
        let isAllCaps = input == input.uppercased() && input.rangeOfCharacter(from: .lowercaseLetters) == nil
        let isAllLower = input == input.lowercased()
        guard isAllCaps || isAllLower else { return input }

        // Short all-caps single words are acronyms or stylised titles — "FER",
        // "DMZ" must not become "Fer", "Dmz".
        if isAllCaps && input.count <= 4 && !input.contains(" ") { return input }

        return input
            .split(separator: " ")
            .map { word -> String in
                guard let first = word.first else { return String(word) }
                return String(first).uppercased() + word.dropFirst().lowercased()
            }
            .joined(separator: " ")
    }
}
