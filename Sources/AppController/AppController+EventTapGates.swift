/// Mirrors the main-thread facts the event taps consult into the interceptors, whose callbacks run
/// on the event-tap threads and cannot read that state directly.

import AppKit

extension AppController {
    /// Pushes the current gates to every interceptor. Called wherever a gate changes: hotkey
    /// suspension, sleep/wake protection, a chooser opening or closing, a topology change (which
    /// may change whether any screen is navigable), and at startup.
    internal func syncEventTapGates() {
        let hotkeysSuspended = hotkeyService.isSuspended
        let cmdTabActive = cmdTabController.isActive
        let winShotChooserActive = winShotChooserController.isActive

        cmdTabKeyInterceptor.isSuspended = hotkeysSuspended
        zoneNavigationInterceptor.isSuspended = hotkeysSuspended || sleepWakeProtectionActive
        // Choosers that own the arrow keys block the gesture. The Launcher deliberately does not:
        // it keeps its plain arrows, and this gesture is how the target moves by keyboard while it
        // is open.
        zoneNavigationInterceptor.canBegin = !cmdTabActive && !winShotChooserActive && hasNavigableZone()
        zoneClickInterceptor.isCmdTabActive = cmdTabActive
        zoneClickInterceptor.isWinShotChooserActive = winShotChooserActive
    }

    func hotkeyServiceDidChangeSuspension(_ service: HotkeyService) {
        syncEventTapGates()
    }
}
