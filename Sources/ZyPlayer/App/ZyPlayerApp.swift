import SwiftUI
import UniformTypeIdentifiers

/// Receives files opened from Finder or `open -a ZyPlayer <file>`.
final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var player: PlayerModel?
    static weak var streamer: TorrentStreamer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let iconImage = NSImage(named: "AppIcon") {
            NSApp.applicationIconImage = iconImage
        }
        // Çökme ya da eski sürümlerden sarkan indirme motorları: uygulama daha
        // kendi motorunu başlatmadan temizlenir. Burada, çünkü bu geri çağrı
        // oturumda tam olarak bir kez ve her şeyden önce çalışır.
        TorrentEngine.terminateStrayProcesses()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first(where: { MediaTypes.isVideo($0) }) ?? urls.first else { return }
        Self.player?.open(url)
    }

    /// Torrent streaming keeps its data in a cache directory that must not
    /// outlive the session — the helper process goes down with it.
    ///
    /// `aria2c` de burada kapatılır: ayrı bir süreç olduğundan uygulama
    /// kapandığında kendiliğinden ölmez, arkada indirmeye devam eder.
    func applicationWillTerminate(_ notification: Notification) {
        Self.streamer?.stopAndWait()
        TorrentStreamer.clearCache()
        TorrentEngine.terminateStrayProcesses()
    }
}

@main
struct ZyPlayerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow
    @State private var player = PlayerModel()
    @State private var library = LibraryStore()
    @State private var settings = AppSettings()
    @State private var smb = SMBStore()
    @State private var drive: GoogleDriveStore
    @State private var torrents: TorrentStore
    @State private var streamDownloads: StreamDownloadStore
    @State private var cinema = CinemaStore()
    @State private var appleTV = AppleTVStore()
    @State private var providers = StreamingProviderStore()
    @State private var streamer = TorrentStreamer()
    @State private var iptv: IPTVStore

    init() {
        ImageCacheManager.configure()
        let settings = AppSettings()
        _settings = State(initialValue: settings)
        _drive = State(initialValue: GoogleDriveStore(settings: settings))
        _torrents = State(initialValue: TorrentStore(settings: settings))
        _streamDownloads = State(initialValue: StreamDownloadStore(settings: settings))
        _iptv = State(initialValue: IPTVStore(settings: settings))
    }

    var body: some Scene {
        // `Window`, not `WindowGroup`: opening a second file must reuse the
        // player rather than spawn another window with its own mpv instance.
        Window("ZyPlayer", id: "main") {
            RootView(player: player, library: library, smb: smb, drive: drive,
                     torrents: torrents, streamDownloads: streamDownloads,
                     streamer: streamer, cinema: cinema,
                     appleTV: appleTV, providers: providers, settings: settings,
                     iptv: iptv)
                .frame(minWidth: 900, minHeight: 560)
                // Uygulamanın seçili görünümünü (Açık/Koyu) tüm pencereye uygula.
                // Bu olmadan arka planlar ayara göre, metin renkleri ise SİSTEM
                // görünümüne göre gidiyordu; ikisi çakışınca (ör. sistem koyu, uygulama
                // açık) açık modda beyaz-üstüne-beyaz "bozuk" görüntü çıkıyordu.
                .preferredColorScheme(settings.colorScheme)
                .onAppear {
                    AppDelegate.player = player
                    AppDelegate.streamer = streamer
                    // Anything a crash left behind is dead weight.
                    TorrentStreamer.clearCache()
                    // Removed eager loading to improve launch performance.
                    // HomeView will fetch its own content when it appears.
                    // Heavy file sync runs concurrently in background
                    Task {
                        await smb.remountAll(library: library)
                        if !library.folders.isEmpty { await library.rescan() }
                        await drive.sync(library: library)
                        if settings.fetchMetadataAutomatically, !library.items.isEmpty {
                            await library.fetchMetadata(settings: settings)
                        }
                    }
                }
                .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                    loadDroppedFile(from: providers)
                }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Dosya Aç…") { openFile() }
                    .keyboardShortcut("o", modifiers: .command)
            }
            // Replaces the stock about panel with our own, so the app menu item
            // shows the logo, version and developer.
            CommandGroup(replacing: .appInfo) {
                Button("ZyPlayer Hakkında") { openWindow(id: "about") }
            }
        }

        Window("ZyPlayer Hakkında", id: "about") {
            AboutView()
                .preferredColorScheme(settings.colorScheme)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }

    private func openFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = MediaTypes.videoContentTypes
        guard panel.runModal() == .OK, let url = panel.url else { return }
        player.open(url)
    }

    private func loadDroppedFile(from providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url, MediaTypes.isVideo(url) else { return }
            DispatchQueue.main.async { player.open(url) }
        }
        return true
    }
}

enum MediaTypes {
    static let videoExtensions: Set<String> = [
        "mkv", "mp4", "m4v", "avi", "mov", "webm", "ts", "m2ts", "mts",
        "flv", "wmv", "mpg", "mpeg", "iso", "vob", "ogv", "3gp", "divx"
    ]

    static var videoContentTypes: [UTType] {
        var types: [UTType] = [.movie, .video, .mpeg4Movie, .quickTimeMovie]
        for ext in videoExtensions {
            if let type = UTType(filenameExtension: ext) { types.append(type) }
        }
        return types
    }

    static func isVideo(_ url: URL) -> Bool {
        videoExtensions.contains(url.pathExtension.lowercased())
    }
}
