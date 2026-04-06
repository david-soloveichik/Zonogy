import Foundation
import AppKit

/// Handles drag-and-drop of external files/URLs onto placeholders, add-zone indicators, and floating zone indicators.
extension AppController {
    func placeholderReceivedExternalDrop(
        screenId: CGDirectDisplayID,
        zoneIndex: Int,
        items: [ExternalDropItem]
    ) {
        handleExternalDrop(into: zoneKey(for: screenId, index: zoneIndex), items: items, clearExistingOccupant: false, reason: "placeholder-drop")
    }

    func occupiedZoneReceivedExternalDrop(
        screenId: CGDirectDisplayID,
        zoneIndex: Int,
        items: [ExternalDropItem]
    ) {
        handleExternalDrop(into: zoneKey(for: screenId, index: zoneIndex), items: items, clearExistingOccupant: true, reason: "occupied-zone-drop")
    }

    func addZoneIndicatorManager(
        _ manager: AddZoneIndicatorManager,
        didReceiveExternalDrop items: [ExternalDropItem],
        for screenId: CGDirectDisplayID
    ) {
        guard !items.isEmpty else { return }
        if let zone = addZone(on: screenId, announce: false, promoteFloatingOccupant: false) {
            let newZoneKey = zoneKey(for: screenId, index: zone.index)
            targetedZoneManager.setTargetedZone(newZoneKey, reason: "add-zone-drop")
            scheduleActivityRecordingSuppression(reason: "add-zone-drop")
        } else {
            Logger.debug("Add-zone drop requested a new zone on screen \(screenContextStore.loggingIndex(for: screenId)) but creation failed (likely at max zones)")
        }
        openExternalDropItems(items)
    }

    func floatingZoneIndicatorReceivedExternalDrop(screenId: CGDirectDisplayID, items: [ExternalDropItem]) {
        guard !items.isEmpty else { return }
        targetedZoneManager.setFloatingTarget(on: screenId, reason: "floating-zone-drop")
        scheduleActivityRecordingSuppression(reason: "floating-zone-drop")
        openExternalDropItems(items)
    }

    private func handleExternalDrop(
        into zoneKey: ZoneKey,
        items: [ExternalDropItem],
        clearExistingOccupant: Bool,
        reason: String
    ) {
        guard !items.isEmpty else { return }
        let screenIndex = screenContextStore.loggingIndex(for: zoneKey.screenId)
        Logger.debug(
            "Handling external drop into zone \(zoneKey.index) on screen \(screenIndex) " +
            "(clearExistingOccupant: \(clearExistingOccupant), items: \(items.count), reason: \(reason))"
        )

        if clearExistingOccupant,
           let context = screenContexts[zoneKey.screenId],
           let zone = context.zoneController.zone(at: zoneKey.index),
           let windowId = zone.occupantWindowId,
           let managed = windowController.window(withId: windowId) {
            Logger.debug(
                "External drop clearing occupant window \(managed.windowId) from zone \(zoneKey.index) on screen \(screenIndex)"
            )
            let wasManualResizeDetached = performProgrammaticMinimizeCleanup(
                managed,
                minimizeReason: reason,
                cleanupReason: reason,
                retarget: false
            )
            syncWindowsToZones()
            scheduleMinimizeVerification(
                windowId: managed.windowId,
                emptiedZoneKey: zoneKey,
                minimizeReason: reason,
                cleanupReason: reason,
                wasManualResizeDetached: wasManualResizeDetached
            )
        }

        targetedZoneManager.setTargetedZone(zoneKey, reason: reason)
        scheduleActivityRecordingSuppression(reason: reason)
        openExternalDropItems(items)
    }

    private func openExternalDropItems(_ items: [ExternalDropItem]) {
        for item in items {
            if item.url.isFileURL {
                openFileURL(item.url)
                continue
            }

            let scheme = item.url.scheme?.lowercased()
            if scheme == "http" || scheme == "https" {
                openWebLink(item.url)
            } else {
                openGeneralURL(item.url)
            }
        }
    }

    private func openFileURL(_ url: URL) {
        if !NSWorkspace.shared.open(url) {
            Logger.debug("Failed to open dropped file \(url.path)")
        }
    }

    private func openWebLink(_ url: URL) {
        if !browserLaunchController.openNewWindow(with: url) {
            Logger.debug("Failed to open dropped web link \(url.absoluteString) in default browser window")
        }
    }

    private func openGeneralURL(_ url: URL) {
        if !NSWorkspace.shared.open(url) {
            Logger.debug("Failed to open dropped URL \(url.absoluteString)")
        }
    }
}
