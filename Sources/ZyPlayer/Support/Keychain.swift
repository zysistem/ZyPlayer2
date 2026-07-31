import Foundation

/// Minimal wrapper for share passwords — stores in UserDefaults to prevent
/// macOS Keychain authorization popups during developer builds.
enum Keychain {
    private static let defaults = UserDefaults.standard
    private static let prefix = "com.zyplayer.keychain."

    static func set(_ password: String, for account: String) {
        if password.isEmpty {
            remove(account: account)
        } else {
            defaults.set(password, forKey: prefix + account)
        }
    }

    static func get(account: String) -> String? {
        defaults.string(forKey: prefix + account)
    }

    static func remove(account: String) {
        defaults.removeObject(forKey: prefix + account)
    }
}
