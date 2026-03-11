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
    }

    func placeholderCoordinator(
        _ coordinator: PlaceholderCoordinator,
        prepareToClose placeholder: PlaceholderWindow,
        reason: PlaceholderCoordinator.CloseReason
    ) {
        let screenIndex = screenContextStore.loggingIndex(for: placeholder.screenDisplayId)
        Logger.debug("Preparing to close placeholder for zone \(placeholder.zoneIndex) on screen \(screenIndex) (reason: \(reason))")
        // PlaceholderWindow.close() is called by PlaceholderCoordinator after this callback.
    }

    // MARK: - PlaceholderManagerDelegate

    func placeholderButtonMode(screenId: CGDirectDisplayID, zoneIndex: Int) -> PlaceholderButtonMode {
        placeholderButtonMode(for: screenId, zoneIndex: zoneIndex)
    }

    func placeholderExternalDragEntered(screenId: CGDirectDisplayID, zoneIndex: Int) {
        showPlaceholderExternalDragOverlay(for: ZoneKey(screenId: screenId, index: zoneIndex), trigger: "entered")
    }

    func placeholderExternalDragUpdated(screenId: CGDirectDisplayID, zoneIndex: Int) {
        showPlaceholderExternalDragOverlay(for: ZoneKey(screenId: screenId, index: zoneIndex), trigger: "updated")
    }

    func placeholderExternalDragExited(screenId: CGDirectDisplayID, zoneIndex: Int) {
        schedulePlaceholderExternalDragOverlayTearDown(
            from: ZoneKey(screenId: screenId, index: zoneIndex),
            reason: "placeholder-drag-exited"
        )
    }

    func suspendPlaceholderExternalDragOverlay(reason: String) {
        guard placeholderExternalDragOverlayKey != nil else {
            return
        }
        Logger.debug("Suspending placeholder external drag overlay (reason: \(reason))")
        tearDownPlaceholderExternalDragOverlay()
    }

    func resumePlaceholderExternalDragOverlayIfNeeded(cursorPoint: CGPoint?) {
        guard !(NSEvent.modifierFlags.contains(.command) && NSEvent.modifierFlags.contains(.control)),
              MouseButtons.isLeftMouseButtonDown(),
              ExternalDropParser.canAccept(NSPasteboard(name: .drag)),
              let cursorPoint,
              let key = resolveEmptyTilingZoneUnderCursor(cursorPoint: cursorPoint),
              placeholderCoordinator.hasPlaceholder(for: key),
              !isScreenPausedForFullScreen(key.screenId) else {
            return
        }

        showPlaceholderExternalDragOverlay(for: key, trigger: "resumed")
    }

    private func showPlaceholderExternalDragOverlay(for key: ZoneKey, trigger: String) {
        placeholderExternalDragOverlayTeardownWorkItem?.cancel()
        placeholderExternalDragOverlayTeardownWorkItem = nil

        guard !(NSEvent.modifierFlags.contains(.command) && NSEvent.modifierFlags.contains(.control)) else {
            tearDownPlaceholderExternalDragOverlay()
            return
        }
        guard !isScreenPausedForFullScreen(key.screenId) else {
            tearDownPlaceholderExternalDragOverlay()
            return
        }

        let screenIndex = screenContextStore.loggingIndex(for: key.screenId)
        if placeholderExternalDragOverlayKey == nil {
            Logger.debug("Showing placeholder external drag overlay for zone \(key.index) on screen \(screenIndex) (trigger: \(trigger))")
            placeholderExternalDragOverlayManager.present(over: externalDropOverlayDescriptors())
        }
        placeholderExternalDragOverlayKey = key
        placeholderExternalDragOverlayManager.updateHighlight(to: key)
    }

    private func schedulePlaceholderExternalDragOverlayTearDown(from key: ZoneKey, reason: String) {
        placeholderExternalDragOverlayTeardownWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.placeholderExternalDragOverlayTeardownWorkItem = nil
            let screenIndex = self.screenContextStore.loggingIndex(for: key.screenId)
            Logger.debug("Hiding placeholder external drag overlay for zone \(key.index) on screen \(screenIndex) (reason: \(reason))")
            self.tearDownPlaceholderExternalDragOverlay()
        }

        placeholderExternalDragOverlayTeardownWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: workItem)
    }

    private func tearDownPlaceholderExternalDragOverlay() {
        placeholderExternalDragOverlayTeardownWorkItem?.cancel()
        placeholderExternalDragOverlayTeardownWorkItem = nil
        placeholderExternalDragOverlayManager.tearDown()
        placeholderExternalDragOverlayKey = nil
    }
}
