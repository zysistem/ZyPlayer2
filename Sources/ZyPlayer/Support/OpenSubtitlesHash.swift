import Foundation

/// OpenSubtitles' file hash, which subtitle addons accept as `videoHash` to
/// return the release that actually matches the file rather than the film.
///
/// The algorithm is the classic OSDb one: file size plus the 64-bit words of the
/// first and last 64 KB, added with wraparound.
enum OpenSubtitlesHash {
    private static let chunkSize = 65536

    /// `nil` for anything that is not a readable local file — Drive and other
    /// HTTP streams would need range requests to hash, which is not worth it.
    static func compute(for url: URL) -> (hash: String, size: Int64)? {
        guard url.isFileURL, let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        guard let size = try? handle.seekToEnd(), size >= UInt64(chunkSize) else { return nil }

        var hash = size

        try? handle.seek(toOffset: 0)
        guard let head = try? handle.read(upToCount: chunkSize), head.count == chunkSize else {
            return nil
        }
        try? handle.seek(toOffset: size - UInt64(chunkSize))
        guard let tail = try? handle.read(upToCount: chunkSize), tail.count == chunkSize else {
            return nil
        }

        for chunk in [head, tail] {
            for word in words(of: chunk) {
                hash = hash &+ word
            }
        }

        return (String(format: "%016qx", hash), Int64(size))
    }

    /// Little-endian 64-bit words. `withUnsafeBytes` avoids an alignment trap on
    /// the raw buffer, which a direct `load(as:)` would risk.
    private static func words(of data: Data) -> [UInt64] {
        data.withUnsafeBytes { raw in
            stride(from: 0, to: raw.count - 7, by: 8).map { offset in
                UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt64.self))
            }
        }
    }
}
