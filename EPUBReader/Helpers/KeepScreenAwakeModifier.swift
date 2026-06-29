import SwiftUI
import UIKit

/// Drives the app-global `UIApplication.shared.isIdleTimerDisabled` from a persisted toggle
/// and the current scene phase. Apply once at the app root via `View.keepScreenAwake(_:)` so
/// there is a single writer of the global idle timer.
private struct KeepScreenAwakeModifier: ViewModifier {
    let isEnabled: Bool
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .onAppear { apply() }
            .onChange(of: isEnabled) { apply() }
            .onChange(of: scenePhase) { apply() }
    }

    @MainActor
    private func apply() {
        UIApplication.shared.isIdleTimerDisabled = ScreenWakeDecider.shouldDisableIdleTimer(
            keepScreenAwake: isEnabled,
            isActive: scenePhase == .active
        )
    }
}

extension View {
    /// Keeps the screen awake (prevents auto-lock/dim) while the app is foregrounded and
    /// `isEnabled` is true. Apply once at the app root — `isIdleTimerDisabled` is app-global.
    func keepScreenAwake(_ isEnabled: Bool) -> some View {
        modifier(KeepScreenAwakeModifier(isEnabled: isEnabled))
    }
}
