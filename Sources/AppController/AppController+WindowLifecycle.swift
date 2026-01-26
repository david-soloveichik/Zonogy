import Foundation
import AppKit
import ApplicationServices

/// Validation retry callbacks and WindowController delegate bridge (manual moves, resizes, closes).
extension AppController {
    func hasManagedWindows(for pid: pid_t) -> Bool {
        return windowController.allWindows.contains { $0.backing.pid == pid }
    }

    func debugManagedWindowIds(for pid: pid_t) -> [Int] {
        return windowController.allWindows
            .filter { $0.backing.pid == pid }
            .map { $0.windowId }
            .sorted()
    }

    func pruneDestroyedWindowsForPid(_ pid: pid_t) -> [Int] {
        return windowController.pruneDestroyedWindowsForPid(pid)
    }

    func handleDestroyedWindow(
        windowId: Int,
        reason: String,
        retarget: Bool = true,
        shouldSync: Bool = true,
        shouldRefreshWinShotChooser: Bool = true
    ) {
        handleDestroyedWindows(
            [windowId],
            reason: reason,
            retarget: retarget,
            shouldSync: shouldSync,
            shouldRefreshWinShotChooser: shouldRefreshWinShotChooser
        )
    }

    func handleDestroyedWindows(
        _ windowIds: [Int],
        reason: String,
        retarget: Bool
    ) {
        handleDestroyedWindows(
            windowIds,
            reason: reason,
            retarget: retarget,
            shouldSync: true,
            shouldRefreshWinShotChooser: true
        )
    }

    func handleDestroyedWindows(
        _ windowIds: [Int],
        reason: String,
        retarget: Bool,
        shouldSync: Bool,
        shouldRefreshWinShotChooser: Bool
    ) {
        guard !windowIds.isEmpty else { return }

        for windowId in windowIds {
            performDestroyedWindowPreSyncCleanup(windowId: windowId, reason: reason, retarget: retarget)
        }

        if shouldRefreshWinShotChooser, let chooserScreenId = winShotChooserController.currentScreenId {
            refreshWinShotChooserIfNeeded(for: chooserScreenId)
        }

        if shouldSync {
            syncWindowsToZones()
        }

        for windowId in windowIds {
            performDestroyedWindowPostSyncCleanup(windowId: windowId)
        }
    }

    private func performDestroyedWindowPreSyncCleanup(windowId: Int, reason: String, retarget: Bool) {
        if let workItem = fullScreenCheckWorkItemsByWindowId.removeValue(forKey: windowId) {
            workItem.cancel()
        }

        // Notify full-screen tracker before cleanup
        if let managed = windowController.window(withId: windowId) {
            fullScreenElementCache.removeValue(forKey: AccessibilityElementKey(element: managed.backing.element))
            notifyFullScreenTrackerOfWindowClose(
                cgWindowId: CGWindowID(managed.backing.cgWindowId),
                pid: managed.backing.pid
            )
        } else {
            notifyFullScreenTrackerOfWindowClose(windowId: windowId)
        }

        if currentFrontmostManagedWindowId == windowId {
            currentFrontmostManagedWindowId = nil
        }
        manualResizeDetachedWindowIds.remove(windowId)
        selfResizeSnapDebouncer.clear(windowId: windowId)

        removeWindowFromAllZones(windowId: windowId, reason: reason, retarget: retarget)

        // WinShot: Remove any snapshots containing this window
        winShotManager.removeSnapshotsContaining(windowId: windowId)
    }

    private func performDestroyedWindowPostSyncCleanup(windowId: Int) {
        clearRevealModeForWindow(windowId: windowId, transitionToRest: false, reason: "close")
        activeFitClearSuppressionForWindow(windowId)
    }

    // MARK: - WindowControllerDelegate

    func windowFocusChanged(pid: pid_t, focusedWindowId: Int?) {
        // AX focus notifications can fire after screens go to sleep; ignore them to
        // avoid incorrect pruning of windows when AX APIs return transient errors.
        if shouldIgnoreDueToSleepWake(event: "windowFocusChanged(pid: \(pid))") {
            return
        }

        let activitySuppressed = isActivityRecordingSuppressed()
        if focusedWindowId == nil || activitySuppressed {
            let bundleId = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "unknown"
            if let windowId = focusedWindowId,
               let managed = windowController.window(withId: windowId) {
                let resolvedScreenId = managed.screenDisplayId ?? detectScreenId(for: managed)
                let screenDescription = resolvedScreenId.map { screenContextStore.logDescription(for: $0) } ?? "unknown-screen"
                let zoneDescription = managed.zoneIndex.map(String.init) ?? "none"
                let tempDescription = isWindowInTemporaryZone(windowId) ? "temporary" : "not-temporary"
                Logger.debug(
                    "windowFocusChanged: pid \(pid) (bundle: \(bundleId)) focusedWindowId=\(windowId) zone=\(zoneDescription) temp=\(tempDescription) \(screenDescription) (activitySuppressed: \(activitySuppressed))"
                )
            } else {
                Logger.debug(
                    "windowFocusChanged: pid \(pid) (bundle: \(bundleId)) focusedWindowId=nil (activitySuppressed: \(activitySuppressed))"
                )
            }
        }

        // Dismiss Launcher if focus shifts to a managed window in a zone (tiled or temporary).
        if let windowId = focusedWindowId,
           let managed = windowController.window(withId: windowId),
           (managed.zoneIndex != nil || isWindowInTemporaryZone(windowId)) {
            dismissLauncherIfActiveRespectingAutoShowGrace()
        }

        // When focus changes in an application, validate its windows
        // This catches window closures that didn't fire destroy notifications
        _ = validationRetryManager.validateWindowsForApplication(pid: pid, reason: "focus-changed")
        handleActiveFitFocusChange(pid: pid)
        handleTemporaryZoneFocusChange(pid: pid, focusedWindowId: focusedWindowId)
        handleManualResizeFocusChange(pid: pid, focusedWindowId: focusedWindowId)

        // Record window activity for launcher recency ordering
        // Skip during activity suppression to avoid twitchy recordings during temp zone/WinShot operations
        if let windowId = focusedWindowId, !isActivityRecordingSuppressed() {
            recordActiveWindowForHistory(windowId: windowId, reason: "focus-changed")
        }

        // Track frontmost managed window for AltTab initial selection (no AX call needed at show time)
        currentFrontmostManagedWindowId = focusedWindowId

        updateUnmanagedFocusState()
    }

    func placeholderCloseRequested(screenId: CGDirectDisplayID, zoneIndex: Int) {
        let screenIndex = screenContextStore.loggingIndex(for: screenId)
        Logger.debug("Placeholder close requested for zone \(zoneIndex) on screen \(screenIndex)")

        // UnderCovers: when this screen has exactly one tiling zone (zone 1) and it is empty,
        // treat the close button as a temporary put-away of the placeholder instead of removing the zone.
        if placeholderButtonMode(for: screenId, zoneIndex: zoneIndex) == .underCovers {
            Logger.debug("Placeholder close mapped to UnderCovers put-away on screen \(screenIndex)")
            beginUnderCoversIfEligible(on: screenId, zoneIndex: zoneIndex, reason: "placeholder-close")
            return
        }

        // Defer zone removal to the next run loop tick. Zone removal triggers a sync that can close
        // and recreate placeholder windows; doing that while AppKit is still unwinding the click
        // tracking can leave the UI in a flaky state.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            _ = self.performRemoveZone(at: zoneIndex, on: screenId, announce: false)
        }
    }

    func placeholderActivated(screenId: CGDirectDisplayID, zoneIndex: Int, mouseDownTimestamp: TimeInterval) {
        if isScreenPausedForFullScreen(screenId) {
            Logger.debug("Placeholder activated on full-screen screen \(screenContextStore.loggingIndex(for: screenId)); ignoring")
            return
        }
        let screenIndex = screenContextStore.loggingIndex(for: screenId)
        Logger.debug("Placeholder activated for zone \(zoneIndex) on screen \(screenIndex)")
        recordZoneUiMouseDown(mouseDownTimestamp: mouseDownTimestamp)
        refreshResizeHandles()
        minimizeTemporaryZoneOccupant(on: screenId, reason: "placeholder-activated")
        targetedZoneManager.setTargetedZone(zoneKey(for: screenId, index: zoneIndex), reason: "placeholder-activated")
    }

    func placeholderSearchPillClicked(screenId: CGDirectDisplayID, zoneIndex: Int) {
        if isScreenPausedForFullScreen(screenId) {
            Logger.debug("Placeholder search pill clicked on full-screen screen \(screenContextStore.loggingIndex(for: screenId)); ignoring")
            return
        }
        let screenIndex = screenContextStore.loggingIndex(for: screenId)
        Logger.debug("Placeholder search pill clicked for zone \(zoneIndex) on screen \(screenIndex)")

        minimizeTemporaryZoneOccupant(on: screenId, reason: "placeholder-search-pill")
        let key = zoneKey(for: screenId, index: zoneIndex)
        targetedZoneManager.setTargetedZone(key, reason: "placeholder-search-pill")

        // Clicking the search pill should always show the Launcher, even if the zone was already targeted.
        showLauncherIfAllowed(trigger: "placeholder-search-pill")
    }

    func zoneIndicatorActivated(_ key: ZoneKey, wasAlreadyTargeted: Bool, isDoubleClick: Bool) {
        if isScreenPausedForFullScreen(key.screenId) {
            Logger.debug("Zone indicator activated on full-screen screen \(screenContextStore.loggingIndex(for: key.screenId)); ignoring")
            return
        }
        let screenIndex = screenContextStore.loggingIndex(for: key.screenId)
        Logger.debug("Zone indicator activated for zone \(key.index) on screen \(screenIndex) (wasAlreadyTargeted: \(wasAlreadyTargeted), isDoubleClick: \(isDoubleClick))")
        targetedZoneManager.setTargetedZone(key, reason: "indicator-clicked")

        if isDoubleClick || wasAlreadyTargeted {
            showLauncherIfAllowed(trigger: "indicator-clicked")
        }
    }

    func temporaryZoneIndicatorActivated(screenId: CGDirectDisplayID, wasAlreadyTargeted: Bool, isDoubleClick: Bool) {
        if isScreenPausedForFullScreen(screenId) {
            Logger.debug("Temporary indicator activated on full-screen screen \(screenContextStore.loggingIndex(for: screenId)); ignoring")
            return
        }
        let screenIndex = screenContextStore.loggingIndex(for: screenId)
        Logger.debug("Temporary zone indicator activated on screen \(screenIndex) (wasAlreadyTargeted: \(wasAlreadyTargeted), isDoubleClick: \(isDoubleClick))")
        targetedZoneManager.setTemporaryTarget(on: screenId, reason: "temporary-indicator-clicked")

        if isDoubleClick || wasAlreadyTargeted {
            showLauncherIfAllowed(trigger: "temporary-indicator-clicked")
        }
    }

    // MARK: - AddZoneIndicatorManagerDelegate

    func addZoneIndicatorManager(_ manager: AddZoneIndicatorManager, didClickIndicatorFor screenId: CGDirectDisplayID) {
        if isScreenPausedForFullScreen(screenId) {
            Logger.debug("Add zone indicator clicked on full-screen screen \(screenContextStore.loggingIndex(for: screenId)); ignoring")
            return
        }
        let screenIndex = screenContextStore.loggingIndex(for: screenId)
        Logger.debug("Add zone indicator clicked on screen \(screenIndex)")
        addZone(on: screenId)
    }

    func windowWillClose(windowId: Int) {
        if shouldIgnoreDueToSleepWake(event: "windowWillClose(\(windowId))") {
            return
        }
        Logger.debug("Window \(windowId) will close")

        handleDestroyedWindow(windowId: windowId, reason: "delegate-will-close")
    }

    func windowDidMiniaturize(windowId: Int) {
        if shouldIgnoreDueToSleepWake(event: "windowDidMiniaturize(\(windowId))") {
            return
        }
        Logger.debug("Window \(windowId) did miniaturize")
        if currentFrontmostManagedWindowId == windowId {
            currentFrontmostManagedWindowId = nil
        }
        manualResizeDetachedWindowIds.remove(windowId)
        selfResizeSnapDebouncer.clear(windowId: windowId)
        let managed = windowController.window(withId: windowId)

        if let managed, isEventSuppressed(windowId: managed.windowId, event: .miniaturized) {
            Logger.debug("Miniaturize notification suppressed for window \(managed.windowId)")
            return
        }

        if dragDropCoordinator.currentDragWindowId == windowId {
            dragDropCoordinator.tearDownDragSession()
        }
        removeWindowFromAllZones(windowId: windowId, reason: "delegate-did-miniaturize", retarget: true)
        // Sync handles temporary zone promotion automatically
        syncWindowsToZones()

        clearRevealModeForWindow(windowId: windowId, transitionToRest: false, reason: "miniaturize")
        activeFitClearSuppressionForWindow(windowId)
    }

    func windowDidDeminiaturize(windowId: Int) {
        if shouldIgnoreDueToSleepWake(event: "windowDidDeminiaturize(\(windowId))") {
            return
        }
        Logger.debug("Window \(windowId) did deminiaturize")
        if isEventSuppressed(windowId: windowId, event: .deminiaturized) {
            Logger.debug("Deminiaturize notification suppressed for window \(windowId)")
            return
        }
        guard let managed = windowController.window(withId: windowId) else { return }
        windowPlacementManager.placeNewWindow(managed)
    }

    func windowManualResizeDidEnd(windowId: Int, screenId: CGDirectDisplayID?, frame: CGRect) {
        if shouldIgnoreDueToSleepWake(event: "windowManualResizeDidEnd(\(windowId))") {
            return
        }
        if shouldSuppressManualMoveHandling(windowId: windowId, event: "resize") {
            return
        }

        guard let managed = windowController.window(withId: windowId),
              let zoneIndex = managed.zoneIndex else {
            Logger.debug("Window \(windowId) manual resize ended outside tiled zone; ignoring snapback tracking")
            manualResizeDetachedWindowIds.remove(windowId)
            return
        }

        let resolvedScreenId: CGDirectDisplayID? = {
            if let screenId {
                return screenId
            }
            return managed.screenDisplayId ?? detectScreenId(for: managed)
        }()

        if handleSelfResizeSnapIfNeeded(
            managed: managed,
            screenId: resolvedScreenId,
            zoneIndex: zoneIndex,
            reportedFrame: frame
        ) {
            return
        }

        manualResizeDetachedWindowIds.insert(windowId)

        if let resolvedScreenId {
            let screenIndex = screenContextStore.loggingIndex(for: resolvedScreenId)
            Logger.debug("Window \(windowId) manual resize ended in zone \(zoneIndex) on screen \(screenIndex); deferring snapback until layout sync or focus loss")
        } else {
            Logger.debug("Window \(windowId) manual resize ended in zone \(zoneIndex) on unknown screen; deferring snapback until layout sync or focus loss")
        }
    }

    private func handleSelfResizeSnapIfNeeded(
        managed: ManagedWindow,
        screenId: CGDirectDisplayID?,
        zoneIndex: Int,
        reportedFrame: CGRect
    ) -> Bool {
        guard shouldSnapToZoneOnSelfResize(managed: managed) else {
            return false
        }

        guard let screenId,
              let context = screenContexts[screenId],
              let descriptor = descriptor(for: screenId),
              let zone = context.zoneController.zone(at: zoneIndex) else {
            return false
        }

        // If the user manually resized this window earlier, preserve that detached
        // state until focus loss / layout sync clears it (simplest behavior).
        if manualResizeDetachedWindowIds.contains(managed.windowId) {
            let screenIndex = screenContextStore.loggingIndex(for: screenId)
            Logger.debug(
                "Self-resize snap skipped for window \(managed.windowId) in zone \(zone.index) on screen \(screenIndex) (reason: manually-detached)"
            )
            return true
        }

        // If the cursor is near the window border and the left button is down (or just went up),
        // assume this resize came from a user edge drag and keep the existing detach semantics.
        let cursorPoint = currentCursorScreenPoint(on: descriptor)
        let isLikelyUserResize = WindowResizeHeuristics.isLikelyUserEdgeDragResize(
            cursorPoint: cursorPoint,
            windowFrame: reportedFrame,
            edgeProximity: userResizeEdgeProximityThreshold,
            leftMouseButtonDown: MouseButtons.isLeftMouseButtonDown(),
            secondsSinceLeftMouseUp: MouseButtons.secondsSinceLastLeftMouseUp(),
            mouseUpGrace: userResizeMouseUpGraceInterval
        )
        if isLikelyUserResize {
            let screenIndex = screenContextStore.loggingIndex(for: screenId)
            Logger.debug(
                "Self-resize snap not applied for window \(managed.windowId) in zone \(zone.index) on screen \(screenIndex) (reason: likely-user-edge-drag)"
            )
            return false
        }

        let targetFrame = frameWithMargin(for: zone, in: context.zoneController)
        guard selfResizeSnapDebouncer.shouldAllow(windowId: managed.windowId, targetFrame: targetFrame) else {
            let screenIndex = screenContextStore.loggingIndex(for: screenId)
            Logger.debug(
                "Self-resize snap debounced for window \(managed.windowId) in zone \(zone.index) on screen \(screenIndex)"
            )
            return true
        }

        let screenIndex = screenContextStore.loggingIndex(for: screenId)
        Logger.debug("Self-resize snap: moving window \(managed.windowId) to zone \(zone.index) on screen \(screenIndex)")
        windowController.moveWindow(managed, to: targetFrame, on: descriptor)
        activeFitHandleAssignmentChange(managed: managed, screenId: screenId, zoneIndex: zoneIndex)
        return true
    }

    private func shouldSnapToZoneOnSelfResize(managed: ManagedWindow) -> Bool {
        guard let bundleId = NSRunningApplication(processIdentifier: managed.backing.pid)?.bundleIdentifier else {
            return false
        }
        return windowController.applicationExceptionPolicy.snapsToZoneOnSelfResize(forBundleIdentifier: bundleId)
    }

    private func currentCursorScreenPoint(on descriptor: ScreenDescriptor) -> CGPoint {
        let cocoaPoint = NSEvent.mouseLocation
        let cocoaFrame = CGRect(origin: cocoaPoint, size: .zero)
        return descriptor.cocoaToScreen(cocoaFrame).origin
    }

    func windowManualMoveDidBegin(windowId: Int, frame: CGRect) {
        if shouldIgnoreDueToSleepWake(event: "windowManualMoveDidBegin(\(windowId))") {
            return
        }
        if shouldSuppressManualMoveHandling(windowId: windowId, event: "move-begin") {
            return
        }
        guard let managed = windowController.window(withId: windowId) else {
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
        if shouldIgnoreDueToSleepWake(event: "windowManualMoveDidUpdate(\(windowId))") {
            return
        }
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
        if shouldIgnoreDueToSleepWake(event: "windowManualMoveDidEnd(\(windowId))") {
            return
        }
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
           managed.zoneIndex == nil,
           !isWindowInTemporaryZone(windowId) {
            // Window vanished mid-drag; snap it back into regular placement flow.
            windowPlacementManager.placeNewWindow(managed, preferredScreenId: result.preferredScreenId)
        }

        activeFitResumeAfterDrag(windowId: windowId)
    }

    func windowManualMoveDidAbort(windowId: Int) {
        if shouldIgnoreDueToSleepWake(event: "windowManualMoveDidAbort(\(windowId))") {
            return
        }
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
        // Clear both sides: zone's record and window's record of the assignment
        if let originKey,
           let originContext = screenContexts[originKey.screenId] {
            originContext.zoneController.removeWindow(windowId: managed.windowId)
        }
        clearManagedWindowZone(managed)
        assignWindowToTemporaryZone(managed, on: screenId, centerWindow: true, reason: "drag-to-temporary-zone")
        handleZoneEmptiedByTemporaryDrag(
            originZoneKey: originKey,
            recentlyPlacedInTemporaryZone: managed.windowId,
            reason: "drag-to-temporary-zone"
        )
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

        // Clear both sides: zone's record and window's record of the assignment
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
        handleZoneEmptiedByTemporaryDrag(
            originZoneKey: originZoneKey,
            recentlyPlacedInTemporaryZone: windowId,
            reason: "control-command-drag-to-temporary"
        )

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

    private func handleZoneEmptiedByTemporaryDrag(
        originZoneKey: ZoneKey?,
        recentlyPlacedInTemporaryZone windowId: Int,
        reason: String
    ) {
        if let originZoneKey,
           let originContext = screenContexts[originZoneKey.screenId],
           originContext.zoneController.zone(at: originZoneKey.index) != nil {
            targetedZoneManager.setTargetedZone(originZoneKey, reason: reason)
        }
        syncWindowsToZones(recentlyPlacedInTempZone: windowId)
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
        if shouldIgnoreDueToSleepWake(event: "didCaptureExternalWindow(\(window.windowId))") {
            return
        }
        windowPlacementManager.placeNewWindow(window)
    }

    func windowCreationFailedRetryNeeded(forPid pid: pid_t) {
        if shouldIgnoreDueToSleepWake(event: "windowCreationFailedRetryNeeded(pid: \(pid))") {
            return
        }
        // When AXWindowCreated fires but we can't capture the window (likely due to .cannotComplete errors),
        // schedule a retry to attempt capturing windows for this PID again
        let bundleId = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        Logger.debug("Scheduling capture retry for pid \(pid) due to failed AXWindowCreated capture")
        capturePipeline.requestRetry(forPid: pid, bundleId: bundleId)
    }

    func windowDidResize(windowId: Int) {
        if shouldIgnoreDueToSleepWake(event: "windowDidResize(\(windowId))") {
            return
        }
        // Check if this window entered or exited full-screen mode
        queueFullScreenCheck(windowId: windowId)
    }

    func windowElementDidCreate(element: AXUIElement, pid: pid_t) {
        if shouldIgnoreDueToSleepWake(event: "windowElementDidCreate(\(pid))") {
            return
        }
        checkWindowFullScreenState(element: element, pid: pid)
    }

    func windowElementDidResize(element: AXUIElement, pid: pid_t) {
        if shouldIgnoreDueToSleepWake(event: "windowElementDidResize(\(pid))") {
            return
        }
        queueFullScreenCheck(element: element, pid: pid)
    }

    func windowElementDidClose(element: AXUIElement, pid: pid_t) {
        if shouldIgnoreDueToSleepWake(event: "windowElementDidClose(\(pid))") {
            return
        }
        let elementKey = AccessibilityElementKey(element: element)
        if let workItem = fullScreenCheckWorkItemsByElement.removeValue(forKey: elementKey) {
            workItem.cancel()
        }
        if let cached = fullScreenElementCache.removeValue(forKey: elementKey) {
            Logger.debug("FullScreenTracker: using cached CGWindowID \(cached.cgWindowId) for destroyed element (pid \(pid))")
            notifyFullScreenTrackerOfWindowClose(cgWindowId: cached.cgWindowId, pid: pid)
            return
        }

        if let cgWindowId = resolveCgWindowId(for: element) {
            notifyFullScreenTrackerOfWindowClose(cgWindowId: cgWindowId, pid: pid)
        } else {
            Logger.debug("FullScreenTracker: unable to resolve CGWindowID for destroyed element (pid \(pid)); full-screen state may persist until rescan")
        }
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

    func isZoneResizeDragInProgress() -> Bool {
        return zoneResizeDragInProgress
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

// MARK: - Window activation

extension AppController {
    /// Activates the application owning the window and raises the window to front.
    internal func raiseWindow(_ managed: ManagedWindow) {
        let element = managed.backing.element
        let pid = managed.backing.pid
        if let app = NSRunningApplication(processIdentifier: pid) {
            app.activate()
        }
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
    }
}

// MARK: - Manual resize snapback

extension AppController {
    internal func handleManualResizeFocusChange(pid: pid_t, focusedWindowId: Int?) {
        guard !manualResizeDetachedWindowIds.isEmpty else {
            return
        }

        let candidateIds = manualResizeDetachedWindowIds
        Logger.debug("Manual resize focus change for pid \(pid) (focusedWindowId: \(focusedWindowId.map(String.init) ?? "nil"), candidates: \(candidateIds.count))")
        for windowId in candidateIds {
            guard let managed = windowController.window(withId: windowId) else {
                manualResizeDetachedWindowIds.remove(windowId)
                continue
            }

            guard managed.backing.pid == pid else {
                continue
            }

            if let focusedWindowId, focusedWindowId == windowId {
                // Keep the active window at its custom size until it later loses focus.
                continue
            }

            snapManuallyResizedWindowBackToZoneIfNeeded(windowId: windowId, reason: "focus-change")
        }
    }

    private func snapManuallyResizedWindowBackToZoneIfNeeded(windowId: Int, reason: String) {
        guard manualResizeDetachedWindowIds.contains(windowId) else {
            return
        }

        defer { manualResizeDetachedWindowIds.remove(windowId) }

        guard let managed = windowController.window(withId: windowId),
              let zoneIndex = managed.zoneIndex else {
            return
        }

        let screenId = managed.screenDisplayId ?? detectScreenId(for: managed)
        guard let screenId,
              let context = screenContexts[screenId],
              let descriptor = descriptor(for: screenId),
              let zone = context.zoneController.zone(at: zoneIndex) else {
            return
        }

        let targetFrame = frameWithMargin(for: zone, in: context.zoneController)
        let screenIndex = screenContextStore.loggingIndex(for: screenId)
        Logger.debug("Manual resize snapback: restoring window \(windowId) to zone \(zone.index) on screen \(screenIndex) (reason: \(reason))")
        windowController.moveWindow(managed, to: targetFrame, on: descriptor)
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
        // actualFrame is already in accessibility coordinates for external windows
        return descriptor.accessibilityToScreen(actualFrame)
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
