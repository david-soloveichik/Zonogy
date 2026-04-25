import Foundation
import AppKit
import ApplicationServices

/// Validation retry callbacks and WindowController delegate bridge (manual moves, resizes, closes).
extension AppController {
    private func armLauncherClickSuppressionIfNeeded(
        for destination: TargetedZoneManager.TargetedDestination,
        willOpenLauncher: Bool
    ) {
        let willRetargetVisibleLauncher = launcherController.isActive &&
            targetedZoneManager.targetedDestination != destination
        let willOpenHiddenLauncher = willOpenLauncher && !launcherController.isActive

        guard willRetargetVisibleLauncher || willOpenHiddenLauncher else {
            return
        }

        launcherController.armInheritedClickSuppression()
    }

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
        // If the window is staged for deferred prune, keep its remembered sizes alive —
        // a false-positive detection followed by restore would otherwise lose user state.
        // The sizes are cleared when the pending-prune entry is permanently discarded
        // (see windowController(_:didDiscardPendingPrunedWindowIds:reason:)).
        if !windowController.hasPendingPrunedEntry(forWindowId: windowId) {
            _ = clearRememberedManualResizeSize(for: windowId, reason: "destroyed-window")
            floatingZoneCoordinator.clearRememberedSize(for: windowId)
        }
        selfResizeSnapDebouncer.clear(windowId: windowId)

        removeWindowFromAllZones(windowId: windowId, reason: reason, retarget: retarget)

        // WinShot: Remove any snapshots containing this window
        winShotManager.removeSnapshotsContaining(windowId: windowId)
    }

    private func performDestroyedWindowPostSyncCleanup(windowId: Int) {
        clearRevealModeForWindow(windowId: windowId, transitionToRest: false, reason: "close")
        activeFitClearSuppressionForWindow(windowId)
    }

    /// Resolves the frontmost managed window id used for resize-handle/CmdTab behavior.
    /// We only trust focus-change notifications from the currently frontmost app and
    /// preserve the last known managed focus across transient AX nil-focus failures.
    private func resolveFrontmostManagedWindowId(pid: pid_t, focusedWindowId: Int?) -> Int? {
        let frontmostPid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard frontmostPid == pid else {
            return currentFrontmostManagedWindowId
        }

        if let focusedWindowId {
            return focusedWindowId
        }

        if let focusedManaged = windowController.focusedWindowIfTracked(pid: pid) {
            return focusedManaged.windowId
        }

        if let previousId = currentFrontmostManagedWindowId,
           let previousManaged = windowController.window(withId: previousId),
           previousManaged.backing.pid == pid,
           (previousManaged.zoneIndex != nil || isWindowInFloatingZone(previousId)) {
            return previousId
        }

        return nil
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
                let floatingDescription = isWindowInFloatingZone(windowId) ? "floating" : "not-floating"
                Logger.debug(
                    "windowFocusChanged: pid \(pid) (bundle: \(bundleId)) focusedWindowId=\(windowId) zone=\(zoneDescription) floating=\(floatingDescription) \(screenDescription) (activitySuppressed: \(activitySuppressed))"
                )
            } else {
                Logger.debug(
                    "windowFocusChanged: pid \(pid) (bundle: \(bundleId)) focusedWindowId=nil (activitySuppressed: \(activitySuppressed))"
                )
            }
        }

        if focusedWindowId == nil || activitySuppressed {
            cancelPendingWindowActivityRecord()
        }

        // Dismiss Launcher if focus shifts to a managed window in a zone (tiled or floating).
        if let windowId = focusedWindowId,
           let managed = windowController.window(withId: windowId),
           (managed.zoneIndex != nil || isWindowInFloatingZone(windowId)) {
            dismissLauncherIfActiveRespectingAutoShowGrace()
            exitPinnedResizeBarMode(reason: "managed-window-focus")
        }

        // When focus changes in an application, validate its windows
        // This catches window closures that didn't fire destroy notifications
        _ = validationRetryManager.validateWindowsForApplication(pid: pid, trigger: .focusChanged)
        handleManualResizeFocusChange(pid: pid, focusedWindowId: focusedWindowId)
        handleActiveFitFocusChange(pid: pid)
        handleFloatingZoneFocusChange(pid: pid, focusedWindowId: focusedWindowId)

        // Record window activity for launcher recency ordering
        // Skip during activity suppression to avoid twitchy recordings during floating zone/WinShot operations
        if let windowId = focusedWindowId, !activitySuppressed {
            recordActiveWindowForHistoryDebounced(windowId: windowId, pid: pid, reason: "focus-changed")
        }

        // Track frontmost managed window for CmdTab initial selection and resize-handle
        // overlap avoidance. Ignore stale background-app focus events and tolerate
        // transient AX nil-focus failures for the frontmost app.
        currentFrontmostManagedWindowId = resolveFrontmostManagedWindowId(
            pid: pid,
            focusedWindowId: focusedWindowId
        )

        // Resize-handle visibility depends on which managed window is active.
        // Refresh on focus changes so the UI updates immediately.
        refreshResizeHandles()

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

    func placeholderActivated(screenId: CGDirectDisplayID, zoneIndex: Int, isDoubleClick: Bool) {
        if isScreenPausedForFullScreen(screenId) {
            Logger.debug("Placeholder activated on full-screen screen \(screenContextStore.loggingIndex(for: screenId)); ignoring")
            return
        }
        let screenIndex = screenContextStore.loggingIndex(for: screenId)
        Logger.debug("Placeholder activated for zone \(zoneIndex) on screen \(screenIndex) (doubleClick: \(isDoubleClick))")
        enterPinnedResizeBarMode(on: screenId, reason: "placeholder-activated")
        let key = zoneKey(for: screenId, index: zoneIndex)
        let openLauncher = isDoubleClick && !cmdTabController.isActive
        armLauncherClickSuppressionIfNeeded(for: .tiled(key), willOpenLauncher: openLauncher)
        targetedZoneManager.setTargetedZone(key, reason: "placeholder-activated")
        flashTargetFeedback(for: key)

        // Promote the floating zone occupant into the activated placeholder's zone if they overlap.
        // Targeting happens first so that placeWindow sees the zone as targeted and triggers
        // the normal retarget-after-fill logic per spec.
        if let occupant = floatingZoneOccupant(on: screenId),
           let context = screenContexts[screenId],
           let zone = context.zoneController.zone(at: zoneIndex),
           isZoneEffectivelyEmpty(zone),
           let occupantFrame = windowController.actualFrameInAccessibilityCoordinates(for: occupant) {
            let zoneFrame = context.descriptor.screenToAccessibility(zone.frame)
            if FloatingZoneOverlapPolicy.overlapsZoneFrame(
                floatingFrame: occupantFrame,
                zoneFrame: zoneFrame
            ) {
                Logger.debug("Promoting floating zone occupant \(occupant.windowId) into zone \(zoneIndex) on screen \(screenIndex) (placeholder-activated)")
                windowPlacementManager.placeWindow(occupant, into: key, reason: "placeholder-activated-promotion")
            }
        }
        if isDoubleClick && !cmdTabController.isActive {
            showLauncherIfAllowed(trigger: "placeholder-double-click")
        }
    }

    func placeholderSearchPillClicked(screenId: CGDirectDisplayID, zoneIndex: Int) {
        if isScreenPausedForFullScreen(screenId) {
            Logger.debug("Placeholder search pill clicked on full-screen screen \(screenContextStore.loggingIndex(for: screenId)); ignoring")
            return
        }
        let screenIndex = screenContextStore.loggingIndex(for: screenId)
        Logger.debug("Placeholder search pill clicked for zone \(zoneIndex) on screen \(screenIndex)")

        // Reuse placeholder activation logic for targeting and floating zone overlap promotion
        placeholderActivated(screenId: screenId, zoneIndex: zoneIndex, isDoubleClick: false)

        // Always show the Launcher when the search pill is clicked
        armLauncherClickSuppressionIfNeeded(for: .tiled(zoneKey(for: screenId, index: zoneIndex)), willOpenLauncher: true)
        showLauncherIfAllowed(trigger: "placeholder-search-pill")
    }

    func zoneIndicatorActivated(_ key: ZoneKey, wasAlreadyTargeted: Bool, isDoubleClick: Bool) {
        if isScreenPausedForFullScreen(key.screenId) {
            Logger.debug("Zone indicator activated on full-screen screen \(screenContextStore.loggingIndex(for: key.screenId)); ignoring")
            return
        }
        let screenIndex = screenContextStore.loggingIndex(for: key.screenId)
        Logger.debug("Zone indicator activated for zone \(key.index) on screen \(screenIndex) (wasAlreadyTargeted: \(wasAlreadyTargeted), isDoubleClick: \(isDoubleClick))")
        let openLauncher = (isDoubleClick || wasAlreadyTargeted) && !cmdTabController.isActive
        armLauncherClickSuppressionIfNeeded(for: .tiled(key), willOpenLauncher: openLauncher)
        targetedZoneManager.setTargetedZone(key, reason: "indicator-clicked")

        if openLauncher {
            showLauncherIfAllowed(trigger: "indicator-clicked")
        }
    }

    func floatingZoneIndicatorActivated(screenId: CGDirectDisplayID, wasAlreadyTargeted: Bool, isDoubleClick: Bool) {
        if isScreenPausedForFullScreen(screenId) {
            Logger.debug("Floating indicator activated on full-screen screen \(screenContextStore.loggingIndex(for: screenId)); ignoring")
            return
        }
        let screenIndex = screenContextStore.loggingIndex(for: screenId)
        Logger.debug("Floating zone indicator activated on screen \(screenIndex) (wasAlreadyTargeted: \(wasAlreadyTargeted), isDoubleClick: \(isDoubleClick))")
        let openLauncher = (isDoubleClick || wasAlreadyTargeted) && !cmdTabController.isActive
        armLauncherClickSuppressionIfNeeded(for: .floating(screenId: screenId), willOpenLauncher: openLauncher)
        targetedZoneManager.setFloatingTarget(on: screenId, reason: "floating-indicator-clicked")

        if openLauncher {
            showLauncherIfAllowed(trigger: "floating-indicator-clicked")
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
        // Sync handles floating zone promotion automatically
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
            // Re-raise the active window after each unminimize animation to keep it in front.
            // Activate the app too in case the unminimize stole app activation.
            if var pending = pendingRestoreRaise, pending.pendingWindowIds.remove(windowId) != nil {
                NSRunningApplication(processIdentifier: pending.pid)?.activate()
                _ = AXUIElementPerformAction(pending.element, kAXRaiseAction as CFString)
                Logger.debug("Re-raised restore active window after unminimize of window \(windowId)")
                pendingRestoreRaise = pending.pendingWindowIds.isEmpty ? nil : pending
            }
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
        defer {
            // AX focus notifications can lag during edge drags; force this resize event's
            // window into the overlap computation so handles update immediately.
            refreshResizeHandles(frontmostWindowIdOverride: windowId)
        }

        guard let managed = windowController.window(withId: windowId) else {
            manualResizeDetachedWindowIds.remove(windowId)
            return
        }

        if managed.isInFloatingZone {
            floatingZoneCoordinator.rememberSize(for: windowId, size: frame.size)
        }

        guard let zoneIndex = managed.zoneIndex else {
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
        rememberManualResizeSize(for: windowId, size: frame.size, reason: "manual-resize-end")

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

        let isAlreadyDetached = manualResizeDetachedWindowIds.contains(managed.windowId)

        // If the cursor is near the window border and the left button is down (or just went up),
        // assume this resize came from a user edge drag and keep Sticky Resize tracking updated.
        let cursorPoint = currentCursorScreenPoint(on: descriptor)
        let isLikelyUserResize = WindowResizeHeuristics.isLikelyUserEdgeDragResize(
            cursorPoint: cursorPoint,
            windowFrame: reportedFrame,
            edgeProximity: userResizeEdgeProximityThreshold,
            leftMouseButtonDown: MouseButtons.isLeftMouseButtonDown(),
            secondsSinceLeftMouseUp: MouseButtons.secondsSinceLastLeftMouseUp(),
            mouseUpGrace: userResizeMouseUpGraceInterval
        )
        let action = WindowSelfResizePolicy.action(
            isAlreadyDetached: isAlreadyDetached,
            isLikelyUserResize: isLikelyUserResize
        )
        switch action {
        case .updateManualResizeTracking:
            let screenIndex = screenContextStore.loggingIndex(for: screenId)
            Logger.debug(
                "Self-resize snap not applied for window \(managed.windowId) in zone \(zone.index) on screen \(screenIndex) (reason: likely-user-edge-drag)"
            )
            return false
        case .ignoreWhileDetached:
            let screenIndex = screenContextStore.loggingIndex(for: screenId)
            Logger.debug(
                "Self-resize snap skipped for window \(managed.windowId) in zone \(zone.index) on screen \(screenIndex) (reason: manually-detached)"
            )
            return true
        case .snapToZone:
            break
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

        let isFloating = isWindowInFloatingZone(windowId)

        if isFloating && !isControlCommandModifierHeld {
            let floatingScreenId = managed.screenDisplayId ?? detectScreenId(for: managed)
            floatingDragHandler.beginDrag(windowId: windowId, originScreenId: floatingScreenId)
            Logger.debug("Floating floating zone drag began for window \(windowId)")
            return
        }

        let originZoneKey = zoneKey(forManagedWindow: managed)

        activeFitSuspendForDrag(windowId: windowId)

        let originScreenId = managed.screenDisplayId ?? detectScreenId(for: managed)
        dragDropCoordinator.beginDragSession(
            windowId: windowId,
            frame: frame,
            originZoneKey: originZoneKey,
            originScreenId: originScreenId,
            originatedFromFloating: isFloating
        )
    }

    func windowManualMoveDidUpdate(windowId: Int, frame: CGRect) {
        if shouldIgnoreDueToSleepWake(event: "windowManualMoveDidUpdate(\(windowId))") {
            return
        }
        if shouldSuppressManualMoveHandling(windowId: windowId, event: "move-update") {
            return
        }
        if floatingDragHandler.isActive {
            floatingDragHandler.updateDrag(frame: frame)
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
        if finishFloatingDragIfActive(windowId: windowId, finalFrame: finalFrame) {
            return
        }
        let result = dragDropCoordinator.endDragSession(windowId: windowId, finalFrame: finalFrame)

        // Re-check after zone-drag teardown: releasing Control-Command on the same
        // mouse-up can resume a floating drag inside `endDragSession`.
        if finishFloatingDragIfActive(windowId: windowId, finalFrame: finalFrame) {
            return
        }

        displacedWindowCoordinator.resolve(
            result.displacedWindow,
            preferredScreenId: result.preferredScreenId,
            disposition: result.displacedDisposition
        )

        syncWindowsToZones()

        if let managed = windowController.window(withId: windowId),
           managed.zoneIndex == nil,
           !result.didResolveDrop {
            if result.originatedFromFloating {
                // Floating-originated drag cancelled (e.g., dropped over empty zone with
                // Control-Command held). Re-establish as a normal floating drop so
                // cross-screen swaps work correctly instead of minimizing occupants.
                if !isWindowInFloatingZone(windowId) {
                    // Mid-drag promotion cleared the floating zone; reassign to origin first.
                    let originScreenId = result.preferredScreenId ?? activeScreenId()
                    assignWindowToFloatingZone(managed, on: originScreenId, centerWindow: false, reason: "cancelled-floating-drag-revert")
                }
                finalizeFloatingDrop(
                    windowId: windowId,
                    finalFrame: finalFrame,
                    hoveredAddZoneScreenId: nil,
                    hoveredFloatingScreenId: nil,
                    finalCursorPoint: nil
                )
            } else if !isWindowInFloatingZone(windowId) {
                // Window vanished mid-drag; snap it back into regular placement flow.
                windowPlacementManager.placeNewWindow(managed, preferredScreenId: result.preferredScreenId)
            }
        }

        activeFitResumeAfterDrag(windowId: windowId)
    }

    private func finishFloatingDragIfActive(windowId: Int, finalFrame: CGRect) -> Bool {
        guard floatingDragHandler.isActive else {
            return false
        }
        floatingDragHandler.endDrag(finalFrame: finalFrame)
        activeFitResumeAfterDrag(windowId: windowId)
        refreshResizeHandles()
        return true
    }

    func windowManualMoveDidAbort(windowId: Int) {
        if shouldIgnoreDueToSleepWake(event: "windowManualMoveDidAbort(\(windowId))") {
            return
        }
        if floatingDragHandler.isActive {
            floatingDragHandler.abortDrag()
            cancelTiledFloatingConversionIfNeeded(windowId: windowId, reason: "floating-drag-abort")
            return
        }
        if dragDropCoordinator.currentDragWindowId == windowId {
            // Tear down overlays when the OS/host app ends the drag without a mouse-up.
            dragDropCoordinator.tearDownDragSession()
            syncWindowsToZones()
        }
        activeFitResumeAfterDrag(windowId: windowId)
    }

    func dropWindowIntoFloatingZone(_ managed: ManagedWindow, from originKey: ZoneKey?, on screenId: CGDirectDisplayID) {
        // Clear both sides: zone's record and window's record of the assignment
        if let originKey,
           let originContext = screenContexts[originKey.screenId] {
            originContext.zoneController.removeWindow(windowId: managed.windowId)
        }
        clearManagedWindowZone(managed)
        assignWindowToFloatingZone(managed, on: screenId, centerWindow: true, reason: "drag-to-floating-zone")
        handleZoneEmptiedByFloatingDrag(
            originZoneKey: originKey,
            recentlyPlacedInFloatingZone: managed.windowId,
            reason: "drag-to-floating-zone"
        )
    }

    internal func promoteFloatingDragToZone(windowId: Int, frame: CGRect, originScreenId: CGDirectDisplayID?) {
        promoteFloatingDragToTiledDrag(windowId: windowId, frame: frame, originFloatingScreenId: originScreenId)
    }

    private func promoteFloatingDragToTiledDrag(windowId: Int, frame: CGRect, originFloatingScreenId: CGDirectDisplayID?) {
        guard let managed = windowController.window(withId: windowId) else {
            return
        }
        clearFloatingZone(for: windowId, minimize: false, reason: "control-command-drag")
        activeFitSuspendForDrag(windowId: windowId)
        updateAddZoneIndicatorHighlight(screenId: nil)
        updateFloatingIndicatorHighlight(screenId: nil)
        let originScreenId = originFloatingScreenId ?? managed.screenDisplayId ?? detectScreenId(for: managed)
        dragDropCoordinator.beginDragSession(
            windowId: windowId,
            frame: frame,
            originZoneKey: nil,
            originScreenId: originScreenId,
            originatedFromFloating: true
        )
        dragDropCoordinator.updateDragSession(windowId: windowId, frame: frame)
    }

    internal func promoteTiledDragToFloating(
        windowId: Int,
        frame: CGRect,
        originZoneKey: ZoneKey?,
        originScreenId: CGDirectDisplayID?,
        preferredFloatingScreenId: CGDirectDisplayID?
    ) -> Bool {
        guard let managed = windowController.window(withId: windowId),
              !floatingDragHandler.isActive else {
            return false
        }

        let destinationScreenId = preferredFloatingScreenId
            ?? targetedFloatingScreenId
            ?? originZoneKey?.screenId
            ?? originScreenId
            ?? detectScreenId(for: managed)
            ?? activeScreenId()

        let displaced = floatingZoneOccupant(on: destinationScreenId)
        let displacedFrame = displaced.flatMap { captureFloatingScreenFrame(for: $0, on: destinationScreenId) }

        // Clear both sides: zone's record and window's record of the assignment
        if let originKey = originZoneKey,
           let originContext = screenContexts[originKey.screenId] {
            originContext.zoneController.removeWindow(windowId: windowId)
        }
        clearManagedWindowZone(managed)
        // `clearManagedWindowZone` drops ActiveFit suppression. Restore it so
        // releasing Control-Command mid-drag cannot trigger a reveal/rest move
        // while we are still dragging the window.
        activeFitSuspendForDrag(windowId: windowId)

        assignWindowToFloatingZone(
            managed,
            on: destinationScreenId,
            // Mid-drag conversion should preserve the live dragged frame; recentering
            // here causes the window to visibly jump under the cursor.
            centerWindow: false,
            reason: "control-command-drag-to-floating"
        )
        handleZoneEmptiedByFloatingDrag(
            originZoneKey: originZoneKey,
            recentlyPlacedInFloatingZone: windowId,
            reason: "control-command-drag-to-floating"
        )

        floatingDragHandler.beginDrag(
            windowId: windowId,
            originScreenId: destinationScreenId,
            originZoneKey: originZoneKey,
            requiresControlCommand: true
        )
        floatingDragHandler.updateDrag(frame: frame)

        tiledToFloatingDragContexts[windowId] = TiledToFloatingDragContext(
            originZoneKey: originZoneKey,
            originScreenId: originScreenId,
            floatingScreenId: destinationScreenId,
            displacedWindowId: displaced?.windowId,
            displacedWindowFrame: displacedFrame
        )

        return true
    }

    private func handleZoneEmptiedByFloatingDrag(
        originZoneKey: ZoneKey?,
        recentlyPlacedInFloatingZone windowId: Int,
        reason: String
    ) {
        if let originZoneKey,
           let originContext = screenContexts[originZoneKey.screenId],
           originContext.zoneController.zone(at: originZoneKey.index) != nil {
            targetedZoneManager.setTargetedZone(originZoneKey, reason: reason)
        }
        syncWindowsToZones(recentlyPlacedInFloatingZone: windowId)
    }

    func revertFloatingDragToTiled(
        windowId: Int,
        frame: CGRect,
        originZoneKey: ZoneKey?,
        originScreenId: CGDirectDisplayID?
    ) {
        guard let context = tiledToFloatingDragContexts.removeValue(forKey: windowId),
              let managed = windowController.window(withId: windowId) else {
            return
        }

        reinstateWindowFromFloatingContext(
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
            originatedFromFloating: false
        )
        dragDropCoordinator.updateDragSession(windowId: windowId, frame: frame)
    }

    func windowController(_ controller: WindowController, didCaptureExternalWindow window: ManagedWindow) {
        if shouldIgnoreDueToSleepWake(event: "didCaptureExternalWindow(\(window.windowId))") {
            return
        }
        if let restoredDestination = controller.consumeRestoredPendingPruneDestination(for: window.windowId),
           placeRestoredDeferredPruneWindowIfPossible(window, destination: restoredDestination) {
            return
        }
        windowPlacementManager.placeNewWindow(window)
    }

    func windowController(
        _ controller: WindowController,
        didDiscardPendingPrunedWindowIds windowIds: [Int],
        reason: String
    ) {
        for windowId in windowIds {
            _ = clearRememberedManualResizeSize(for: windowId, reason: "pending-prune-discarded-\(reason)")
            floatingZoneCoordinator.clearRememberedSize(for: windowId)
        }
    }

    private func placeRestoredDeferredPruneWindowIfPossible(
        _ window: ManagedWindow,
        destination: PendingPrunedWindowDestination
    ) -> Bool {
        switch destination {
        case .tiled(let key):
            guard let context = screenContexts[key.screenId],
                  let zone = context.zoneController.zone(at: key.index),
                  zone.occupantWindowId == nil else {
                return false
            }

            Logger.debug(
                "Restoring deferred-prune window \(window.windowId) to original zone \(key.index) on \(screenContextStore.logDescription(for: key.screenId))"
            )
            windowPlacementManager.placeWindow(window, into: key, reason: "deferred-prune-restore")
            return true

        case .floating(let screenId):
            guard screenContexts[screenId] != nil,
                  floatingZoneOccupant(on: screenId) == nil else {
                return false
            }

            Logger.debug(
                "Restoring deferred-prune window \(window.windowId) to original floating zone on \(screenContextStore.logDescription(for: screenId))"
            )
            windowPlacementManager.placeWindow(
                window,
                into: .floating(screenId: screenId),
                centerFloatingWindow: false,
                reason: "deferred-prune-restore"
            )
            return true
        }
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
        if let floatingScreenId = targetedFloatingScreenId {
            let screenIndex = screenContextStore.loggingIndex(for: floatingScreenId)
            return "floating zone on screen \(screenIndex)"
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

    internal func resolveFloatingDropTarget(cursorPoint: CGPoint?) -> CGDirectDisplayID? {
        guard let cursorPoint else { return nil }

        let hitAreas = floatingIndicatorTracker.hitAreas
        if let targeted = targetedFloatingScreenId,
           let targetedFrame = hitAreas[targeted], targetedFrame.contains(cursorPoint) {
            return targeted
        }

        for (screenId, frame) in hitAreas where frame.contains(cursorPoint) {
            return screenId
        }
        return nil
    }

    // MARK: - Empty-zone auto-promotion for floating drags

    internal func resolveEmptyTilingZoneUnderCursor(cursorPoint: CGPoint?) -> ZoneKey? {
        guard let cursorPoint else { return nil }
        for (screenId, context) in screenContexts {
            if isScreenPausedForFullScreen(screenId) { continue }
            let descriptor = context.descriptor
            for zone in context.zoneController.allZones where zone.isEmpty {
                let accessibilityFrame = descriptor.screenToAccessibility(zone.frame)
                if accessibilityFrame.contains(cursorPoint) {
                    return ZoneKey(screenId: screenId, index: zone.index)
                }
            }
        }
        return nil
    }

    internal func presentFloatingDragOverlays() {
        var descriptors: [ZoneOverlayDescriptor] = []
        for (screenId, context) in screenContexts {
            if isScreenPausedForFullScreen(screenId) { continue }
            let descriptor = context.descriptor
            for zone in context.zoneController.allZones {
                let cocoaFrame = descriptor.screenToCocoa(zone.frame)
                descriptors.append(
                    ZoneOverlayDescriptor(
                        key: ZoneKey(screenId: screenId, index: zone.index),
                        cocoaFrame: cocoaFrame,
                        isEmpty: zone.isEmpty
                    )
                )
            }
        }
        floatingDragOverlayManager.present(over: descriptors)
    }

    internal func tearDownFloatingDragOverlays() {
        floatingDragOverlayManager.tearDown()
    }

    internal func updateFloatingDragOverlayHighlight(zoneKey: ZoneKey?) {
        floatingDragOverlayManager.updateHighlight(to: zoneKey)
    }

    internal func finalizeFloatingDropIntoEmptyZone(windowId: Int, zoneKey: ZoneKey) {
        guard let managed = windowController.window(withId: windowId) else { return }

        // Validate the target zone still exists and is empty before committing.
        guard let context = screenContexts[zoneKey.screenId],
              let zone = context.zoneController.zone(at: zoneKey.index),
              zone.isEmpty else {
            Logger.debug("Auto-promote drop aborted: zone \(zoneKey.index) no longer empty or missing")
            return
        }

        clearFloatingZone(for: windowId, minimize: false, reason: "auto-promote-drop-into-empty-zone")

        if let result = windowPlacementManager.assignWindowFromDrag(managed, to: zoneKey) {
            displacedWindowCoordinator.resolve(
                result.displacedWindow,
                preferredScreenId: zoneKey.screenId,
                disposition: .reassign
            )
        }

        syncWindowsToZones()
        Logger.debug("Auto-promoted floating drag: window \(windowId) dropped into empty zone \(zoneKey.index) on screen \(screenContextStore.loggingIndex(for: zoneKey.screenId))")
    }

}

// MARK: - Window activation

extension AppController {
    /// Activates the application owning the window and raises the window to front.
    internal func raiseWindow(_ managed: ManagedWindow) {
        let element = managed.backing.element
        let pid = managed.backing.pid
        scheduleWindowRaise(pid: pid, element: element, reason: "raise-window")
    }
}

// MARK: - Manual resize snapback

extension AppController {
    internal func handleManualResizeFocusChange(pid: pid_t, focusedWindowId: Int?) {
        guard !manualResizeDetachedWindowIds.isEmpty ||
                (stickyResizeEnabled && focusedWindowId != nil) else {
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

        guard stickyResizeEnabled,
              let focusedWindowId,
              let managed = windowController.window(withId: focusedWindowId),
              managed.backing.pid == pid,
              let zoneIndex = managed.zoneIndex else {
            return
        }

        let screenId = managed.screenDisplayId ?? detectScreenId(for: managed)
        guard let screenId else {
            return
        }

        _ = restoreStickyResizeFrameIfNeeded(
            for: managed,
            screenId: screenId,
            zoneIndex: zoneIndex,
            reason: "focus-change"
        )
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

// MARK: - DragDropCoordinatorDelegate (floating re-entry)

extension AppController {
    func resumeFloatingDrag(windowId: Int, frame: CGRect, originScreenId: CGDirectDisplayID?) {
        guard let managed = windowController.window(withId: windowId) else {
            return
        }
        let screenId = originScreenId ?? detectScreenId(for: managed) ?? activeScreenId()
        assignWindowToFloatingZone(
            managed,
            on: screenId,
            centerWindow: false,
            reason: "control-command-release"
        )
        floatingDragHandler.beginDrag(windowId: windowId, originScreenId: screenId)
        floatingDragHandler.updateDrag(frame: frame)
    }

    private func captureFloatingScreenFrame(for window: ManagedWindow, on screenId: CGDirectDisplayID) -> CGRect? {
        guard let descriptor = descriptor(for: screenId) else {
            return nil
        }
        let actualFrame = window.actualFrame
        // actualFrame is already in accessibility coordinates for external windows
        return descriptor.accessibilityToScreen(actualFrame)
    }

    private func restoreFloatingOccupant(from context: TiledToFloatingDragContext) {
        guard let displacedId = context.displacedWindowId,
              let displaced = windowController.window(withId: displacedId) else {
            return
        }
        unminimizeWithPrePositioning(displaced, reason: "floating-drag-revert")
        assignWindowToFloatingZone(
            displaced,
            on: context.floatingScreenId,
            centerWindow: false,
            reason: "floating-drag-revert"
        )
        if let frame = context.displacedWindowFrame,
           let descriptor = descriptor(for: context.floatingScreenId) {
            windowController.showWindow(displaced, at: frame, on: descriptor)
            // Override any stale seed from assign (which used pre-revert actualFrame)
            // so the remembered floating size matches the restored pre-drag frame.
            floatingZoneCoordinator.rememberSize(for: displaced.windowId, size: frame.size)
        }
    }

    private func reinstateWindowFromFloatingContext(
        windowId: Int,
        context: TiledToFloatingDragContext,
        managed: ManagedWindow,
        reason: String
    ) {
        clearFloatingZone(for: windowId, minimize: false, reason: reason)
        restoreFloatingOccupant(from: context)

        if let originKey = context.originZoneKey,
           let originContext = screenContexts[originKey.screenId] {
            originContext.zoneController.assignWindow(windowId: windowId, toZoneIndex: originKey.index)
            setManagedWindow(managed, screenId: originKey.screenId, zoneIndex: originKey.index)
        } else if let screenId = context.originScreenId {
            setManagedWindow(managed, screenId: screenId, zoneIndex: nil)
        }
    }

    internal func cancelTiledFloatingConversionIfNeeded(windowId: Int, reason: String) {
        guard let context = tiledToFloatingDragContexts.removeValue(forKey: windowId),
              let managed = windowController.window(withId: windowId) else {
            return
        }
        reinstateWindowFromFloatingContext(windowId: windowId, context: context, managed: managed, reason: reason)
        syncWindowsToZones()
    }
}
