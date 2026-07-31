import Foundation
import AppKit
import NetFS

/// Mounts SMB shares through macOS's own NetFS stack.
///
/// Mounting rather than speaking SMB in-process means mpv gets an ordinary file
/// path, and the scanner, metadata and playback layers work unchanged.
enum SMBMounter {

    struct MountError: LocalizedError {
        var status: Int32
        var errorDescription: String? {
            switch status {
            case 13, -5045, -5046: "Kullanıcı adı veya parola hatalı."
            case 2: "Paylaşım bulunamadı."
            case 60, 64, 65: "Sunucuya ulaşılamıyor."
            case -5998: "Sunucuda paylaşım yok."
            case -1: "Bağlama iptal edildi."
            default: "Bağlanamadı (kod \(status))."
            }
        }
    }

    /// Mounts and returns the mount point, e.g. `/Volumes/Movies`.
    /// Already-mounted shares return their existing path.
    static func mount(_ share: SMBShare, password: String?) throws -> String {
        guard let url = share.url else { throw MountError(status: -1) }

        if let existing = share.mountPath,
           FileManager.default.fileExists(atPath: existing) {
            return existing
        }

        var mountpoints: Unmanaged<CFArray>?
        let openOptions = NSMutableDictionary()
        let mountOptions = NSMutableDictionary()
        // Do not put up UI; we already collected credentials ourselves.
        openOptions[kNAUIOptionKey] = kNAUIOptionNoUI

        let status = NetFSMountURLSync(
            url as CFURL,
            nil,                                   // let macOS pick /Volumes/<share>
            share.isGuest ? "guest" as CFString : share.username as CFString,
            share.isGuest ? "" as CFString : (password ?? "") as CFString,
            openOptions as CFMutableDictionary,
            mountOptions as CFMutableDictionary,
            &mountpoints
        )

        guard status == 0 else { throw MountError(status: status) }

        guard let paths = mountpoints?.takeRetainedValue() as? [String],
              let first = paths.first else {
            throw MountError(status: -1)
        }
        return first
    }

    /// Unmounts, ignoring the case where it is already gone.
    static func unmount(path: String) {
        guard FileManager.default.fileExists(atPath: path) else { return }
        try? NSWorkspace.shared.unmountAndEjectDevice(at: URL(fileURLWithPath: path))
    }
}
