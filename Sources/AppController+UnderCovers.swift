import Foundation
import AppKit
import ApplicationServices

/// UnderCovers mode: temporarily hides the single-zone placeholder on a screen while keeping zone 1 alive.
extension AppController {
    internal func placeholderButtonMode(for screenId: CGDirectDisplayID, zoneIndex: Int) -> PlaceholderButtonMode {
        guard let context = screenContexts[screenId] else {
            return .removeZone
        }

        // UnderCovers is only available for the single empty non-temporary zone 1 on a screen.
        guard zoneIndex == 1 else {
            return .removeZone
        }

        let zones = context.zoneController.allZones
        guard zones.count == 1, let zone = zones.first, zone.isEmpty else {
            return .removeZone
        }

        // When UnderCovers is active, the placeholder is hidden so this mode is never queried;
        // treat the presence of a placeholder as an invitation to offer the put-away affordance.
        return .underCovers
    }

    internal func isUnderCoversActive(on screenId: CGDirectDisplayID) -> Bool {
        underCoversScreens.contains(screenId)
    }

    internal func beginUnderCoversIfEligible(on screenId: CGDirectDisplayID, zoneIndex: Int, reason: String) {
        guard zoneIndex == 1,
              let context = screenContexts[screenId] else {
            return
        }

        let zones = context.zoneController.allZones
        guard zones.count == 1, let zone = zones.first, zone.isEmpty else {
            return
        }

        if underCoversScreens.contains(screenId) {
            let screenIndex = screenContextStore.loggingIndex(for: screenId)
            Logger.debug("UnderCovers already active on screen \(screenIndex); ignoring begin request (\(reason))")
            return
        }

        if let placeholderId = zone.placeholderWindowId,
           let placeholder = windowController.window(withId: placeholderId) {
            let screenIndex = screenContextStore.loggingIndex(for: screenId)
            Logger.debug("UnderCovers begin: closing placeholder \(placeholderId) for zone 1 on screen \(screenIndex)")
            windowController.closeWindow(placeholder)
            placeholderCoordinator.forget(windowId: placeholderId)
            context.zoneController.setPlaceholder(windowId: nil, forZoneIndex: zone.index)
        }

        underCoversScreens.insert(screenId)
        let screenIndex = screenContextStore.loggingIndex(for: screenId)
        Logger.debug("UnderCovers entered on screen \(screenIndex) (reason: \(reason))")
    }

    internal func endUnderCovers(on screenId: CGDirectDisplayID, reason: String, recreatePlaceholders: Bool) {
        guard underCoversScreens.contains(screenId) else { return }
        underCoversScreens.remove(screenId)

        let screenIndex = screenContextStore.loggingIndex(for: screenId)
        Logger.debug("UnderCovers exiting on screen \(screenIndex) (reason: \(reason))")

        if recreatePlaceholders {
            syncWindowsToZones()
        }
    }

    internal func endUnderCoversForPlacementIfNeeded(on screenId: CGDirectDisplayID, zoneIndex: Int, reason: String) {
        guard zoneIndex == 1 else { return }
        if underCoversScreens.contains(screenId) {
            endUnderCovers(on: screenId, reason: reason, recreatePlaceholders: false)
        }
    }

    // MARK: - WindowPlacementManagerDelegate hook

    func willPlaceWindowIntoZone(on screenId: CGDirectDisplayID, zoneIndex: Int) {
        endUnderCoversForPlacementIfNeeded(on: screenId, zoneIndex: zoneIndex, reason: "window-placement")
        dismissLauncherIfActive()
    }
}
