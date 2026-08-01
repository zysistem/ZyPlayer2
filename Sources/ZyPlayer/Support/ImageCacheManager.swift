import Foundation
import AppKit
import SwiftUI

/// Manages global image and artwork disk caching and cache size calculations.
enum ImageCacheManager {

    /// Configures 1GB disk cache for standard network image requests (e.g. AsyncImage).
    static func configure() {
        let memoryCapacity = 100 * 1024 * 1024 // 100 MB RAM
        let diskCapacity = 1024 * 1024 * 1024   // 1 GB Disk
        let urlCache = URLCache(
            memoryCapacity: memoryCapacity,
            diskCapacity: diskCapacity,
            diskPath: "ZyPlayerImageCache"
        )
        URLCache.shared = urlCache
    }

    /// Calculates total size of all image caches (URLCache + ArtworkCache).
    static var totalCacheSizeBytes: Int64 {
        let urlCacheSize = Int64(URLCache.shared.currentDiskUsage)
        let artworkSize = ArtworkCache.cacheSizeBytes
        return urlCacheSize + artworkSize
    }

    /// Returns human-readable cache size string (e.g. "45.2 MB").
    static var formattedCacheSize: String {
        let bytes = totalCacheSizeBytes
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB, .useKB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    /// Clears both URLCache, ArtworkCache, and CachedAsyncImage memory cache.
    static func clearAllCaches() {
        URLCache.shared.removeAllCachedResponses()
        ArtworkCache.clear()
        CachedAsyncImageStorage.memoryCache.removeAllObjects()
    }
}
