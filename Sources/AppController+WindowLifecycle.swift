import Foundation
import AppKit
import ApplicationServices

/// Validation retry callbacks and WindowController delegate bridge (manual moves, resizes, closes).
extension AppController {
    func hasManagedWindows(for pid: pid_t) -> Bool {
        return windowController.allWindows.contains { window in
            if case .accessibility(_, let windowPid, _) = window.backing {
                return windowPid == pid
            }
            return false
        }
    }

    func pruneDestroyedWindowsForPid(_ pid: pid_t) -> [Int] {
        return windowController.pruneDestroyedWindowsForPid(pid)
    }

    func activationWorkaroundIfNeeded(for pid: pid_t, excludingWindowIds: Set<Int>, reason: String) {
        triggerActivationWorkaroundIfNeeded(pid: pid, excludingWindowIds: excludingWindowIds, reason: reason)
    }

    // MARK: - WindowControllerDelegate

    func windowFocusChanged(pid: pid_t) {
        // When focus changes in an application, validate its windows
        // This catches window closures that didn't fire destroy notifications
        _ = validationRetryManager.validateWindowsForApplication(pid: pid, reason: "focus-changed")
    }

    func placeholderCloseRequested(screenId: CGDirectDisplayID, zoneIndex: Int) {
        let screenIndex = screenContextStore.screenIndex(for: screenId) ?? ScreenContextStore.screenIndex(for: screenId) ?? Int(screenId)
        Logger.debug("Placeholder close requested for zone \(zoneIndex) on screen \(screenIndex)")
        _ = performRemoveZone(at: zoneIndex, on: screenId, announce: false)
    }

    func placeholderActivated(screenId: CGDirectDisplayID, zoneIndex: Int) {
        let screenIndex = screenContextStore.screenIndex(for: screenId) ?? ScreenContextStore.screenIndex(for: screenId) ?? Int(screenId)
        Logger.debug("Placeholder activated for zone \(zoneIndex) on screen \(screenIndex)")
        targetedZoneManager.setTargetedZone(zoneKey(for: screenId, index: zoneIndex), reason: "placeholder-activated")
    }

    func zoneIndicatorActivated(_ key: ZoneKey) {
        let screenIndex = screenContextStore.screenIndex(for: key.screenId) ?? ScreenContextStore.screenIndex(for: key.screenId) ?? Int(key.screenId)
        Logger.debug("Zone indicator activated for zone \(key.index) on screen \(screenIndex)")
        targetedZoneManager.setTargetedZone(key, reason: "indicator-clicked")
    }

    // MARK: - AddZoneIndicatorManagerDelegate

    func addZoneIndicatorManager(_ manager: AddZoneIndicatorManager, didClickIndicatorFor screenId: CGDirectDisplayID) {
        let screenIndex = screenContextStore.screenIndex(for: screenId) ?? ScreenContextStore.screenIndex(for: screenId) ?? Int(screenId)
        Logger.debug("Add zone indicator clicked on screen \(screenIndex)")
        addZone(on: screenId)
    }

    func windowWillClose(windowId: Int) {
        Logger.debug("Window \(windowId) will close")
        let managed = windowController.window(withId: windowId)
        if let managed, managed.isPlaceholder {
            placeholderCoordinator.forget(windowId: windowId)
        }
        if dragDropCoordinator.currentDragWindowId == windowId {
            dragDropCoordinator.tearDownDragSession()
        }
        removeWindowFromAllZones(windowId: windowId, reason: "delegate-will-close")
        syncWindowsToZones()
        if let managed,
           case .accessibility(_, let pid, _) = managed.backing {
            triggerActivationWorkaroundIfNeeded(
                pid: pid,
                excludingWindowIds: Set([managed.windowId]),
                reason: "close"
            )
        }
    }

    func windowDidMiniaturize(windowId: Int) {
        Logger.debug("Window \(windowId) did miniaturize")
        let managed = windowController.window(withId: windowId)
        if dragDropCoordinator.currentDragWindowId == windowId {
            dragDropCoordinator.tearDownDragSession()
        }
        removeWindowFromAllZones(windowId: windowId, reason: "delegate-did-miniaturize")
        syncWindowsToZones()
        if let managed,
           case .accessibility(_, let pid, _) = managed.backing {
            triggerActivationWorkaroundIfNeeded(
                pid: pid,
                excludingWindowIds: Set([managed.windowId]),
                reason: "miniaturize"
            )
        }
    }

    func windowDidDeminiaturize(windowId: Int) {
        Logger.debug("Window \(windowId) did deminiaturize")
        guard let managed = windowController.window(withId: windowId) else { return }
        windowPlacementManager.placeNewWindow(managed)
    }

    func placeholderLiveResizeDidBegin(screenId: CGDirectDisplayID, zoneIndex: Int) {
        liveResizingZoneKey = ZoneKey(screenId: screenId, index: zoneIndex)
    }

    func placeholderLiveResized(screenId: CGDirectDisplayID, zoneIndex: Int, to frame: CGRect) {
        let key = ZoneKey(screenId: screenId, index: zoneIndex)
        guard liveResizingZoneKey == key else {
            return
        }

        applyPlaceholderResize(zoneKey: key, placeholderFrame: frame, finalize: false)
    }

    func placeholderLiveResizeDidEnd(screenId: CGDirectDisplayID, zoneIndex: Int, to frame: CGRect) {
        let key = ZoneKey(screenId: screenId, index: zoneIndex)
        if liveResizingZoneKey == key {
            liveResizingZoneKey = nil
        }

        applyPlaceholderResize(zoneKey: key, placeholderFrame: frame, finalize: true)
    }

    func windowManualResizeDidEnd(windowId: Int, screenId: CGDirectDisplayID?, frame: CGRect) {
        if shouldSuppressManualMoveHandling(windowId: windowId, event: "resize") {
            return
        }
        guard let screenId,
              let context = screenContexts[screenId],
              let managed = windowController.window(withId: windowId),
              let zoneIndex = managed.zoneIndex else {
            Logger.debug("Resize completed for window \(windowId) without a zone assignment")
            return
        }

        guard let zone = context.zoneController.zone(at: zoneIndex) else {
            Logger.debug("Zone \(zoneIndex) not found during resize for window \(windowId)")
            return
        }

        let zoneFrame = zoneFrame(fromContentFrame: frame, for: zone, in: context)
        guard context.zoneController.resizeZone(at: zoneIndex, to: zoneFrame, allowOccupied: true) else {
            Logger.debug("Failed to resize zone \(zoneIndex) from window \(windowId)")
            return
        }

        Logger.debug("Applied window-driven resize for zone \(zoneIndex) from window \(windowId)")
        syncWindowsToZones()
    }

    func windowManualMoveDidBegin(windowId: Int, frame: CGRect) {
        if shouldSuppressManualMoveHandling(windowId: windowId, event: "move-begin") {
            return
        }
        guard let managed = windowController.window(withId: windowId), !managed.isPlaceholder else {
            return
        }

        let originZoneKey: ZoneKey?
        if let screenId = managed.screenDisplayId, let zoneIndex = managed.zoneIndex {
            originZoneKey = ZoneKey(screenId: screenId, index: zoneIndex)
        } else {
            originZoneKey = nil
        }

        let originScreenId = managed.screenDisplayId ?? detectScreenId(for: managed)
        dragDropCoordinator.beginDragSession(
            windowId: windowId,
            frame: frame,
            originZoneKey: originZoneKey,
            originScreenId: originScreenId
        )
    }

    func windowManualMoveDidUpdate(windowId: Int, frame: CGRect) {
        if shouldSuppressManualMoveHandling(windowId: windowId, event: "move-update") {
            return
        }
        dragDropCoordinator.updateDragSession(windowId: windowId, frame: frame)
    }

    func windowManualMoveDidEnd(windowId: Int, finalFrame: CGRect) {
        if shouldSuppressManualMoveHandling(windowId: windowId, event: "move-end") {
            return
        }
        let result = dragDropCoordinator.endDragSession(windowId: windowId, finalFrame: finalFrame)

        if let displacedWindow = result.displacedWindow {
            windowPlacementManager.placeNewWindow(displacedWindow, preferredScreenId: result.preferredScreenId)
        }

        syncWindowsToZones()

        if let managed = windowController.window(withId: windowId),
           !managed.isPlaceholder,
           managed.zoneIndex == nil {
            // Window vanished mid-drag; snap it back into regular placement flow.
            windowPlacementManager.placeNewWindow(managed, preferredScreenId: result.preferredScreenId)
        }
    }

    func windowManualMoveDidAbort(windowId: Int) {
        if dragDropCoordinator.currentDragWindowId == windowId {
            // Tear down overlays when the OS/host app ends the drag without a mouse-up.
            dragDropCoordinator.tearDownDragSession()
            syncWindowsToZones()
        }
    }

    func placeholderAllowedResizeAxes(screenId: CGDirectDisplayID, zoneIndex: Int) -> PlaceholderResizeAxes {
        guard let context = screenContexts[screenId],
              let zone = context.zoneController.zone(at: zoneIndex), zone.isEmpty else {
            return []
        }

        let zoneCount = context.zoneController.allZones.count
        return PlaceholderResizePolicy.allowedAxes(
            zoneIndex: zoneIndex,
            zoneCount: zoneCount,
            zoneIsEmpty: zone.isEmpty
        )
    }

    func windowController(_ controller: WindowController, didCaptureExternalWindow window: ManagedWindow) {
        windowPlacementManager.placeNewWindow(window)
    }

    func windowCreationFailedRetryNeeded(forPid pid: pid_t) {
        // When AXWindowCreated fires but we can't capture the window (likely due to .cannotComplete errors),
        // schedule a retry to attempt capturing windows for this PID again
        let bundleId = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        Logger.debug("Scheduling capture retry for pid \(pid) due to failed AXWindowCreated capture")
        capturePipeline.requestRetry(forPid: pid, bundleId: bundleId)
    }

    func screenDescriptor(for screenId: CGDirectDisplayID) -> ScreenDescriptor? {
        descriptor(for: screenId)
    }

    @discardableResult
    internal func captureWindows(
        for application: NSRunningApplication,
        notifyDelegate: Bool,
        allowExisting: Bool
    ) -> [ManagedWindow] {
        let request = WindowCapturePipeline.CaptureRequest(
            application: application,
            notifyDelegate: notifyDelegate,
            allowExisting: allowExisting
        )
        return capturePipeline.capture(request)
    }

}
