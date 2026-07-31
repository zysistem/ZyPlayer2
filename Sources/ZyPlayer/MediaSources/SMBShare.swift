import Foundation

/// A network share the user added. The password lives in the Keychain, never here.
struct SMBShare: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var host: String
    var shareName: String
    var username: String = ""
    var isGuest: Bool = false
    var addedAt: Date = .now
    /// Filled in once mounted, e.g. `/Volumes/Movies`.
    var mountPath: String?

    var displayName: String { "\(shareName) — \(host)" }

    var url: URL? {
        var components = URLComponents()
        components.scheme = "smb"
        components.host = host
        components.path = "/" + shareName
        return components.url
    }

    /// Keychain account key; the service is fixed per app.
    var credentialKey: String { "smb://\(username)@\(host)/\(shareName)" }

    var isMounted: Bool {
        guard let mountPath else { return false }
        return FileManager.default.fileExists(atPath: mountPath)
    }
}

struct SMBData: Codable {
    var shares: [SMBShare] = []
}
