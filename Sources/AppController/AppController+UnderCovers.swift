import Foundation
import AppKit
import ApplicationServices

/// UnderCovers mode: temporarily hides the single-zone placeholder on a screen while keeping zone 1 alive.
extension AppController {
    private func underCoversEligibleZone(on screenId: CGDirectDisplayID, zoneIndex: Int) -> Zone? {
        guard zoneIndex == 1,
              let context = screenContexts[screenId] else {
            return nil
        }

        // UnderCovers is only available for the single empty non-floating zone 1 on a screen.
        let zones = context.zoneController.allZones
        guard zones.count == 1,
              let zone = zones.first,
              zone.index == 1,
              zone.isEmpty else {
            return nil
        }

        return zone
    }

    internal func placeholderButtonMode(for screenId: CGDirectDisplayID, zoneIndex: Int) -> PlaceholderButtonMode {
        guard underCoversEligibleZone(on: screenId, zoneIndex: zoneIndex) != nil else {
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
        guard let zone = underCoversEligibleZone(on: screenId, zoneIndex: zoneIndex) else {
            return
        }

        if underCoversScreens.contains(screenId) {
            let screenIndex = screenContextStore.loggingIndex(for: screenId)
            Logger.debug("UnderCovers already active on screen \(screenIndex); ignoring begin request (\(reason))")
            return
        }

        let key = ZoneKey(screenId: screenId, index: zone.index)
        if placeholderCoordinator.hasPlaceholder(for: key) {
            let screenIndex = screenContextStore.loggingIndex(for: screenId)
            Logger.debug("UnderCovers begin: closing placeholder for zone \(zone.index) on screen \(screenIndex)")
            placeholderCoordinator.removePlaceholder(for: key, reason: .idle)
        }

        underCoversScreens.insert(screenId)
        dismissLauncherIfActive()
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
            autoShowLauncherIfEmptyTargetedTiledZone()
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
        closePlaceholderIfNeeded(on: screenId, zoneIndex: zoneIndex, reason: .replacedByWindow)
        endUnderCoversForPlacementIfNeeded(on: screenId, zoneIndex: zoneIndex, reason: "window-placement")
        dismissLauncherIfActive()
    }

    private func closePlaceholderIfNeeded(
        on screenId: CGDirectDisplayID,
        zoneIndex: Int,
        reason: PlaceholderCoordinator.CloseReason
    ) {
        let key = ZoneKey(screenId: screenId, index: zoneIndex)
        placeholderCoordinator.removePlaceholder(for: key, reason: reason)
    }
}
