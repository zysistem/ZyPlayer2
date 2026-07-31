import Foundation

extension KeyedDecodingContainer {
    /// Decodes a value, falling back to `fallback` when the key is absent.
    ///
    /// Swift's synthesized `Decodable` ignores property default values and
    /// throws `keyNotFound` instead, so adding one field to a model makes every
    /// previously written file undecodable. Every stored model decodes through
    /// this helper so the JSON stores stay forward- and backward-compatible.
    func value<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        ((try? decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
    }

    func optional<T: Decodable>(_ key: Key) -> T? {
        (try? decodeIfPresent(T.self, forKey: key)) ?? nil
    }
}

enum AppPaths {
    /// `~/Library/Application Support/ZyPlayer`
    static let supportDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("ZyPlayer", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static let artworkDirectory: URL = {
        let dir = supportDirectory.appendingPathComponent("Artwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Downloaded subtitle files.
    static let subtitleDirectory: URL = {
        let dir = supportDirectory.appendingPathComponent("Subtitles", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func file(_ name: String) -> URL {
        supportDirectory.appendingPathComponent(name)
    }
}

/// JSON-file persistence. No database by design — each store is one `Codable`
/// value written atomically to Application Support.
final class LocalStore<Value: Codable> {
    private let url: URL
    private let defaultValue: Value
    private let queue = DispatchQueue(label: "com.zyplayer.localstore")

    private(set) var value: Value

    init(fileName: String, defaultValue: Value) {
        self.url = AppPaths.file(fileName)
        self.defaultValue = defaultValue
        let (loaded, error) = Self.read(from: url)
        self.value = loaded ?? defaultValue
        self.loadError = error
    }

    /// Set when the file existed but could not be read, so callers can refuse to
    /// overwrite it.
    private(set) var loadError: Error?

    private static func read(from url: URL) -> (value: Value?, error: Error?) {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            return (nil, nil)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return (try decoder.decode(Value.self, from: data), nil)
        } catch {
            // Never silently replace unreadable data with defaults: keep a copy
            // so nothing is lost, and let the caller decide.
            let stamp = ISO8601DateFormatter().string(from: .now)
                .replacingOccurrences(of: ":", with: "-")
            let backup = url.deletingPathExtension()
                .appendingPathExtension("corrupt-\(stamp).json")
            try? data.write(to: backup, options: .atomic)
            NSLog("ZyPlayer: %@ okunamadı (%@). Yedek: %@",
                  url.lastPathComponent, String(describing: error), backup.lastPathComponent)
            return (nil, error)
        }
    }

    /// Mutates in memory, then persists off the main thread.
    func update(_ mutate: (inout Value) -> Void) {
        mutate(&value)
        save()
    }

    func replace(with newValue: Value) {
        value = newValue
        save()
    }

    func save() {
        let snapshot = value
        let target = url
        queue.async {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let data = try? encoder.encode(snapshot) else { return }
            // Atomic write so a crash mid-save can't truncate the library.
            try? data.write(to: target, options: .atomic)
        }
    }

    func reset() {
        replace(with: defaultValue)
    }
}
