import SwiftUI
import AppKit

enum CachedAsyncImageStorage {
    static let memoryCache = NSCache<NSString, NSImage>()
}

/// In-memory & disk-backed image cacher and SwiftUI view replacement for `AsyncImage`.
/// Ensures ALL downloaded artwork (posters, backdrops, logos, thumbnails) across
/// all features are stored persistently on disk under `AppPaths.artworkDirectory`.
struct CachedAsyncImage<Content: View>: View {
    let url: URL?
    let content: (AsyncImagePhase) -> Content

    @State private var phase: AsyncImagePhase = .empty
    @State private var currentURL: URL?

    init(url: URL?, @ViewBuilder content: @escaping (AsyncImagePhase) -> Content) {
        self.url = url
        self.content = content
    }

    init<I: View, P: View>(
        url: URL?,
        @ViewBuilder content: @escaping (Image) -> I,
        @ViewBuilder placeholder: @escaping () -> P
    ) where Content == AnyView {
        self.url = url
        self.content = { phase in
            switch phase {
            case .success(let image):
                return AnyView(content(image))
            case .failure, .empty:
                return AnyView(placeholder())
            @unknown default:
                return AnyView(placeholder())
            }
        }
    }

    var body: some View {
        content(phase)
            .task(id: url) {
                await loadImage(for: url)
            }
    }

    private func loadImage(for url: URL?) async {
        guard let url = url else {
            phase = .empty
            return
        }

        let key = Self.cacheKey(for: url)

        // 1. Check Memory Cache
        if let memoryImage = CachedAsyncImageStorage.memoryCache.object(forKey: key as NSString) {
            phase = .success(Image(nsImage: memoryImage))
            return
        }

        // 2. Check Disk Cache
        let diskURL = AppPaths.artworkDirectory.appendingPathComponent(key)
        if FileManager.default.fileExists(atPath: diskURL.path),
           let diskImage = NSImage(contentsOf: diskURL) {
            CachedAsyncImageStorage.memoryCache.setObject(diskImage, forKey: key as NSString)
            phase = .success(Image(nsImage: diskImage))
            return
        }

        // 3. Download from Network
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let downloadedImage = NSImage(data: data) else {
                phase = .failure(URLError(.cannotDecodeContentData))
                return
            }

            // Save to Disk Cache atomically
            try? data.write(to: diskURL, options: .atomic)

            // Save to Memory Cache
            CachedAsyncImageStorage.memoryCache.setObject(downloadedImage, forKey: key as NSString)

            phase = .success(Image(nsImage: downloadedImage))
        } catch {
            phase = .failure(error)
        }
    }

    /// Generates a safe, unique filename key for any URL.
    static func cacheKey(for url: URL) -> String {
        let string = url.absoluteString
        let safe = string.components(separatedBy: CharacterSet.alphanumerics.inverted).joined(separator: "_")
        let truncated = String(safe.suffix(120))
        return "url_\(truncated).jpg"
    }

    /// Clears memory cache.
    static func clearMemoryCache() {
        CachedAsyncImageStorage.memoryCache.removeAllObjects()
    }
}
