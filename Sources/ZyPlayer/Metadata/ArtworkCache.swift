import Foundation
import AppKit

/// Downloads TMDB artwork once and keeps it on disk under Application Support.
enum ArtworkCache {

    /// Downloads `path` if it isn't cached yet and returns the local file name.
    @discardableResult
    static func fetch(path: String?, size: String = "w500", key: String) async -> String? {
        guard let path, !path.isEmpty else { return nil }

        let fileName = "\(key)_\(size).jpg"
        let destination = AppPaths.artworkDirectory.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: destination.path) { return fileName }

        let url = TMDBClient.imageURL(path: path, size: size)
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  !data.isEmpty else {
                return nil
            }
            try data.write(to: destination, options: .atomic)
            return fileName
        } catch {
            return nil
        }
    }

    static func image(named fileName: String?) -> NSImage? {
        guard let fileName else { return nil }
        return NSImage(contentsOf: AppPaths.artworkDirectory.appendingPathComponent(fileName))
    }

    static func clear() {
        try? FileManager.default.removeItem(at: AppPaths.artworkDirectory)
        _ = AppPaths.artworkDirectory
    }

    static var cacheSizeBytes: Int64 {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: AppPaths.artworkDirectory,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        return contents.reduce(into: Int64(0)) { total, url in
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }
}
