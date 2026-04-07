import Foundation
import AppKit

/// Manages ActiveFit behavior: transitioning windows between rest mode and reveal mode.
///
/// ActiveFit has two modes:
/// - **Rest mode**: Window is anchored to zone origin; may overflow off-screen (default state).
/// - **Reveal mode**: Window is shifted so entire frame fits on screen (when window is active).
///
/// This extension handles entering reveal mode when a qualifying window gains focus,
/// and returning to rest mode when the window loses focus or is otherwise deactivated.
extension AppController {
    /// Tracks the current reveal mode state for a single window.
    /// Only one window can be in reveal mode at a time.
    struct ActiveFitState {
        let windowId: Int
        var zoneKey: ZoneKey
        /// The frame applied when the window entered reveal mode.
        var revealFrame: CGRect
    }

    /// Handles focus changes to potentially enter or exit reveal mode.
    internal func handleActiveFitFocusChange(pid: pid_t) {
        guard pid != getpid() else {
            exitRevealMode(reason: "focus-self")
            return
        }

        guard let managed = windowController.focusedWindowIfTracked(pid: pid) else {
            // No tracked focused window for this pid; keep any window in reveal mode as-is.
            Logger.debug("ActiveFit focus change ignored for pid \(pid); no tracked focused window")
            return
        }

        // If the newly focused window is not part of our managed layout (neither tiled nor in the
        // floating zone), we deliberately keep the current window in reveal mode.
        guard isLayoutManagedWindow(managed) else {
            Logger.debug("ActiveFit focus change ignored for window \(managed.windowId); not in tiled or floating zones")
            return
        }

        // If focus moved to a different window than the one currently in reveal mode,
        // return that previous window to rest mode before evaluating the new candidate.
        // Skip if the window is suppressed (e.g., during WinShot restore).
        if let state = activeFitState, state.windowId != managed.windowId {
            if !isActiveFitSuppressed(windowId: state.windowId) {
                transitionToRestMode(state: state, reason: "focus-transfer")
            } else {
                Logger.debug("ActiveFit: skipping rest mode transition for window \(state.windowId); suppressed")
            }
        }

        guard let zoneIndex = managed.zoneIndex,
              zoneIndex >= 2 else {
            // New focused window is not in a right-column zone; no reveal mode needed.
            return
        }

        guard !isActiveFitSuppressed(windowId: managed.windowId) else {
            Logger.debug("ActiveFit focus change ignored for window \(managed.windowId); behavior suppressed")
            return
        }

        let screenId = managed.screenDisplayId ?? detectScreenId(for: managed)
        guard let screenId else {
            exitRevealMode(reason: "focus-no-screen")
            return
        }

        enterRevealModeIfNeeded(for: managed, screenId: screenId, zoneIndex: zoneIndex, reason: "focus-change")
    }

    internal func handleActiveFitActivationCandidate(pid: pid_t?) {
        guard let pid else {
            exitRevealMode(reason: "workspace-no-application")
            return
        }
        handleActiveFitFocusChange(pid: pid)
    }

    /// Returns true if the window is in reveal mode and should skip zone sync repositioning.
    internal func activeFitShouldSkipSync(for zoneKey: ZoneKey, windowId: Int) -> Bool {
        guard let state = activeFitState else {
            return false
        }
        return state.windowId == windowId && state.zoneKey == zoneKey
    }

    /// Handles zone assignment changes for a window that may be in reveal mode.
    internal func activeFitHandleAssignmentChange(managed: ManagedWindow, screenId: CGDirectDisplayID, zoneIndex: Int?) {
        if dragDropCoordinator.currentDragWindowId == managed.windowId {
            Logger.debug("ActiveFit assignment change ignored for window \(managed.windowId); drag in progress")
            return
        }
        guard let state = activeFitState, state.windowId == managed.windowId else {
            if let zoneIndex {
                evaluateRevealModeForAssignment(managed: managed, screenId: screenId, zoneIndex: zoneIndex)
            }
            return
        }

        guard let zoneIndex else {
            Logger.debug("ActiveFit: exiting reveal mode for window \(managed.windowId) due to assignment removal")
            activeFitState = nil
            return
        }

        guard zoneIndex >= 2 else {
            Logger.debug("ActiveFit: exiting reveal mode for window \(managed.windowId); reassigned to zone \(zoneIndex)")
            clearRevealModeForWindow(windowId: managed.windowId, transitionToRest: true, reason: "assignment-zone<2")
            return
        }

        let updatedKey = ZoneKey(screenId: screenId, index: zoneIndex)
        if state.zoneKey != updatedKey {
            Logger.debug("ActiveFit: updating zone key for revealed window \(managed.windowId) to zone \(zoneIndex)")
            activeFitState = ActiveFitState(windowId: state.windowId, zoneKey: updatedKey, revealFrame: state.revealFrame)
        }

        enterRevealModeIfNeeded(for: managed, screenId: screenId, zoneIndex: zoneIndex, reason: "assignment-change")
    }

    /// Clears reveal mode for a specific window, optionally transitioning it back to rest mode.
    internal func clearRevealModeForWindow(windowId: Int, transitionToRest: Bool = true, reason: String) {
        guard let state = activeFitState, state.windowId == windowId else {
            return
        }

        if transitionToRest {
            transitionToRestMode(state: state, reason: reason)
        } else {
            Logger.debug("ActiveFit: clearing reveal state for window \(windowId) without rest transition (\(reason))")
            activeFitState = nil
            refreshResizeHandles()
        }
    }

    /// Exits reveal mode for the currently revealed window (if any), returning it to rest mode.
    internal func exitRevealMode(reason: String) {
        guard let state = activeFitState else {
            return
        }
        transitionToRestMode(state: state, reason: reason)
    }

    /// Evaluates whether a window should enter reveal mode and applies the transition if needed.
    private func enterRevealModeIfNeeded(
        for managed: ManagedWindow,
        screenId: CGDirectDisplayID,
        zoneIndex: Int,
        reason: String,
        shouldPrimeWithRestMove: Bool = true
    ) {
        guard let context = screenContexts[screenId],
              let descriptor = descriptor(for: screenId),
              let zone = context.zoneController.zone(at: zoneIndex) else {
            exitRevealMode(reason: "missing-context")
            return
        }

        guard !isActiveFitSuppressed(windowId: managed.windowId) else {
            Logger.debug("ActiveFit: reveal mode evaluation skipped for window \(managed.windowId); suppressed")
            return
        }

        let frameResolution = stickyResizeFrameResolution(
            for: managed,
            zone: zone,
            controller: context.zoneController
        )
        let candidateFrame = frameResolution.frame

        // If a frame retry is still pending (e.g., from initial placement), skip — the
        // rest-mode moveWindow below would cancel the retry chain before it resizes the
        // window to zone dimensions. The retry chain will call frameRetryDidSettle when
        // it completes, triggering re-evaluation.
        if windowController.hasFrameRetryPending(for: managed.windowId) {
            Logger.debug("ActiveFit: skipping reveal evaluation for window \(managed.windowId); frame retry pending")
            return
        }

        // First move window to rest mode position (zone-anchored) to get accurate dimensions.
        // This prevents acting on stale dimensions (e.g., when a window just moved from another screen).
        // Skip this priming move after a frame-retry settle callback to avoid starting a new retry loop.
        if activeFitState == nil {
            if shouldPrimeWithRestMove {
                windowController.moveWindow(managed, to: candidateFrame, on: descriptor)
            } else {
                Logger.debug("ActiveFit: evaluating settled frame for window \(managed.windowId) without rest-mode priming move")
            }
        }

        let actualFrame = windowController.actualFrameInScreenCoordinates(for: managed, on: descriptor)
        let screenBounds = descriptor.visibleScreenBounds
        let candidateSize = frameResolution.usesRememberedSize ? candidateFrame.size : actualFrame.size

        // Check if window would overflow in rest mode and needs reveal mode
        guard let revealFrame = ActiveFitPolicy.revealFrameIfNeeded(
            zoneIndex: zoneIndex,
            zoneOrigin: candidateFrame.origin,
            windowSize: candidateSize,
            screenBounds: screenBounds,
            tolerance: activeFitOverflowTolerance
        ) else {
            // Window fits on screen in rest mode; no reveal needed
            exitRevealModeIfMatches(windowId: managed.windowId, reason: "no-overflow")
            return
        }

        // If another window is in reveal mode, return it to rest mode first
        if let existing = activeFitState, existing.windowId != managed.windowId {
            transitionToRestMode(state: existing, reason: "handoff")
        }

        // Skip if already in reveal mode at the same position
        if let existing = activeFitState,
           existing.windowId == managed.windowId,
           framesClose(existing.revealFrame, revealFrame) {
            return
        }

        // Enter reveal mode: shift window to fit on screen
        let zoneKey = ZoneKey(screenId: screenId, index: zoneIndex)
        Logger.debug("ActiveFit: entering reveal mode for window \(managed.windowId) -> \(revealFrame.origin) (\(reason))")
        windowController.moveWindow(managed, to: revealFrame, on: descriptor)
        activeFitState = ActiveFitState(windowId: managed.windowId, zoneKey: zoneKey, revealFrame: revealFrame)
        refreshResizeHandles()
    }

    /// Exits reveal mode for a specific window if it matches the current state.
    private func exitRevealModeIfMatches(windowId: Int, reason: String) {
        guard let state = activeFitState, state.windowId == windowId else {
            return
        }
        transitionToRestMode(state: state, reason: reason)
    }

    /// Transitions a window from reveal mode back to rest mode (zone-anchored position).
    private func transitionToRestMode(state: ActiveFitState, reason: String) {
        guard let context = screenContexts[state.zoneKey.screenId],
              let descriptor = descriptor(for: state.zoneKey.screenId),
              let zone = context.zoneController.zone(at: state.zoneKey.index),
              let managed = windowController.window(withId: state.windowId) else {
            Logger.debug("ActiveFit: clearing reveal state for window \(state.windowId) without rest transition (\(reason))")
            activeFitState = nil
            return
        }

        let restFrame = stickyResizeFrameResolution(
            for: managed,
            zone: zone,
            controller: context.zoneController
        ).frame
        Logger.debug("ActiveFit: returning window \(state.windowId) to rest mode in zone \(state.zoneKey.index) (\(reason))")

        // Clear state before moving window to avoid race condition with frame retry checks
        activeFitState = nil
        windowController.moveWindow(managed, to: restFrame, on: descriptor)
        refreshResizeHandles()
    }

    private func framesClose(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) <= activeFitOverflowTolerance &&
            abs(lhs.origin.y - rhs.origin.y) <= activeFitOverflowTolerance &&
            abs(lhs.size.width - rhs.size.width) <= activeFitOverflowTolerance &&
            abs(lhs.size.height - rhs.size.height) <= activeFitOverflowTolerance
    }

    /// Evaluates whether a newly assigned window should enter reveal mode.
    private func evaluateRevealModeForAssignment(
        managed: ManagedWindow,
        screenId: CGDirectDisplayID,
        zoneIndex: Int,
        reason: String = "assignment-change",
        shouldPrimeWithRestMove: Bool = true
    ) {
        guard zoneIndex >= 2 else {
            clearRevealModeForWindow(windowId: managed.windowId, transitionToRest: true, reason: "assignment-zone<2")
            return
        }

        guard !isActiveFitSuppressed(windowId: managed.windowId), isWindowActive(managed) else {
            return
        }

        enterRevealModeIfNeeded(
            for: managed,
            screenId: screenId,
            zoneIndex: zoneIndex,
            reason: reason,
            shouldPrimeWithRestMove: shouldPrimeWithRestMove
        )
    }

    /// Called by WindowController when a frame retry chain settles (target reached or exhausted).
    /// Re-evaluates reveal mode based on the settled frame without issuing another rest-mode move.
    internal func frameRetryDidSettle(windowId: Int) {
        guard let managed = windowController.window(withId: windowId),
              let screenId = managed.screenDisplayId,
              let zoneIndex = managed.zoneIndex, zoneIndex >= 2 else { return }
        guard isWindowActive(managed) else { return }
        evaluateRevealModeForAssignment(
            managed: managed,
            screenId: screenId,
            zoneIndex: zoneIndex,
            reason: "retry-settled",
            shouldPrimeWithRestMove: false
        )
    }

    internal func isWindowActive(_ managed: ManagedWindow) -> Bool {
        let pid = managed.backing.pid
        guard let frontmostPid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              frontmostPid == pid else {
            return false
        }
        guard let focused = windowController.focusedWindowIfTracked(pid: pid) else {
            return false
        }
        return focused.windowId == managed.windowId
    }

    /// Suspends reveal mode evaluation for a window during drag operations.
    /// The window stays at its current position (reveal or rest) until the drag ends.
    internal func activeFitSuspendForDrag(windowId: Int) {
        guard activeFitSuppressedWindowIds.insert(windowId).inserted else {
            return
        }
        // Clear reveal state without transitioning to rest; window stays where user grabbed it
        clearRevealModeForWindow(windowId: windowId, transitionToRest: false, reason: "drag-begin")
        Logger.debug("ActiveFit: suspended for window \(windowId) during drag")
    }

    /// Resumes reveal mode evaluation after a drag ends and re-evaluates the window.
    internal func activeFitResumeAfterDrag(windowId: Int) {
        guard activeFitSuppressedWindowIds.remove(windowId) != nil else {
            return
        }
        Logger.debug("ActiveFit: resumed for window \(windowId) after drag")
        guard let managed = windowController.window(withId: windowId),
              let screenId = managed.screenDisplayId,
              let zoneIndex = managed.zoneIndex else {
            return
        }
        evaluateRevealModeForAssignment(managed: managed, screenId: screenId, zoneIndex: zoneIndex, reason: "drag-end")
    }

    internal func activeFitClearSuppressionForWindow(_ windowId: Int) {
        if dragDropCoordinator.currentDragWindowId == windowId {
            Logger.debug("ActiveFit: suppression retained for window \(windowId) while drag is active")
            return
        }
        activeFitSuppressedWindowIds.remove(windowId)
    }

    /// Re-evaluates reveal mode after zone topology changes (add/remove/resize).
    /// First returns any revealed window to rest mode with new zone geometry, then re-evaluates.
    internal func activeFitRefreshAfterZoneTopologyChange(reason: String) {
        guard let state = activeFitState,
              let managed = windowController.window(withId: state.windowId) else {
            return
        }

        let screenId = managed.screenDisplayId ?? state.zoneKey.screenId
        let zoneIndex = managed.zoneIndex ?? state.zoneKey.index

        // Return to rest mode first (with new zone geometry)
        exitRevealMode(reason: reason)

        guard zoneIndex >= 2,
              screenContexts[screenId]?.zoneController.zone(at: zoneIndex) != nil else {
            return
        }

        // Re-evaluate whether reveal mode is needed with new zone geometry
        evaluateRevealModeForAssignment(
            managed: managed,
            screenId: screenId,
            zoneIndex: zoneIndex,
            reason: reason
        )
    }

    private func isActiveFitSuppressed(windowId: Int) -> Bool {
        if zoneResizeDragInProgress {
            if !activeFitZoneResizeLoggedWindowIds.contains(windowId) {
                activeFitZoneResizeLoggedWindowIds.insert(windowId)
                Logger.debug("ActiveFit suppression: zone resize in progress; skipping window \(windowId)")
            }
            return true
        }
        if activeFitSuppressedWindowIds.contains(windowId) {
            Logger.debug("ActiveFit suppression: window \(windowId) is in suppressed set")
            return true
        }
        return false
    }

    /// Returns true when the window is participating in the managed layout — either as a tiled
    /// zone occupant (including placeholders) or as the occupant of a floating zone.
    private func isLayoutManagedWindow(_ managed: ManagedWindow) -> Bool {
        if managed.zoneIndex != nil {
            return true
        }
        if isWindowInFloatingZone(managed.windowId) {
            return true
        }
        return false
    }

    // MARK: - Timed suppression for restore flows

    /// Temporarily suppresses reveal mode evaluation during restore flows (WinShot, sleep/wake).
    /// After the delay, clears suppression and optionally evaluates reveal mode for the active window.
    internal func scheduleActiveFitSuppression(windowIds: [Int], evaluateRevealModeFor activeWindowId: Int? = nil) {
        for windowId in windowIds {
            activeFitSuppressedWindowIds.insert(windowId)
        }
        Logger.debug("ActiveFit: suppression scheduled for windows \(windowIds) (duration: \(activeFitRestoreDelay)s)")

        DispatchQueue.main.asyncAfter(deadline: .now() + activeFitRestoreDelay) { [weak self] in
            guard let self else { return }
            for windowId in windowIds {
                self.activeFitSuppressedWindowIds.remove(windowId)
            }
            Logger.debug("ActiveFit: suppression cleared for windows \(windowIds)")

            guard !self.screensAsleep else {
                Logger.debug("ActiveFit: skipping post-restore reveal evaluation while screens are asleep")
                return
            }

            // Evaluate reveal mode for the active window after restore settles
            if let activeWindowId,
               let managed = self.windowController.window(withId: activeWindowId),
               let screenId = managed.screenDisplayId,
               let zoneIndex = managed.zoneIndex,
               zoneIndex >= 2 {
                Logger.debug("ActiveFit: evaluating reveal mode for window \(activeWindowId) after restore")
                self.enterRevealModeAfterRestore(managed: managed, screenId: screenId, zoneIndex: zoneIndex)
            }
        }
    }

    /// Enters reveal mode for a window after a restore flow completes.
    private func enterRevealModeAfterRestore(managed: ManagedWindow, screenId: CGDirectDisplayID, zoneIndex: Int) {
        guard let context = screenContexts[screenId],
              let descriptor = descriptor(for: screenId),
              let zone = context.zoneController.zone(at: zoneIndex) else {
            return
        }

        let frameResolution = stickyResizeFrameResolution(
            for: managed,
            zone: zone,
            controller: context.zoneController
        )
        let actualFrame = windowController.actualFrameInScreenCoordinates(for: managed, on: descriptor)
        let screenBounds = descriptor.visibleScreenBounds
        let candidateSize = frameResolution.usesRememberedSize ? frameResolution.frame.size : actualFrame.size

        guard let revealFrame = ActiveFitPolicy.revealFrameIfNeeded(
            zoneIndex: zoneIndex,
            zoneOrigin: frameResolution.frame.origin,
            windowSize: candidateSize,
            screenBounds: screenBounds,
            tolerance: activeFitOverflowTolerance
        ) else {
            // Window fits in rest mode; no reveal needed
            return
        }

        let zoneKey = ZoneKey(screenId: screenId, index: zoneIndex)
        Logger.debug("ActiveFit: entering reveal mode after restore for window \(managed.windowId) -> \(revealFrame.origin)")
        windowController.moveWindow(managed, to: revealFrame, on: descriptor)
        activeFitState = ActiveFitState(windowId: managed.windowId, zoneKey: zoneKey, revealFrame: revealFrame)
        refreshResizeHandles()
    }
}
