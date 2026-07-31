import Foundation

/// Talks the Stremio subtitle-addon protocol, which needs no API key.
///
/// The client never touches a subtitle site: it asks an addon server
/// `GET <base>/subtitles/<type>/<id>[/videoHash=…&videoSize=…].json` and gets
/// back `{"subtitles":[{"id","url","lang"}]}` whose `url` is a plain subtitle
/// file. That is the whole reason this works without credentials — the addon
/// does the scraping server-side.
struct StremioSubtitleClient {

    enum ClientError: LocalizedError {
        case noSources
        case notASubtitleAddon
        case unreachable(String)
        case http(Int)

        var errorDescription: String? {
            switch self {
            case .noSources:
                "Etkin altyazı kaynağı yok. Ayarlar → Altyazı Kaynakları'ndan ekleyin."
            case .notASubtitleAddon:
                "Bu adres bir altyazı eklentisi değil."
            case .unreachable(let host):
                "\(host) yanıt vermedi."
            case .http(let code):
                "Altyazı kaynağı hata döndü (HTTP \(code))."
            }
        }
    }

    /// One subtitle offered by an addon.
    ///
    /// The protocol has no release-name field, but addons leak it anyway — in a
    /// `title`/`filename` extra, in the download URL's file name, or appended to
    /// `lang`. Whatever turns up goes in `releaseName`; when nothing does, the
    /// row falls back to the per-language number.
    struct Result: Identifiable, Hashable {
        var id: String
        var language: String        // three-letter, as the addon reports it
        var url: URL
        var addonName: String
        /// 1-based rank within its language, so rows read "Türkçe · #2".
        var index: Int
        /// Release/file name, empty when the addon gave no hint of one.
        var releaseName: String = ""

        var languageName: String { SubtitleLanguage.displayName(alpha3: language) }

        /// What the row shows as its headline.
        var displayName: String {
            releaseName.isEmpty ? "\(languageName) · #\(index)" : releaseName
        }
    }

    /// Enabled sources, in the order they should be tried.
    var addons: [SubtitleAddon]
    /// Comma-separated two-letter codes, e.g. "tr,en". Empty means every language.
    var languages: String

    private static let timeout: TimeInterval = 8

    // MARK: - Manifest

    struct Manifest: Decodable {
        var id: String?
        var name: String?
        var resources: [ResourceEntry]?
        var types: [String]?

        /// `resources` is either `["subtitles"]` or a list of objects.
        enum ResourceEntry: Decodable {
            case name(String)
            case object(String)

            var value: String {
                switch self {
                case .name(let v), .object(let v): v
                }
            }

            init(from decoder: Decoder) throws {
                if let plain = try? decoder.singleValueContainer().decode(String.self) {
                    self = .name(plain)
                    return
                }
                struct Object: Decodable { var name: String }
                let object = try decoder.singleValueContainer().decode(Object.self)
                self = .object(object.name)
            }
        }

        var servesSubtitles: Bool {
            resources?.contains { $0.value == "subtitles" } ?? false
        }
    }

    /// Validates a pasted address and returns the addon it describes.
    static func probe(baseURL raw: String) async throws -> SubtitleAddon {
        let base = SubtitleAddon.normalize(raw)
        guard let url = URL(string: base + "/manifest.json") else {
            throw ClientError.notASubtitleAddon
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ClientError.unreachable(URL(string: base)?.host ?? base)
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ClientError.http(http.statusCode)
        }
        guard let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
              manifest.servesSubtitles else {
            throw ClientError.notASubtitleAddon
        }
        return SubtitleAddon(
            name: manifest.name ?? URL(string: base)?.host ?? "Altyazı kaynağı",
            baseURL: base
        )
    }

    // MARK: - Search

    /// Queries every enabled addon in order and merges what comes back.
    ///
    /// A failing addon is skipped rather than surfaced: with several sources
    /// configured, one being down must not turn into an error the user sees.
    func search(imdbID: String,
                season: Int? = nil,
                episode: Int? = nil,
                videoURL: URL? = nil) async throws -> [Result] {
        let enabled = addons.filter(\.isEnabled)
        guard !enabled.isEmpty else { throw ClientError.noSources }

        let wanted = SubtitleLanguage.codes(for: languages)
        let hash = videoURL.flatMap(OpenSubtitlesHash.compute)

        var merged: [Result] = []
        var seenURLs = Set<URL>()
        var perLanguageCount: [String: Int] = [:]

        for addon in enabled {
            guard let url = endpoint(for: addon, imdbID: imdbID,
                                     season: season, episode: episode, hash: hash) else { continue }
            guard let entries = try? await fetch(url) else { continue }

            for entry in entries {
                guard let link = entry.url, let linkURL = URL(string: link) else { continue }
                let (lang, langExtra) = Self.splitLanguage(entry.lang)
                if !wanted.isEmpty && !wanted.contains(lang) { continue }
                guard seenURLs.insert(linkURL).inserted else { continue }

                let rank = (perLanguageCount[lang] ?? 0) + 1
                perLanguageCount[lang] = rank
                merged.append(Result(
                    id: "\(addon.id)-\(entry.id ?? link)",
                    language: lang,
                    url: linkURL,
                    addonName: addon.name,
                    index: rank,
                    releaseName: Self.releaseName(entry.release, langExtra, linkURL)
                ))
            }
        }

        // Preferred languages first, in the order the user listed them.
        let priority = SubtitleLanguage.codes(for: languages)
        return merged.sorted { lhs, rhs in
            let l = priority.firstIndex(of: lhs.language) ?? Int.max
            let r = priority.firstIndex(of: rhs.language) ?? Int.max
            if l != r { return l < r }
            return lhs.index < rhs.index
        }
    }

    /// Splits `lang` into a three-letter code and whatever else was crammed in.
    ///
    /// Because the protocol has no release-name field, several addons write
    /// `"Turkish - The.Movie.1080p.WEB-DL"` into `lang` so Stremio's own UI —
    /// which only ever prints the language — still shows the version. Anything
    /// past the first separator is that, not a language.
    private static func splitLanguage(_ raw: String?) -> (code: String, extra: String) {
        let value = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return ("und", "") }
        if let code = SubtitleLanguage.alpha3(forAnyForm: value) { return (code, "") }

        for separator in [" - ", " – ", " | ", "|", " / ", ": ", " "] {
            guard let range = value.range(of: separator) else { continue }
            let head = String(value[..<range.lowerBound])
            guard let code = SubtitleLanguage.alpha3(forAnyForm: head) else { continue }
            return (code, String(value[range.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return (value.lowercased(), "")
    }

    /// The best release name available, or "" when there is genuinely none.
    ///
    /// The URL is the last resort: plenty of addons serve the scraped file under
    /// its own name, while others end in an opaque id — which is filtered out by
    /// requiring letters and a separator, the shape every release name has.
    private static func releaseName(_ field: String?, _ langExtra: String, _ url: URL) -> String {
        for candidate in [field ?? "", langExtra] where !candidate.isEmpty {
            return clean(candidate)
        }
        let file = url.deletingPathExtension().lastPathComponent
            .removingPercentEncoding ?? url.deletingPathExtension().lastPathComponent
        let extensions: Set<String> = ["srt", "ass", "ssa", "sub", "vtt", "zip", "gz"]
        guard extensions.contains(url.pathExtension.lowercased()),
              file.count > 6,
              file.contains(where: \.isLetter),
              file.contains(where: { $0 == "." || $0 == "-" || $0 == "_" || $0 == " " }) else {
            return ""
        }
        return clean(file)
    }

    private static func clean(_ name: String) -> String {
        var value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        for suffix in [".srt", ".ass", ".ssa", ".sub", ".vtt"] where value.lowercased().hasSuffix(suffix) {
            value = String(value.dropLast(suffix.count))
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `<base>/subtitles/<type>/<id>[/videoHash=…&videoSize=…].json`
    private func endpoint(for addon: SubtitleAddon,
                          imdbID: String,
                          season: Int?,
                          episode: Int?,
                          hash: (hash: String, size: Int64)?) -> URL? {
        let type = (season != nil && episode != nil) ? "series" : "movie"
        var id = imdbID
        if let season, let episode { id += ":\(season):\(episode)" }

        var path = "\(addon.baseURL)/subtitles/\(type)/\(id)"
        if let hash {
            path += "/videoHash=\(hash.hash)&videoSize=\(hash.size)"
        }
        path += ".json"
        // The id and extras contain `:` and `&`, which are legal in a path but
        // must survive URL construction intact.
        return URL(string: path.addingPercentEncoding(
            withAllowedCharacters: .urlFragmentAllowed
        ) ?? path)
    }

    private struct Payload: Decodable {
        struct Entry: Decodable {
            var id: String?
            var url: String?
            var lang: String?
            /// The release name, under whichever key this addon chose for it.
            var release: String?

            /// Some addons number ids, others use strings.
            enum CodingKeys: String, CodingKey {
                case id, url, lang
                case title, name, filename, fileName, release
                case subFileName = "SubFileName"
                case movieReleaseName = "MovieReleaseName"
            }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                if let text = try? c.decode(String.self, forKey: .id) {
                    id = text
                } else if let number = try? c.decode(Int.self, forKey: .id) {
                    id = String(number)
                }
                url = try? c.decode(String.self, forKey: .url)
                lang = try? c.decode(String.self, forKey: .lang)

                // No agreed key: take the first one that is present and looks
                // like more than a language label.
                let candidates: [CodingKeys] = [
                    .release, .movieReleaseName, .subFileName,
                    .filename, .fileName, .title, .name
                ]
                release = candidates
                    .lazy
                    .compactMap { try? c.decode(String.self, forKey: $0) }
                    .first { $0.trimmingCharacters(in: .whitespaces).count > 3 }
            }
        }
        var subtitles: [Entry]?
    }

    private func fetch(_ url: URL) async throws -> [Payload.Entry] {
        var request = URLRequest(url: url)
        request.timeoutInterval = Self.timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ClientError.http(http.statusCode)
        }
        return try JSONDecoder().decode(Payload.self, from: data).subtitles ?? []
    }

    // MARK: - Download

    /// Fetches the file and writes it as UTF-8 next to the other subtitles.
    func download(_ result: Result) async throws -> URL {
        var request = URLRequest(url: result.url)
        request.timeoutInterval = 25
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ClientError.http(http.statusCode)
        }

        let payload = try Self.unpack(data)
        let name = "\(result.language)-\(abs(result.url.absoluteString.hashValue)).srt"
        let destination = AppPaths.subtitleDirectory.appendingPathComponent(name)
        try payload.write(to: destination, options: .atomic)
        return destination
    }

    /// Stremio's own addon serves plain UTF-8 SRT, but third-party ones may zip
    /// or gzip the file and use a legacy codepage, so normalise both here.
    private static func unpack(_ data: Data) throws -> Data {
        let magic = [UInt8](data.prefix(2))

        if magic == [0x50, 0x4B] {          // "PK" — zip
            return try unzip(data)
        }
        if magic == [0x1F, 0x8B] {          // gzip
            return try gunzip(data)
        }
        return reencode(data)
    }

    /// Re-encodes to UTF-8. Turkish subtitles are still commonly CP1254, which
    /// renders as mojibake if handed to mpv unchanged.
    private static func reencode(_ data: Data) -> Data {
        if String(data: data, encoding: .utf8) != nil { return data }
        for encoding in [String.Encoding.windowsCP1254, .isoLatin1] {
            if let text = String(data: data, encoding: encoding) {
                return Data(text.utf8)
            }
        }
        return data
    }

    /// The app is unsandboxed and already shells out for mounts and downloads,
    /// so the system tools are the cheapest archive support available.
    private static func unzip(_ data: Data) throws -> Data {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zysub-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let archive = directory.appendingPathComponent("sub.zip")
        try data.write(to: archive)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-o", "-j", "-qq", archive.path, "-d", directory.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        let extensions: Set<String> = ["srt", "ass", "ssa", "sub", "vtt"]
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? []
        guard let subtitle = files.first(where: { extensions.contains($0.pathExtension.lowercased()) }),
              let contents = try? Data(contentsOf: subtitle) else {
            throw ClientError.notASubtitleAddon
        }
        return reencode(contents)
    }

    private static func gunzip(_ data: Data) throws -> Data {
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("zysub-\(UUID().uuidString).gz")
        defer { try? FileManager.default.removeItem(at: source) }
        try data.write(to: source)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gunzip")
        process.arguments = ["-c", source.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return reencode(output)
    }
}
