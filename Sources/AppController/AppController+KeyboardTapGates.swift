/// Mirrors the main-thread facts the keyboard event taps consult into the interceptors, whose
/// callbacks run on the event-tap thread and cannot read that state directly.

import AppKit

extension AppController {
    /// Pushes the current gates to both interceptors. Called wherever a gate changes: hotkey
    /// suspension, sleep/wake protection, a chooser opening or closing, a topology change (which
    /// may change whether any screen is navigable), and at startup.
    internal func syncKeyboardTapGates() {
        let hotkeysSuspended = hotkeyService.isSuspended
        cmdTabKeyInterceptor.isSuspended = hotkeysSuspended
        zoneNavigationInterceptor.isSuspended = hotkeysSuspended || sleepWakeProtectionActive
        // Choosers that own the arrow keys block the gesture. The Launcher deliberately does not:
        // it keeps its plain arrows, and this gesture is how the target moves by keyboard while it
        // is open.
        zoneNavigationInterceptor.canBegin = !cmdTabController.isActive
            && !winShotChooserController.isActive
            && hasNavigableZone()
    }

    func hotkeyServiceDidChangeSuspension(_ service: HotkeyService) {
        syncKeyboardTapGates()
    }
}
