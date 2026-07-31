import Foundation

/// Walks library folders and turns video files into `MediaItem`s.
enum LibraryScanner {

    /// Directories that never contain user media.
    private static let skippedDirectories: Set<String> = [
        ".Trash", "@eaDir", "#recycle", ".Spotlight-V100", ".fseventsd", "node_modules"
    ]

    struct ScanResult {
        var items: [MediaItem] = []
        var scannedFileCount: Int = 0
    }

    /// Scans one folder recursively. `existing` is keyed by file path so files
    /// that are already known keep their id, artwork and watch history.
    static func scan(folder url: URL, existing: [String: MediaItem]) -> ScanResult {
        var result = ScanResult()
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isHiddenKey]

        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants]
        ) else {
            return result
        }

        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: Set(keys))

            if values?.isDirectory == true {
                if skippedDirectories.contains(fileURL.lastPathComponent)
                    || fileURL.lastPathComponent.hasPrefix(".") {
                    enumerator.skipDescendants()
                }
                continue
            }

            guard MediaTypes.isVideo(fileURL), values?.isHidden != true else { continue }
            // Skip the tiny "sample" files that ship with releases.
            let size = Int64(values?.fileSize ?? 0)
            if size > 0 && size < 50_000_000 && fileURL.lastPathComponent.lowercased().contains("sample") {
                continue
            }

            result.scannedFileCount += 1
            let modified = values?.contentModificationDate ?? .now

            let parsed = FilenameParser.parse(url: fileURL)

            if var known = existing[fileURL.path] {
                known.fileSize = size
                known.modifiedAt = modified
                // Re-parse so parser improvements reach items already in the
                // library, but never overwrite titles confirmed against TMDB.
                if known.tmdbID == nil {
                    known.kind = parsed.kind
                    known.title = parsed.title
                    known.year = parsed.year
                    known.showTitle = parsed.showTitle
                    known.season = parsed.season
                    known.episode = parsed.episode
                }
                result.items.append(known)
                continue
            }

            result.items.append(
                MediaItem(
                    url: fileURL,
                    kind: parsed.kind,
                    title: parsed.title,
                    year: parsed.year,
                    showTitle: parsed.showTitle,
                    season: parsed.season,
                    episode: parsed.episode,
                    fileSize: size,
                    modifiedAt: modified
                )
            )
        }

        return result
    }
}
