import Foundation
import Observation

/// Observable download list backed by `TorrentEngine`.
@Observable
final class TorrentStore {

    private(set) var downloads: [TorrentDownload] = []
    var statusMessage = ""
    var isStarting = false

    @ObservationIgnored private let engine = TorrentEngine()
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    /// GIDs already handed to the library, so completion runs once each.
    @ObservationIgnored private var importedGIDs: Set<String> = []

    init(settings: AppSettings) {
        self.settings = settings
    }

    var isEngineAvailable: Bool { TorrentEngine.isInstalled }

    // MARK: - Lifecycle

    @MainActor
    func startIfNeeded() async {
        if await engine.isRunning { return }
        // Another caller is mid-start (e.g. the Downloads screen's own `.task`
        // firing as we navigate to it): wait for it to finish rather than racing
        // ahead to addMagnet before the RPC endpoint is up — which would throw and
        // silently drop the download.
        if isStarting {
            while isStarting { try? await Task.sleep(for: .milliseconds(50)) }
            return
        }
        isStarting = true
        defer { isStarting = false }
        do {
            try await engine.start(downloadDirectory: settings.downloadDirectory)
            statusMessage = ""
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    /// Polls while the Downloads screen is on-screen.
    @MainActor
    func beginPolling(library: LibraryStore) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh(library: library)
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func endPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    func shutdown() async {
        endPolling()
        await engine.stop()
    }

    @MainActor
    private func refresh(library: LibraryStore) async {
        downloads = await engine.allDownloads()
        await importFinished(library: library)
    }

    // MARK: - Actions

    /// `directory` overrides the configured download folder for this one item —
    /// the torrent picker lets the user pick a destination per download.
    @MainActor
    func add(_ input: String, library: LibraryStore, directory: String? = nil) async {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        await startIfNeeded()
        await engine.setDownloadDirectory(directory ?? settings.downloadDirectory)

        do {
            if trimmed.hasPrefix("magnet:") {
                try await engine.addMagnet(trimmed)
            } else if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
                try await engine.addMagnet(trimmed)   // aria2 fetches .torrent URLs too
            } else {
                let url = URL(fileURLWithPath: trimmed)
                guard FileManager.default.fileExists(atPath: url.path) else {
                    statusMessage = "Geçersiz bağlantı ya da dosya."
                    return
                }
                try await engine.addTorrentFile(url)
            }
            statusMessage = ""
            await refresh(library: library)
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    @MainActor
    func addTorrentFile(_ url: URL, library: LibraryStore) async {
        await startIfNeeded()
        await engine.setDownloadDirectory(settings.downloadDirectory)
        do {
            try await engine.addTorrentFile(url)
            await refresh(library: library)
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func pause(_ download: TorrentDownload) async {
        await engine.pause(download.id)
    }

    func resume(_ download: TorrentDownload) async {
        await engine.resume(download.id)
    }

    @MainActor
    func remove(_ download: TorrentDownload, deleteFiles: Bool, library: LibraryStore) async {
        await engine.remove(download.id, deleteFiles: deleteFiles, filePaths: download.filePaths)
        importedGIDs.remove(download.id)
        await refresh(library: library)
    }

    // MARK: - Library hand-off

    /// Once a torrent finishes, make sure its folder is in the library and
    /// rescan, so the file shows up with artwork like anything else.
    @MainActor
    private func importFinished(library: LibraryStore) async {
        let finished = downloads.filter { $0.isFinished && !importedGIDs.contains($0.id) }
        guard !finished.isEmpty else { return }

        let hasVideo = finished.contains { download in
            download.filePaths.contains { MediaTypes.isVideo(URL(fileURLWithPath: $0)) }
        }
        finished.forEach { importedGIDs.insert($0.id) }
        guard hasVideo else { return }

        let directory = URL(fileURLWithPath: settings.downloadDirectory)
        if !library.folders.contains(where: { $0.url.path == directory.path }) {
            library.addFolder(directory)   // addFolder rescans on its own
        } else {
            await library.rescan()
        }
        statusMessage = "İndirme tamamlandı, kütüphaneye eklendi."
    }
}
