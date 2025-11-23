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
            Logger.debug("Hiding excluded placeholder \(placeholder.windowId) using hideWindow")
            windowController.hideWindow(placeholder, reason: .zoneExcluded)
            return
        }

        Logger.debug("Showing placeholder \(placeholder.windowId) using ensurePlaceholderVisibilityAndPosition")
        windowController.ensurePlaceholderVisibilityAndPosition(placeholder, at: frame, on: descriptor)
        placeholder.screenDisplayId = descriptor.displayId
        if let zoneIndex = placeholder.zoneIndex {
            setManagedWindow(placeholder, screenId: descriptor.displayId, zoneIndex: zoneIndex)
        }
    }

    func placeholderCoordinator(
        _ coordinator: PlaceholderCoordinator,
        prepareToHide placeholder: ManagedWindow,
        reason: PlaceholderCoordinator.HideReason
    ) {
        let screenIndex = placeholder.screenDisplayId.map { screenContextStore.loggingIndex(for: $0) } ?? -1
        Logger.debug("Preparing to hide placeholder window \(placeholder.windowId) for zone \(placeholder.zoneIndex ?? -1) on screen \(screenIndex) (reason: \(reason))")

        let hideReason: WindowController.HideReason
        switch reason {
        case .replacedByWindow:
            hideReason = .replacedByOccupant
        case .idle:
            hideReason = .inactiveZone
        }
        Logger.debug("Hiding placeholder \(placeholder.windowId) (reason: \(hideReason))")
        windowController.hideWindow(placeholder, reason: hideReason)
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
