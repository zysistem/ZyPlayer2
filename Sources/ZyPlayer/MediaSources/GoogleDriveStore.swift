import Foundation
import Observation

/// Google Drive as a library source: sign in, list videos, hand them to the
/// library as `MediaItem`s so parsing, TMDB and playback all work unchanged.
@Observable
final class GoogleDriveStore {

    var isConnected = false
    var isBusy = false
    var statusMessage = ""
    var accountFileCount = 0

    @ObservationIgnored private let auth = GoogleDriveAuth()
    @ObservationIgnored private let settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
        Task { isConnected = await auth.hasStoredCredentials }
    }

    // MARK: - Session

    @MainActor
    func connect(library: LibraryStore) async {
        guard !settings.googleClientID.isEmpty else {
            statusMessage = "Önce Google istemci kimliğini girin."
            return
        }
        isBusy = true
        defer { isBusy = false }
        statusMessage = "Tarayıcıda izin bekleniyor…"

        do {
            _ = try await auth.signIn(
                clientID: settings.googleClientID,
                clientSecret: settings.googleClientSecret
            )
            isConnected = true
            statusMessage = settings.driveFolderID.isEmpty
                ? "Bağlandı. Şimdi bir klasör seçin."
                : "Bağlandı"
            await sync(library: library)
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    @MainActor
    func disconnect(library: LibraryStore) async {
        await auth.signOut()
        isConnected = false
        library.removeItems(from: .googleDrive)
        statusMessage = "Bağlantı kesildi"
        accountFileCount = 0
    }

    // MARK: - Sync

    /// Pulls the video list and merges it into the library.
    @MainActor
    func sync(library: LibraryStore) async {
        let hasCredentials = await auth.hasStoredCredentials
        guard isConnected || hasCredentials else { return }
        isBusy = true
        defer { isBusy = false }
        statusMessage = "Drive taranıyor…"

        do {
            let token = try await auth.validAccessToken(
                clientID: settings.googleClientID,
                clientSecret: settings.googleClientSecret
            )
            let client = GoogleDriveClient(accessToken: token)
            let folderID = settings.driveFolderID
            let files: [GoogleDriveClient.DriveFile]

            if folderID.isEmpty {
                // No folder chosen yet: do not pull the whole account.
                statusMessage = "Bir Drive klasörü seçin."
                return
            }
            files = try await client.listVideos(inFolder: folderID) { [weak self] count in
                Task { @MainActor in self?.statusMessage = "Drive taranıyor… \(count) dosya" }
            }

            let items = files.map { file -> MediaItem in
                let parsed = FilenameParser.parse(url: URL(fileURLWithPath: file.name))
                return MediaItem(
                    url: file.downloadURL,
                    kind: parsed.kind,
                    source: .googleDrive,
                    remoteID: file.id,
                    title: parsed.title,
                    year: parsed.year,
                    showTitle: parsed.showTitle,
                    season: parsed.season,
                    episode: parsed.episode,
                    fileSize: file.byteSize,
                    modifiedAt: file.modifiedTime ?? .now
                )
            }

            library.replaceItems(from: .googleDrive, with: items)
            accountFileCount = items.count
            isConnected = true
            statusMessage = "\(items.count) video bulundu"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    /// Sub-folders of `parentID`, for the folder picker.
    func folders(in parentID: String) async throws -> [GoogleDriveClient.DriveFile] {
        let token = try await auth.validAccessToken(
            clientID: settings.googleClientID,
            clientSecret: settings.googleClientSecret
        )
        return try await GoogleDriveClient(accessToken: token).listFolders(in: parentID)
    }

    /// Fresh bearer token for mpv's HTTP headers.
    func currentAccessToken() async -> String? {
        try? await auth.validAccessToken(
            clientID: settings.googleClientID,
            clientSecret: settings.googleClientSecret
        )
    }
}
