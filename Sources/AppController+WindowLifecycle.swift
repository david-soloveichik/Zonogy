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

    func windowFocusChanged(pid: pid_t, focusedWindowId: Int?) {
        // When focus changes in an application, validate its windows
        // This catches window closures that didn't fire destroy notifications
        _ = validationRetryManager.validateWindowsForApplication(pid: pid, reason: "focus-changed")
        handleActiveFitFocusChange(pid: pid)
        handleTemporaryZoneFocusChange(pid: pid, focusedWindowId: focusedWindowId)
    }

    func placeholderCloseRequested(screenId: CGDirectDisplayID, zoneIndex: Int) {
        let screenIndex = screenContextStore.loggingIndex(for: screenId)
        Logger.debug("Placeholder close requested for zone \(zoneIndex) on screen \(screenIndex)")
        _ = performRemoveZone(at: zoneIndex, on: screenId, announce: false)
    }

    func placeholderActivated(screenId: CGDirectDisplayID, zoneIndex: Int) {
        let screenIndex = screenContextStore.loggingIndex(for: screenId)
        Logger.debug("Placeholder activated for zone \(zoneIndex) on screen \(screenIndex)")
        minimizeTemporaryZoneOccupant(on: screenId, reason: "placeholder-activated")
        targetedZoneManager.setTargetedZone(zoneKey(for: screenId, index: zoneIndex), reason: "placeholder-activated")
    }

    func zoneIndicatorActivated(_ key: ZoneKey) {
        let screenIndex = screenContextStore.loggingIndex(for: key.screenId)
        Logger.debug("Zone indicator activated for zone \(key.index) on screen \(screenIndex)")
        targetedZoneManager.setTargetedZone(key, reason: "indicator-clicked")
    }

    func temporaryZoneIndicatorActivated(screenId: CGDirectDisplayID) {
        let screenIndex = screenContextStore.loggingIndex(for: screenId)
        Logger.debug("Temporary zone indicator activated on screen \(screenIndex)")
        targetedZoneManager.setTemporaryTarget(on: screenId, reason: "temporary-indicator-clicked")
    }

    // MARK: - AddZoneIndicatorManagerDelegate

    func addZoneIndicatorManager(_ manager: AddZoneIndicatorManager, didClickIndicatorFor screenId: CGDirectDisplayID) {
        let screenIndex = screenContextStore.loggingIndex(for: screenId)
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
        activeFitClearForWindowIfNeeded(windowId: windowId, restoreToZone: false, reason: "close")
        activeFitClearSuppressionForWindow(windowId)
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
        activeFitClearForWindowIfNeeded(windowId: windowId, restoreToZone: false, reason: "miniaturize")
        activeFitClearSuppressionForWindow(windowId)
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
        let screenIndex = screenContextStore.loggingIndex(for: screenId)
        Logger.debug("Placeholder live resize began for zone \(zoneIndex) on screen \(screenIndex) (depth=\(windowController.placeholderLiveResizeDepth))")
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

        let screenIndex = screenContextStore.loggingIndex(for: screenId)
        Logger.debug("Placeholder live resize ended for zone \(zoneIndex) on screen \(screenIndex) (depth=\(windowController.placeholderLiveResizeDepth), finalFrame: \(frame))")

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

        if isWindowInTemporaryZone(windowId) && !isControlCommandDragActive() {
            let tempScreenId = managed.screenDisplayId ?? detectScreenId(for: managed)
            temporaryDragHandler.beginDrag(windowId: windowId, originScreenId: tempScreenId)
            Logger.debug("Floating temporary zone drag began for window \(windowId)")
            return
        }

        let originZoneKey = zoneKey(forManagedWindow: managed)

        activeFitSuspendForDrag(windowId: windowId)

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
        if temporaryDragHandler.isActive {
            temporaryDragHandler.updateDrag(frame: frame)
            return
        }
        dragDropCoordinator.updateDragSession(windowId: windowId, frame: frame)
    }

    func windowManualMoveDidEnd(windowId: Int, finalFrame: CGRect) {
        if shouldSuppressManualMoveHandling(windowId: windowId, event: "move-end") {
            return
        }
        if temporaryDragHandler.isActive {
            temporaryDragHandler.endDrag(finalFrame: finalFrame)
            activeFitResumeAfterDrag(windowId: windowId)
            return
        }
        let result = dragDropCoordinator.endDragSession(windowId: windowId, finalFrame: finalFrame)

        resolveDisplacedWindow(result.displacedWindow, preferredScreenId: result.preferredScreenId)

        syncWindowsToZones()

        if let managed = windowController.window(withId: windowId),
           !managed.isPlaceholder,
           managed.zoneIndex == nil {
            // Window vanished mid-drag; snap it back into regular placement flow.
            windowPlacementManager.placeNewWindow(managed, preferredScreenId: result.preferredScreenId)
        }

        activeFitResumeAfterDrag(windowId: windowId)
    }

    func windowManualMoveDidAbort(windowId: Int) {
        if temporaryDragHandler.isActive {
            temporaryDragHandler.abortDrag()
            return
        }
        if dragDropCoordinator.currentDragWindowId == windowId {
            // Tear down overlays when the OS/host app ends the drag without a mouse-up.
            dragDropCoordinator.tearDownDragSession()
            syncWindowsToZones()
        }
        activeFitResumeAfterDrag(windowId: windowId)
    }

    internal func resolveDisplacedWindow(_ displacedWindow: ManagedWindow?, preferredScreenId: CGDirectDisplayID?) {
        guard let displacedWindow else { return }
        if hasAvailableTiledZone() {
            windowPlacementManager.placeNewWindow(displacedWindow, preferredScreenId: preferredScreenId)
        } else {
            let screenId = targetedTemporaryScreenId ?? preferredScreenId ?? activeScreenId()
            assignWindowToTemporaryZone(
                displacedWindow,
                on: screenId,
                centerWindow: true,
                reason: "displaced-no-empty-zones"
            )
        }
    }

    func dropWindowIntoTemporaryZone(_ managed: ManagedWindow, from originKey: ZoneKey?, on screenId: CGDirectDisplayID) {
        if let originKey,
           let originContext = screenContexts[originKey.screenId] {
            originContext.zoneController.removeWindow(windowId: managed.windowId)
        }
        clearManagedWindowZone(managed)
        assignWindowToTemporaryZone(managed, on: screenId, centerWindow: true, reason: "drag-to-temporary-zone")
    }

    internal func promoteFloatingDragToZone(windowId: Int, frame: CGRect, originScreenId: CGDirectDisplayID?) {
        promoteFloatingDragToTiledDrag(windowId: windowId, frame: frame, originTemporaryScreenId: originScreenId)
    }

    private func promoteFloatingDragToTiledDrag(windowId: Int, frame: CGRect, originTemporaryScreenId: CGDirectDisplayID?) {
        guard let managed = windowController.window(withId: windowId) else {
            return
        }
        clearTemporaryZone(for: windowId, minimize: false, reason: "control-command-drag")
        activeFitSuspendForDrag(windowId: windowId)
        updateAddZoneIndicatorHighlight(screenId: nil)
        updateTemporaryIndicatorHighlight(screenId: nil)
        let originScreenId = originTemporaryScreenId ?? managed.screenDisplayId ?? detectScreenId(for: managed)
        dragDropCoordinator.beginDragSession(
            windowId: windowId,
            frame: frame,
            originZoneKey: nil,
            originScreenId: originScreenId,
            originatedFromTemporary: true
        )
        dragDropCoordinator.updateDragSession(windowId: windowId, frame: frame)
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

    func debugTargetedZoneDescription() -> String? {
        if let temporaryScreenId = targetedTemporaryScreenId {
            let screenIndex = screenContextStore.loggingIndex(for: temporaryScreenId)
            return "temporary zone on screen \(screenIndex)"
        }
        guard let key = targetedZoneManager.targetedZoneKey else {
            return "none"
        }

        let screenIndex = screenContextStore.loggingIndex(for: key.screenId)

        guard let context = screenContexts[key.screenId],
              let zone = context.zoneController.zone(at: key.index) else {
            return "screen \(screenIndex) zone \(key.index) (unavailable)"
        }

        let occupancy = zone.isEmpty ? "empty" : "occupied"
        return "screen \(screenIndex) zone \(key.index) (\(occupancy))"
    }

    internal func isControlCommandDragActive() -> Bool {
        let flags = NSEvent.modifierFlags
        return flags.contains(.command) && flags.contains(.control)
    }

    internal func currentCursorAccessibilityPoint() -> CGPoint? {
        let cocoaLocation = NSEvent.mouseLocation
        let cocoaPoint = CGPoint(x: cocoaLocation.x, y: cocoaLocation.y)
        let cocoaFrame = CGRect(origin: cocoaPoint, size: .zero)
        return CoordinateConversion.cocoaToAccessibility(
            cocoaFrame: cocoaFrame,
            primaryScreenBounds: windowController.primaryScreenBounds
        ).origin
    }

    internal func resolveAddZoneDropTarget(cursorPoint: CGPoint?) -> CGDirectDisplayID? {
        guard let cursorPoint else { return nil }
        for (screenId, frame) in addIndicatorTracker.hitAreas where frame.contains(cursorPoint) {
            return screenId
        }
        return nil
    }

    internal func resolveTemporaryDropTarget(cursorPoint: CGPoint?) -> CGDirectDisplayID? {
        guard let cursorPoint,
              let targetScreen = targetedTemporaryScreenId,
              let frame = temporaryIndicatorTracker.hitAreas[targetScreen] else {
            return nil
        }
        return frame.contains(cursorPoint) ? targetScreen : nil
    }

}

// MARK: - DragDropCoordinatorDelegate (temporary re-entry)

extension AppController {
    func resumeTemporaryDrag(windowId: Int, frame: CGRect, originScreenId: CGDirectDisplayID?) {
        guard let managed = windowController.window(withId: windowId) else {
            return
        }
        let screenId = originScreenId ?? detectScreenId(for: managed) ?? activeScreenId()
        assignWindowToTemporaryZone(
            managed,
            on: screenId,
            centerWindow: false,
            reason: "control-command-release"
        )
        temporaryDragHandler.beginDrag(windowId: windowId, originScreenId: screenId)
        temporaryDragHandler.updateDrag(frame: frame)
    }
}
