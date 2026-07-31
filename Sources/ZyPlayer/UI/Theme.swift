import SwiftUI
import AppKit

/// App-wide chrome. The window falls from a deep navy at the top to black at the
/// bottom; the sidebar uses the same hues a shade darker so it reads as its own
/// surface without breaking the gradient.
enum AppTheme {

    static func background(_ scheme: ColorScheme) -> LinearGradient {
        scheme == .dark
            ? LinearGradient(
                colors: [
                    Color(red: 0.05, green: 0.09, blue: 0.19),
                    Color(red: 0.02, green: 0.04, blue: 0.09),
                    .black
                ],
                startPoint: .top, endPoint: .bottom
              )
            : LinearGradient(
                colors: [Color(white: 0.99), Color(white: 0.92)],
                startPoint: .top, endPoint: .bottom
              )
    }

    /// The colour at the very top of the window gradient, as an `NSColor`. The
    /// window background is set to this so the transparent title-bar/toolbar strip
    /// blends into the content instead of showing macOS grey in fullscreen.
    static func windowTopColor(_ scheme: ColorScheme) -> NSColor {
        scheme == .dark
            ? NSColor(srgbRed: 0.05, green: 0.09, blue: 0.19, alpha: 1)
            : NSColor(srgbRed: 0.99, green: 0.99, blue: 0.99, alpha: 1)
    }

    static func sidebar(_ scheme: ColorScheme) -> LinearGradient {
        scheme == .dark
            ? LinearGradient(
                colors: [
                    Color(red: 0.03, green: 0.06, blue: 0.14),
                    Color(red: 0.01, green: 0.02, blue: 0.05)
                ],
                startPoint: .top, endPoint: .bottom
              )
            : LinearGradient(
                colors: [Color(white: 0.96), Color(white: 0.90)],
                startPoint: .top, endPoint: .bottom
              )
    }
}
