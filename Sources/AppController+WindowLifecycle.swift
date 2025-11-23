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
        syncWindowsToZones()
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

        if let managed, isEventSuppressed(windowId: managed.windowId, event: .miniaturized) {
            Logger.debug("Miniaturize notification suppressed for window \(managed.windowId)")
            return
        }

        if dragDropCoordinator.currentDragWindowId == windowId {
            dragDropCoordinator.tearDownDragSession()
        }
        removeWindowFromAllZones(windowId: windowId, reason: "delegate-did-miniaturize", retarget: true)
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

    func windowManualResizeDidEnd(windowId: Int, screenId: CGDirectDisplayID?, frame: CGRect) {
        if shouldSuppressManualMoveHandling(windowId: windowId, event: "resize") {
            return
        }
        
        // Resizing managed windows should not update zone sizes.
        // We just log it. We explicitly DO NOT call syncWindowsToZones() here, allowing
        // the window to remain at its new custom size/position until some other event triggers a sync.
        Logger.debug("Window \(windowId) manual resize ended. Not forcing zone snap.")
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

        displacedWindowCoordinator.resolve(
            result.displacedWindow,
            preferredScreenId: result.preferredScreenId,
            disposition: result.displacedDisposition
        )

        syncWindowsToZones()

        if let managed = windowController.window(withId: windowId),
           !managed.isPlaceholder,
           managed.zoneIndex == nil,
           !isWindowInTemporaryZone(windowId) {
            // Window vanished mid-drag; snap it back into regular placement flow.
            windowPlacementManager.placeNewWindow(managed, preferredScreenId: result.preferredScreenId)
        }

        activeFitResumeAfterDrag(windowId: windowId)
    }

    func windowManualMoveDidAbort(windowId: Int) {
        if temporaryDragHandler.isActive {
            temporaryDragHandler.abortDrag()
            cancelTiledTemporaryConversionIfNeeded(windowId: windowId, reason: "temporary-drag-abort")
            return
        }
        if dragDropCoordinator.currentDragWindowId == windowId {
            // Tear down overlays when the OS/host app ends the drag without a mouse-up.
            dragDropCoordinator.tearDownDragSession()
            syncWindowsToZones()
        }
        activeFitResumeAfterDrag(windowId: windowId)
    }

    func dropWindowIntoTemporaryZone(_ managed: ManagedWindow, from originKey: ZoneKey?, on screenId: CGDirectDisplayID) {
        if let originKey,
           let originContext = screenContexts[originKey.screenId] {
            originContext.zoneController.removeWindow(windowId: managed.windowId)
        }
        clearManagedWindowZone(managed)
        assignWindowToTemporaryZone(managed, on: screenId, centerWindow: true, reason: "drag-to-temporary-zone")
        handleZoneEmptiedByTemporaryDrag(originZoneKey: originKey, reason: "drag-to-temporary-zone")
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

    internal func promoteTiledDragToTemporary(
        windowId: Int,
        frame: CGRect,
        originZoneKey: ZoneKey?,
        originScreenId: CGDirectDisplayID?,
        preferredTemporaryScreenId: CGDirectDisplayID?
    ) -> Bool {
        guard let managed = windowController.window(withId: windowId),
              !temporaryDragHandler.isActive else {
            return false
        }

        let destinationScreenId = preferredTemporaryScreenId
            ?? targetedTemporaryScreenId
            ?? originZoneKey?.screenId
            ?? originScreenId
            ?? detectScreenId(for: managed)
            ?? activeScreenId()

        let displaced = temporaryZoneOccupant(on: destinationScreenId)
        let displacedFrame = displaced.flatMap { captureTemporaryScreenFrame(for: $0, on: destinationScreenId) }

        if let originKey = originZoneKey,
           let originContext = screenContexts[originKey.screenId] {
            originContext.zoneController.removeWindow(windowId: windowId)
        }
        clearManagedWindowZone(managed)

        assignWindowToTemporaryZone(
            managed,
            on: destinationScreenId,
            centerWindow: true,
            reason: "control-command-drag-to-temporary"
        )
        handleZoneEmptiedByTemporaryDrag(originZoneKey: originZoneKey, reason: "control-command-drag-to-temporary")

        temporaryDragHandler.beginDrag(
            windowId: windowId,
            originScreenId: destinationScreenId,
            originZoneKey: originZoneKey,
            requiresControlCommand: true
        )
        temporaryDragHandler.updateDrag(frame: frame)

        tiledToTemporaryDragContexts[windowId] = TiledToTemporaryDragContext(
            originZoneKey: originZoneKey,
            originScreenId: originScreenId,
            temporaryScreenId: destinationScreenId,
            displacedWindowId: displaced?.windowId,
            displacedWindowFrame: displacedFrame
        )

        return true
    }

    private func handleZoneEmptiedByTemporaryDrag(originZoneKey: ZoneKey?, reason: String) {
        guard let originZoneKey,
              let originContext = screenContexts[originZoneKey.screenId],
              originContext.zoneController.zone(at: originZoneKey.index) != nil else {
            return
        }

        targetedZoneManager.setTargetedZone(originZoneKey, reason: reason)
        syncWindowsToZones()
    }

    func revertTemporaryDragToTiled(
        windowId: Int,
        frame: CGRect,
        originZoneKey: ZoneKey?,
        originScreenId: CGDirectDisplayID?
    ) {
        guard let context = tiledToTemporaryDragContexts.removeValue(forKey: windowId),
              let managed = windowController.window(withId: windowId) else {
            return
        }

        reinstateWindowFromTemporaryContext(
            windowId: windowId,
            context: context,
            managed: managed,
            reason: "control-command-release"
        )

        dragDropCoordinator.beginDragSession(
            windowId: windowId,
            frame: frame,
            originZoneKey: context.originZoneKey,
            originScreenId: context.originScreenId,
            originatedFromTemporary: false
        )
        dragDropCoordinator.updateDragSession(windowId: windowId, frame: frame)
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

    func isWindowManagedByActiveFit(windowId: Int) -> Bool {
        // Check if this window is currently being managed by ActiveFit
        return activeFitState?.windowId == windowId
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
        guard let cursorPoint else { return nil }

        let hitAreas = temporaryIndicatorTracker.hitAreas
        if let targeted = targetedTemporaryScreenId,
           let targetedFrame = hitAreas[targeted], targetedFrame.contains(cursorPoint) {
            return targeted
        }

        for (screenId, frame) in hitAreas where frame.contains(cursorPoint) {
            return screenId
        }
        return nil
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

    private func captureTemporaryScreenFrame(for window: ManagedWindow, on screenId: CGDirectDisplayID) -> CGRect? {
        guard let descriptor = descriptor(for: screenId) else {
            return nil
        }
        let actualFrame = window.actualFrame
        let accessibilityFrame: CGRect
        switch window.backing {
        case .appKit:
            accessibilityFrame = CoordinateConversion.cocoaToAccessibility(
                cocoaFrame: actualFrame,
                primaryScreenBounds: primaryScreenBounds
            )
        case .accessibility:
            accessibilityFrame = actualFrame
        }
        return descriptor.accessibilityToScreen(accessibilityFrame)
    }

    private func restoreTemporaryOccupant(from context: TiledToTemporaryDragContext) {
        guard let displacedId = context.displacedWindowId,
              let displaced = windowController.window(withId: displacedId) else {
            return
        }
        windowController.unminimizeWindow(displaced)
        assignWindowToTemporaryZone(
            displaced,
            on: context.temporaryScreenId,
            centerWindow: false,
            reason: "temporary-drag-revert"
        )
        if let frame = context.displacedWindowFrame,
           let descriptor = descriptor(for: context.temporaryScreenId) {
            windowController.showWindow(displaced, at: frame, on: descriptor)
        }
    }

    private func reinstateWindowFromTemporaryContext(
        windowId: Int,
        context: TiledToTemporaryDragContext,
        managed: ManagedWindow,
        reason: String
    ) {
        clearTemporaryZone(for: windowId, minimize: false, reason: reason)
        restoreTemporaryOccupant(from: context)

        if let originKey = context.originZoneKey,
           let originContext = screenContexts[originKey.screenId] {
            originContext.zoneController.assignWindow(windowId: windowId, toZoneIndex: originKey.index)
            setManagedWindow(managed, screenId: originKey.screenId, zoneIndex: originKey.index)
        } else if let screenId = context.originScreenId {
            setManagedWindow(managed, screenId: screenId, zoneIndex: nil)
        }
    }

    internal func cancelTiledTemporaryConversionIfNeeded(windowId: Int, reason: String) {
        guard let context = tiledToTemporaryDragContexts.removeValue(forKey: windowId),
              let managed = windowController.window(withId: windowId) else {
            return
        }
        reinstateWindowFromTemporaryContext(windowId: windowId, context: context, managed: managed, reason: reason)
        syncWindowsToZones()
    }
}