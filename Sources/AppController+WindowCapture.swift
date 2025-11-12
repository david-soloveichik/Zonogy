import Foundation
import AppKit
import ApplicationServices

/// Bridges window capture pipeline and placeholder coordination back to AppController.
extension AppController {
    func capturePipeline(_ pipeline: WindowCapturePipeline, shouldManage application: NSRunningApplication) -> Bool {
        shouldManage(application: application)
    }

    // MARK: - PlaceholderCoordinatorDelegate

    func placeholderCoordinator(
        _ coordinator: PlaceholderCoordinator,
        prepareToShow placeholder: ManagedWindow,
        at frame: CGRect,
        on descriptor: ScreenDescriptor,
        isExcluded: Bool
    ) {
        let screenIndex = screenContextStore.loggingIndex(for: descriptor.displayId)
        Logger.debug("Preparing to show placeholder window \(placeholder.windowId) for zone \(placeholder.zoneIndex ?? -1) on screen \(screenIndex) (excluded: \(isExcluded))")

        if isExcluded {
            Logger.debug("Bringing excluded placeholder \(placeholder.windowId) to front using orderFront")
            placeholder.appKitWindow?.orderFront(nil)
        } else {
            Logger.debug("Showing placeholder \(placeholder.windowId) using showWindow")
            windowController.showWindow(placeholder, at: frame, on: descriptor)
            windowController.moveWindow(placeholder, to: frame, on: descriptor)
        }
        placeholder.screenDisplayId = descriptor.displayId
        if let zoneIndex = placeholder.zoneIndex {
            setManagedWindow(placeholder, screenId: descriptor.displayId, zoneIndex: zoneIndex)
            let zoneKey = ZoneKey(screenId: descriptor.displayId, index: zoneIndex)
            if shouldRetarget(to: zoneKey) {
                targetedZoneManager.setTargetedZone(zoneKey, reason: "placeholder-shown")
            }
        }
    }

    func placeholderCoordinator(
        _ coordinator: PlaceholderCoordinator,
        prepareToHide placeholder: ManagedWindow,
        reason: PlaceholderCoordinator.HideReason
    ) {
        let screenIndex = placeholder.screenDisplayId.map { screenContextStore.loggingIndex(for: $0) } ?? -1
        Logger.debug("Preparing to hide placeholder window \(placeholder.windowId) for zone \(placeholder.zoneIndex ?? -1) on screen \(screenIndex) (reason: \(reason))")

        switch reason {
        case .replacedByWindow:
            Logger.debug("Closing placeholder \(placeholder.windowId) - replaced by actual window")
            windowController.closeWindow(placeholder)
        case .idle:
            Logger.debug("Hiding idle placeholder \(placeholder.windowId) using orderOut")
            placeholder.appKitWindow?.orderOut(nil)
        }
    }

    func placeholderCoordinator(_ coordinator: PlaceholderCoordinator, didResizeZone key: ZoneKey, finalize: Bool) {
        if finalize {
            let screenIndex = screenContextStore.loggingIndex(for: key.screenId)
            Logger.debug("Placeholder for zone \(key.index) on screen \(screenIndex) resize finalized")
            syncWindowsToZones()
        } else {
            syncWindowsToZones(excluding: Set([key]))
        }
    }

    func placeholderCoordinator(_ coordinator: PlaceholderCoordinator, clearManagedZoneFor managed: ManagedWindow) {
        clearManagedWindowZone(managed)
    }

}
