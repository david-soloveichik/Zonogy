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
        prepareToShow placeholder: PlaceholderWindow,
        at frame: CGRect,
        on descriptor: ScreenDescriptor
    ) {
        let screenIndex = screenContextStore.loggingIndex(for: descriptor.displayId)
        Logger.debug("Preparing to show placeholder for zone \(placeholder.zoneIndex) on screen \(screenIndex)")

        Logger.debug("Showing placeholder using show()")
        placeholder.show(at: frame, on: descriptor)
        placeholder.screenDisplayId = descriptor.displayId
    }

    func placeholderCoordinator(
        _ coordinator: PlaceholderCoordinator,
        prepareToHide placeholder: PlaceholderWindow,
        reason: PlaceholderCoordinator.HideReason
    ) {
        let screenIndex = screenContextStore.loggingIndex(for: placeholder.screenDisplayId)
        Logger.debug("Preparing to hide placeholder for zone \(placeholder.zoneIndex) on screen \(screenIndex) (reason: \(reason))")
        // Placeholder's hide() is called by PlaceholderCoordinator after this callback
    }

    // MARK: - PlaceholderManagerDelegate

    func placeholderButtonMode(screenId: CGDirectDisplayID, zoneIndex: Int) -> PlaceholderButtonMode {
        placeholderButtonMode(for: screenId, zoneIndex: zoneIndex)
    }
}
