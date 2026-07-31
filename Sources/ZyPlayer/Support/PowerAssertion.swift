import Foundation
import IOKit
import IOKit.pwr_mgt

/// Keeps the display awake while video is playing.
///
/// mpv's own `stop-screensaver` does not apply here: with the render API mpv
/// owns no window, so it cannot tell the system that something is playing.
final class PowerAssertion {
    private var assertionID: IOPMAssertionID = 0
    private var isHeld = false

    /// Matches playback state; safe to call repeatedly.
    /// The reason is ASCII on purpose — it shows up in `pmset -g assertions`,
    /// which mangles non-ASCII text.
    func setActive(_ active: Bool, reason: String = "ZyPlayer is playing video") {
        if active {
            acquire(reason: reason)
        } else {
            release()
        }
    }

    private func acquire(reason: String) {
        guard !isHeld else { return }
        var id: IOPMAssertionID = 0
        let status = IOPMAssertionCreateWithName(
            kIOPMAssertionTypeNoDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &id
        )
        guard status == kIOReturnSuccess else { return }
        assertionID = id
        isHeld = true
    }

    private func release() {
        guard isHeld else { return }
        IOPMAssertionRelease(assertionID)
        assertionID = 0
        isHeld = false
    }

    deinit { release() }
}
