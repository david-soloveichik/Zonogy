import Foundation
import AppKit

/// Handles drag-and-drop of external files/URLs onto placeholders and add-zone indicators.
extension AppController {
    func placeholderReceivedExternalDrop(
        screenId: CGDirectDisplayID,
        zoneIndex: Int,
        items: [ExternalDropItem]
    ) {
        guard !items.isEmpty else { return }
        let zoneKey = zoneKey(for: screenId, index: zoneIndex)
        targetedZoneManager.setTargetedZone(zoneKey, reason: "placeholder-drop")
        openExternalDropItems(items)
    }

    func addZoneIndicatorManager(
        _ manager: AddZoneIndicatorManager,
        didReceiveExternalDrop items: [ExternalDropItem],
        for screenId: CGDirectDisplayID
    ) {
        guard !items.isEmpty else { return }
        if let zone = addZone(on: screenId, announce: false) {
            let newZoneKey = zoneKey(for: screenId, index: zone.index)
            targetedZoneManager.setTargetedZone(newZoneKey, reason: "add-zone-drop")
        } else {
            Logger.debug("Add-zone drop requested a new zone on screen \(screenContextStore.loggingIndex(for: screenId)) but creation failed (likely at max zones)")
        }
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
