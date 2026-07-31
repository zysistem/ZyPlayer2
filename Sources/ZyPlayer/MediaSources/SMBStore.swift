import Foundation
import Observation

/// Keeps the list of network shares and their mount state.
@Observable
final class SMBStore {

    private(set) var shares: [SMBShare] = []
    var statusMessage: String = ""
    var isBusy = false

    @ObservationIgnored private let store = LocalStore(
        fileName: "shares.json", defaultValue: SMBData()
    )

    init() {
        shares = store.value.shares
    }

    /// Adds a share, mounts it, and hands the mount point to the library.
    @MainActor
    func add(host: String,
             shareName: String,
             username: String,
             password: String,
             isGuest: Bool,
             library: LibraryStore) async -> Bool {
        var share = SMBShare(
            host: host.trimmingCharacters(in: .whitespaces),
            shareName: shareName.trimmingCharacters(in: .whitespaces),
            username: username.trimmingCharacters(in: .whitespaces),
            isGuest: isGuest
        )

        isBusy = true
        defer { isBusy = false }
        statusMessage = "Bağlanılıyor…"

        if !isGuest, !password.isEmpty {
            Keychain.set(password, for: share.credentialKey)
        }

        do {
            let path = try mountOffMainThread(share, password: password)
            share.mountPath = path
            shares.append(share)
            persist()
            library.addFolder(URL(fileURLWithPath: path))
            statusMessage = "Bağlandı: \(path)"
            return true
        } catch {
            statusMessage = error.localizedDescription
            Keychain.remove(account: share.credentialKey)
            return false
        }
    }

    /// Re-mounts saved shares at launch; a share that is already mounted is a no-op.
    @MainActor
    func remountAll(library: LibraryStore) async {
        for index in shares.indices {
            let share = shares[index]
            if share.isMounted { continue }
            let password = Keychain.get(account: share.credentialKey)
            guard let path = try? mountOffMainThread(share, password: password) else { continue }
            shares[index].mountPath = path
            if !library.folders.contains(where: { $0.url.path == path }) {
                library.addFolder(URL(fileURLWithPath: path))
            }
        }
        persist()
    }

    @MainActor
    func remove(_ share: SMBShare, library: LibraryStore) {
        if let path = share.mountPath {
            if let folder = library.folders.first(where: { $0.url.path == path }) {
                library.removeFolder(folder)
            }
            SMBMounter.unmount(path: path)
        }
        Keychain.remove(account: share.credentialKey)
        shares.removeAll { $0.id == share.id }
        persist()
    }

    /// NetFS blocks while it talks to the server, so keep it off the main thread.
    private func mountOffMainThread(_ share: SMBShare, password: String?) throws -> String {
        var result: Result<String, Error>!
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                result = .success(try SMBMounter.mount(share, password: password))
            } catch {
                result = .failure(error)
            }
            semaphore.signal()
        }
        semaphore.wait()
        return try result.get()
    }

    private func persist() {
        store.replace(with: SMBData(shares: shares))
    }
}
