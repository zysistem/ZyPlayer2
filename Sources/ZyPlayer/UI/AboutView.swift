import SwiftUI
import AppKit

/// App identity in one place, read from the bundle so the version never drifts
/// from what was actually built.
enum AppInfo {
    static let name = "ZyPlayer"
    static let developer = "Zysistem.net"
    static let website = URL(string: "https://zysistem.net")!

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }

    /// The bundled icon; `applicationIconImage` is the fallback for builds run
    /// straight out of DerivedData, where the icns may not be registered yet.
    static var icon: NSImage {
        NSImage(named: "AppIcon") ?? NSApplication.shared.applicationIconImage
    }
}

/// "ZyPlayer Hakkında" — logo, version, developer.
struct AboutView: View {
    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: AppInfo.icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 96, height: 96)
                .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
                .padding(.bottom, 16)

            Text(AppInfo.name)
                .font(.system(size: 26, weight: .semibold))

            Text("Sürüm \(AppInfo.version)")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.top, 4)

            Divider()
                .frame(width: 180)
                .padding(.vertical, 18)

            Text("Geliştirici")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Link(AppInfo.developer, destination: AppInfo.website)
                .font(.system(size: 15, weight: .medium))
                .padding(.top, 2)

            Text("macOS için yerel medya oynatıcı")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.top, 16)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 40)
        .padding(.vertical, 36)
        .frame(width: 340)
    }
}
