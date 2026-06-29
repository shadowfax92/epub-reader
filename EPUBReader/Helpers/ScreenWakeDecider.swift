import Foundation

/// Decides whether the device idle timer should be disabled (screen kept awake) right now.
/// Pure so the foreground-gating rule is unit-testable without UIKit/SwiftUI.
enum ScreenWakeDecider {
    /// Disable the idle timer only when the user opted in *and* the app is foregrounded,
    /// so the lock is never held off while the app is inactive or backgrounded.
    static func shouldDisableIdleTimer(keepScreenAwake: Bool, isActive: Bool) -> Bool {
        keepScreenAwake && isActive
    }
}
