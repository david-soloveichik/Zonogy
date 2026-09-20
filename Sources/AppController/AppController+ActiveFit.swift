import Foundation
import AppKit

/// Manages ActiveFit behavior: transitioning windows between rest mode and reveal mode.
///
/// ActiveFit has two modes:
/// - **Rest mode**: Window is anchored to zone origin; may overflow off-screen (default state).
/// - **Reveal mode**: Window is shifted so entire frame fits on screen (when window is active).
///
/// Displays are independent: at most one window per display is in reveal mode, and only activity on
/// that display returns it to rest (another managed window there becoming active, or the window
/// leaving its zone). The revealed window stands in for its display's active window, so zone changes
/// on that display re-evaluate it even while the system-wide active window is elsewhere.
extension AppController {
    /// Tracks the reveal mode state for a single window.
    struct ActiveFitState {
        let windowId: Int
        var zoneKey: ZoneKey
        /// The frame applied when the window entered reveal mode.
        var revealFrame: CGRect
    }

    /// The reveal states on a display, optionally leaving out one window.
    internal func revealedActiveFitStates(on screenId: CGDirectDisplayID, excluding windowId: Int? = nil) -> [ActiveFitState] {
        activeFitStates.values.filter { $0.zoneKey.screenId == screenId && $0.windowId != windowId }
    }

    /// Handles focus changes to potentially enter or exit reveal mode.
    internal func handleActiveFitFocusChange(pid: pid_t) {
        // Zonogy's own windows are not part of the layout; like any other unmanaged focus, they
        // leave revealed windows as they are.
        guard pid != getpid() else {
            Logger.debug("ActiveFit focus change ignored for Zonogy itself")
            return
        }

        guard let managed = windowController.focusedWindowIfTracked(pid: pid) else {
            // No tracked focused window for this pid; keep any window in reveal mode as-is.
            Logger.debug("ActiveFit focus change ignored for pid \(pid); no tracked focused window")
            return
        }

        // If the newly focused window is not part of our managed layout (neither tiled nor in the
        // floating zone), we deliberately keep revealed windows in reveal mode.
        guard isLayoutManagedWindow(managed) else {
            Logger.debug("ActiveFit focus change ignored for window \(managed.windowId); not in tiled or floating zones")
            return
        }

        guard let screenId = managed.screenDisplayId ?? detectScreenId(for: managed) else {
            Logger.debug("ActiveFit focus change ignored for window \(managed.windowId); no display")
            return
        }

        // Another managed window became active on this display: return the display's revealed
        // window to rest mode before evaluating the new candidate. Skip if that window is
        // suppressed (e.g., during WinShot restore).
        for state in revealedActiveFitStates(on: screenId, excluding: managed.windowId) {
            if isActiveFitSuppressed(windowId: state.windowId) {
                Logger.debug("ActiveFit: skipping rest mode transition for window \(state.windowId); suppressed")
            } else {
                transitionToRestMode(state: state, reason: "focus-transfer")
            }
        }

        guard let zoneIndex = managed.zoneIndex else {
            // New focused window is not in a tiling zone; no reveal mode needed.
            return
        }

        guard !isActiveFitSuppressed(windowId: managed.windowId) else {
            Logger.debug("ActiveFit focus change ignored for window \(managed.windowId); behavior suppressed")
            return
        }

        guard activeFitZoneCanReveal(screenId: screenId, zoneIndex: zoneIndex) else {
            // The zone is anchored at the screen's top-left; a reveal shift could not help.
            return
        }

        evaluateRevealModeIfNeeded(for: managed, screenId: screenId, zoneIndex: zoneIndex, reason: "focus-change")
    }

    internal func handleActiveFitActivationCandidate(pid: pid_t?) {
        // No frontmost application: nothing to attribute to a display, so revealed windows stay.
        guard let pid else {
            return
        }
        handleActiveFitFocusChange(pid: pid)
    }

    /// Returns true if the window is in reveal mode and should skip zone sync repositioning.
    internal func activeFitShouldSkipSync(for zoneKey: ZoneKey, windowId: Int) -> Bool {
        activeFitStates[windowId]?.zoneKey == zoneKey
    }

    /// Handles zone assignment changes for a window that may be in reveal mode.
    internal func activeFitHandleAssignmentChange(managed: ManagedWindow, screenId: CGDirectDisplayID, zoneIndex: Int?) {
        if dragDropCoordinator.currentDragWindowId == managed.windowId {
            Logger.debug("ActiveFit assignment change ignored for window \(managed.windowId); drag in progress")
            return
        }
        guard let state = activeFitStates[managed.windowId] else {
            if let zoneIndex {
                evaluateRevealModeForAssignment(managed: managed, screenId: screenId, zoneIndex: zoneIndex)
            }
            return
        }

        guard let zoneIndex else {
            Logger.debug("ActiveFit: exiting reveal mode for window \(managed.windowId) due to assignment removal")
            activeFitStates[managed.windowId] = nil
            return
        }

        guard activeFitZoneCanReveal(screenId: screenId, zoneIndex: zoneIndex) else {
            Logger.debug("ActiveFit: exiting reveal mode for window \(managed.windowId); reassigned to zone \(zoneIndex)")
            clearRevealModeForWindow(windowId: managed.windowId, transitionToRest: true, reason: "assignment-zone-cannot-reveal")
            return
        }

        let updatedKey = ZoneKey(screenId: screenId, index: zoneIndex)
        if state.zoneKey != updatedKey {
            Logger.debug("ActiveFit: updating zone key for revealed window \(managed.windowId) to zone \(zoneIndex)")
            activeFitStates[managed.windowId] = ActiveFitState(windowId: state.windowId, zoneKey: updatedKey, revealFrame: state.revealFrame)
        }

        evaluateRevealModeIfNeeded(for: managed, screenId: screenId, zoneIndex: zoneIndex, reason: "assignment-change")
    }

    /// Clears reveal mode for a specific window, optionally transitioning it back to rest mode.
    internal func clearRevealModeForWindow(windowId: Int, transitionToRest: Bool = true, reason: String) {
        guard let state = activeFitStates[windowId] else {
            return
        }

        if transitionToRest {
            transitionToRestMode(state: state, reason: reason)
        } else {
            Logger.debug("ActiveFit: clearing reveal state for window \(windowId) without rest transition (\(reason))")
            activeFitStates[windowId] = nil
            refreshResizeHandles()
        }
    }

    /// Returns the display's revealed window (if any) to rest mode.
    internal func exitRevealMode(on screenId: CGDirectDisplayID, reason: String) {
        for state in revealedActiveFitStates(on: screenId) {
            transitionToRestMode(state: state, reason: reason)
        }
    }

    /// Evaluates whether a window should enter reveal mode and applies the transition if needed.
    ///
    /// This is the shared ActiveFit reveal pipeline used by focus changes, retry-settled
    /// re-evaluation, and post-restore reveal checks.
    private func evaluateRevealModeIfNeeded(
        for managed: ManagedWindow,
        screenId: CGDirectDisplayID,
        zoneIndex: Int,
        reason: String,
        shouldPrimeWithRestMove: Bool = true
    ) {
        guard let context = screenContexts[screenId],
              let descriptor = descriptor(for: screenId),
              let zone = context.zoneController.zone(at: zoneIndex) else {
            exitRevealMode(on: screenId, reason: "missing-context")
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
        let currentFrame = windowController.accessibilityFrameForWindow(element: managed.backing.element, on: descriptor)
        let effectiveCandidateFrame = windowController.resolvedTargetScreenFrame(
            for: managed,
            requestedFrame: candidateFrame,
            on: descriptor,
            currentScreenFrame: currentFrame
        )

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
        // Skip this priming move after a frame-retry settle callback to avoid starting a new retry
        // loop, and for a manually resized (detached) window, whose custom size is the candidate.
        if activeFitStates[managed.windowId] == nil {
            if manualResizeDetachedWindowIds.contains(managed.windowId) {
                Logger.debug("ActiveFit: evaluating detached window \(managed.windowId) at its manual size without rest-mode priming move")
            } else if shouldPrimeWithRestMove {
                windowController.moveWindow(managed, to: candidateFrame, on: descriptor)
            } else {
                Logger.debug("ActiveFit: evaluating settled frame for window \(managed.windowId) without rest-mode priming move")
            }
        }

        let actualFrame = windowController.actualFrameInScreenCoordinates(for: managed, on: descriptor)
        let screenBounds = descriptor.visibleScreenBounds
        let candidateSize = frameResolution.usesRememberedSize ? effectiveCandidateFrame.size : actualFrame.size

        // An attached sheet (e.g. a save dialog) travels with the window but can extend past
        // its frame, so its overhang counts toward the overflow check and the reveal shift.
        // When measurement is transiently unavailable it must not read as "no sheets": for a
        // window already in reveal mode that would exit reveal and snap its sheet off screen,
        // so keep the current reveal state instead.
        let measuredSheetFrames = windowController.attachedSheetFrames(for: managed, on: descriptor)
        if measuredSheetFrames == nil, activeFitStates[managed.windowId] != nil {
            Logger.debug("ActiveFit: keeping reveal state for window \(managed.windowId); sheet measurement unavailable")
            return
        }
        let sheetOverhang = ActiveFitPolicy.attachmentOverhang(
            windowFrame: actualFrame,
            attachedFrames: measuredSheetFrames ?? []
        )
        if sheetOverhang != .none {
            Logger.debug(
                "ActiveFit: window \(managed.windowId) has sheet overhang " +
                "(left: \(sheetOverhang.left), right: \(sheetOverhang.right), " +
                "top: \(sheetOverhang.top), bottom: \(sheetOverhang.bottom))"
            )
        }

        // Check if window (plus sheet overhang) would overflow in rest mode and needs reveal mode
        guard let revealFrame = ActiveFitPolicy.revealFrameIfNeeded(
            zoneFrame: zone.frame,
            zoneOrigin: candidateFrame.origin,
            windowSize: candidateSize,
            overhang: sheetOverhang,
            screenBounds: screenBounds,
            tolerance: activeFitOverflowTolerance
        ) else {
            // Window fits on screen in rest mode; no reveal needed
            clearRevealModeForWindow(windowId: managed.windowId, reason: "no-overflow")
            return
        }

        // Only one window per display is revealed: return this display's other revealed window
        // to rest mode first.
        for other in revealedActiveFitStates(on: screenId, excluding: managed.windowId) {
            transitionToRestMode(state: other, reason: "handoff")
        }

        // Skip only if the cached reveal state still matches both the desired and actual frames.
        if let existing = activeFitStates[managed.windowId] {
            if ActiveFitRevealStatePolicy.shouldReuseExistingRevealFrame(
                existingRevealFrame: existing.revealFrame,
                desiredRevealFrame: revealFrame,
                actualFrame: actualFrame,
                tolerance: activeFitOverflowTolerance
            ) {
                return
            }

            if framesClose(existing.revealFrame, revealFrame) {
                Logger.debug(
                    "ActiveFit: reapplying reveal frame for window \(managed.windowId); " +
                    "cached reveal state no longer matches actual frame"
                )
            }
        }

        // Enter reveal mode: shift window to fit on screen
        let zoneKey = ZoneKey(screenId: screenId, index: zoneIndex)
        Logger.debug("ActiveFit: entering reveal mode for window \(managed.windowId) -> \(revealFrame.origin) (\(reason))")
        windowController.moveWindow(managed, to: revealFrame, on: descriptor)
        activeFitStates[managed.windowId] = ActiveFitState(windowId: managed.windowId, zoneKey: zoneKey, revealFrame: revealFrame)
        refreshResizeHandles()
    }

    /// Transitions a window from reveal mode back to rest mode (zone-anchored position).
    private func transitionToRestMode(state: ActiveFitState, reason: String) {
        guard let managed = windowController.window(withId: state.windowId) else {
            Logger.debug("ActiveFit: clearing reveal state for window \(state.windowId) without rest transition (\(reason))")
            activeFitStates[state.windowId] = nil
            return
        }

        let restZoneKey = ActiveFitRevealStatePolicy.restTransitionZoneKey(
            cachedZoneKey: state.zoneKey,
            currentScreenId: managed.screenDisplayId,
            currentZoneIndex: managed.zoneIndex
        )

        guard let context = screenContexts[restZoneKey.screenId],
              let descriptor = descriptor(for: restZoneKey.screenId),
              let zone = context.zoneController.zone(at: restZoneKey.index) else {
            Logger.debug("ActiveFit: clearing reveal state for window \(state.windowId) without rest transition (\(reason))")
            activeFitStates[state.windowId] = nil
            return
        }

        let restResolution = stickyResizeFrameResolution(
            for: managed,
            zone: zone,
            controller: context.zoneController
        )
        Logger.debug("ActiveFit: returning window \(state.windowId) to rest mode in zone \(restZoneKey.index) (\(reason))")

        // Clear state before moving window to avoid race condition with frame retry checks
        activeFitStates[state.windowId] = nil
        windowController.moveWindow(managed, to: restResolution.frame, on: descriptor)
        // Resting at the plain zone frame ends any manual-resize detachment; the manual snapback
        // leaves revealed windows to ActiveFit.
        if !restResolution.usesRememberedSize {
            manualResizeDetachedWindowIds.remove(state.windowId)
        }
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
        guard activeFitZoneCanReveal(screenId: screenId, zoneIndex: zoneIndex) else {
            clearRevealModeForWindow(windowId: managed.windowId, transitionToRest: true, reason: "assignment-zone-cannot-reveal")
            return
        }

        guard !isActiveFitSuppressed(windowId: managed.windowId), isWindowActive(managed) else {
            return
        }

        evaluateRevealModeIfNeeded(
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
              let zoneIndex = managed.zoneIndex,
              activeFitZoneCanReveal(screenId: screenId, zoneIndex: zoneIndex) else { return }
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

    /// Drops the drag suppression without re-evaluating reveal state — for terminal gesture
    /// teardown, where the window is leaving its assignment (or the zone system) and
    /// evaluating the stale assignment could move the frame it is about to lose.
    internal func activeFitClearDragSuppression(windowId: Int) {
        if activeFitSuppressedWindowIds.remove(windowId) != nil {
            Logger.debug("ActiveFit: cleared drag suppression for window \(windowId) (terminal teardown)")
        }
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

    /// Re-evaluates reveal mode after zone topology changes (add/remove/resize) on one display, or on
    /// every display when `screenId` is nil. Each revealed window there first returns to rest mode
    /// with the new zone geometry and is then re-evaluated.
    internal func activeFitRefreshAfterZoneTopologyChange(on screenId: CGDirectDisplayID? = nil, reason: String) {
        let states = activeFitStates.values.filter { screenId == nil || $0.zoneKey.screenId == screenId }
        for state in states {
            transitionToRestMode(state: state, reason: reason)
            activeFitReevaluateRestedWindow(windowId: state.windowId, reason: reason)
        }
    }

    /// Re-evaluates a window that a zone change on its display just returned from reveal to rest
    /// mode. The revealed window stands in for its display's active window, so unlike a first entry
    /// into reveal mode this does not require it to be the system-wide active window. The window
    /// already sits at its rest frame, so no priming move is issued.
    internal func activeFitReevaluateRestedWindow(windowId: Int, reason: String) {
        guard let managed = windowController.window(withId: windowId),
              let screenId = managed.screenDisplayId,
              let zoneIndex = managed.zoneIndex,
              activeFitZoneCanReveal(screenId: screenId, zoneIndex: zoneIndex) else {
            return
        }
        evaluateRevealModeIfNeeded(
            for: managed,
            screenId: screenId,
            zoneIndex: zoneIndex,
            reason: reason,
            shouldPrimeWithRestMove: false
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

    /// Whether the zone at (screenId, zoneIndex) could benefit from a reveal shift.
    /// See ActiveFitPolicy.zoneCanReveal.
    internal func activeFitZoneCanReveal(screenId: CGDirectDisplayID, zoneIndex: Int) -> Bool {
        guard let context = screenContexts[screenId],
              let zone = context.zoneController.zone(at: zoneIndex),
              let descriptor = descriptor(for: screenId) else {
            return false
        }
        return ActiveFitPolicy.zoneCanReveal(zoneFrame: zone.frame, screenBounds: descriptor.visibleScreenBounds)
    }

    /// Returns true when the window is participating in the managed layout — either as a tiled
    /// zone occupant (including placeholders) or as the occupant of a floating zone.
    internal func isLayoutManagedWindow(_ managed: ManagedWindow) -> Bool {
        if managed.zoneIndex != nil {
            return true
        }
        if isWindowInFloatingZone(managed.windowId) {
            return true
        }
        return false
    }

    // MARK: - Timed suppression for restore flows

    /// Temporarily suppresses reveal mode evaluation while a restore flow (WinShot) repositions the
    /// given windows, dropping any reveal state they carry since the restore overwrites their frames.
    /// After the delay, clears suppression and optionally evaluates reveal mode for the active window.
    internal func scheduleActiveFitSuppression(windowIds: [Int], evaluateRevealModeFor activeWindowId: Int? = nil) {
        for windowId in windowIds {
            clearRevealModeForWindow(windowId: windowId, transitionToRest: false, reason: "restore")
            activeFitSuppressedWindowIds.insert(windowId)
        }
        Logger.debug("ActiveFit: suppression scheduled for windows \(windowIds) (duration: \(activeFitRestoreDelay)s)")

        DispatchQueue.main.asyncAfter(deadline: .now() + activeFitRestoreDelay) { [weak self] in
            guard let self else { return }
            for windowId in windowIds {
                self.activeFitSuppressedWindowIds.remove(windowId)
            }
            Logger.debug("ActiveFit: suppression cleared for windows \(windowIds)")

            guard !self.sleepWakeProtectionActive else {
                Logger.debug("ActiveFit: skipping post-restore reveal evaluation while sleep/wake protection is active")
                return
            }

            // Evaluate reveal mode for the active window after restore settles
            if let activeWindowId,
               let managed = self.windowController.window(withId: activeWindowId),
               let screenId = managed.screenDisplayId,
               let zoneIndex = managed.zoneIndex,
               self.activeFitZoneCanReveal(screenId: screenId, zoneIndex: zoneIndex) {
                Logger.debug("ActiveFit: evaluating reveal mode for window \(activeWindowId) after restore")
                self.evaluateRevealModeIfNeeded(
                    for: managed,
                    screenId: screenId,
                    zoneIndex: zoneIndex,
                    reason: "restore-settled",
                    shouldPrimeWithRestMove: false
                )
            }
        }
    }
}
