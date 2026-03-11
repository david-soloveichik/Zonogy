import Foundation

/// Activates the managed window occupying the currently targeted destination.
extension AppController {
    internal func focusTargetedWindow() {
        targetedZoneManager.ensureTargetedZone(reason: "shortcut-focus-targeted-window")

        if let target = targetedZoneKey {
            let screenIndex = screenContextStore.loggingIndex(for: target.screenId)
            guard let context = screenContexts[target.screenId] else {
                Logger.debug("Focus targeted window: missing context for targeted zone \(target.index) on screen \(screenIndex)")
                return
            }
            guard let zone = context.zoneController.zone(at: target.index) else {
                Logger.debug("Focus targeted window: missing targeted zone \(target.index) on screen \(screenIndex)")
                return
            }
            guard let windowId = zone.occupantWindowId else {
                Logger.debug("Focus targeted window: targeted zone \(target.index) on screen \(screenIndex) is empty")
                return
            }
            guard let managed = windowController.window(withId: windowId) else {
                Logger.debug("Focus targeted window: zone \(target.index) on screen \(screenIndex) references missing window \(windowId)")
                return
            }

            Logger.debug("Focus targeted window: activating window \(managed.windowId) in zone \(target.index) on screen \(screenIndex)")
            raiseWindow(managed)
            return
        }

        if let screenId = targetedFloatingScreenId {
            let screenIndex = screenContextStore.loggingIndex(for: screenId)
            guard let managed = floatingZoneOccupant(on: screenId) else {
                Logger.debug("Focus targeted window: targeted floating zone on screen \(screenIndex) is empty")
                return
            }

            Logger.debug("Focus targeted window: activating floating-zone window \(managed.windowId) on screen \(screenIndex)")
            activateFloatingZoneWindow(managed, reason: "shortcut-focus-targeted-window")
            return
        }

        Logger.debug("Focus targeted window: no targeted destination available")
    }
}
