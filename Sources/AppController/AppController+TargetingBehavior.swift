/// Targeting helpers for explicit feature-triggered retargeting and recency history.

import AppKit
import Foundation

extension AppController {
    internal func recordActiveWindowForHistory(windowId: Int, reason: String) {
        cancelPendingWindowActivityRecord()
        windowController.recordWindowActivity(windowId: windowId)
        Logger.debug("Recorded window activity immediately for window \(windowId) (reason: \(reason))")
    }

    /// Only record window activity if the window remains focused for `windowActivityRecordingStabilityDelay`.
    /// CmdTab/Launcher recency should ignore brief intermediate activations that can occur during
    /// app/window switching flows (e.g., the app's previously-frontmost window becomes key briefly).
    internal func recordActiveWindowForHistoryDebounced(windowId: Int, pid: pid_t, reason: String) {
        Logger.debug("Scheduling debounced window activity for window \(windowId) (reason: \(reason))")
        scheduleStableWindowActivityRecording(windowId: windowId, pid: pid)
    }

    internal func cancelPendingWindowActivityRecord() {
        pendingWindowActivityRecordToken += 1
        pendingWindowActivityRecordWorkItem?.cancel()
        pendingWindowActivityRecordWorkItem = nil
    }

    internal func resolvedTriggeredTargetUsingActiveWindow() -> TargetedZoneManager.TargetedDestination? {
        let activeWindow = currentActiveManagedWindowContextForTriggeredTargeting().map {
            ActiveWindowTargetResolver.ActiveWindow(
                screenId: $0.screenId,
                zoneIndex: $0.zoneIndex,
                isInFloatingZone: $0.isInFloatingZone
            )
        }

        // Launcher never has an independent destination: if it is visible, it already occupies
        // the currently targeted destination, so feature-triggered retargeting should leave it alone.
        return ActiveWindowTriggeredTargetPolicy.resolveTarget(
            currentTarget: targetedZoneManager.targetedDestination,
            launcherOccupiesCurrentTarget: launcherController.isActive,
            activeWindow: activeWindow
        )
    }

    internal func resolvedInitialLauncherShortcutTargetUsingActiveWindow() -> TargetedZoneManager.TargetedDestination? {
        let activeWindow = currentActiveManagedWindowContextForTriggeredTargeting().map {
            ActiveWindowTargetResolver.ActiveWindow(
                screenId: $0.screenId,
                zoneIndex: $0.zoneIndex,
                isInFloatingZone: $0.isInFloatingZone
            )
        }

        return LauncherShortcutTargetPolicy.resolveInitialTarget(
            currentTarget: targetedZoneManager.targetedDestination,
            shortcutTargetsZoneWithActiveWindow: launcherShortcutTargetsZoneWithActiveWindowEnabled,
            activeWindow: activeWindow
        )
    }

    internal func resolvedRepeatedLauncherShortcutTargetUsingActiveWindow(
        existingSession: TemporaryRetargetSession?
    ) -> LauncherShortcutTargetPolicy.RepeatedShortcutResolution? {
        let activeWindow = currentActiveManagedWindowContextForTriggeredTargeting().map {
            ActiveWindowTargetResolver.ActiveWindow(
                screenId: $0.screenId,
                zoneIndex: $0.zoneIndex,
                isInFloatingZone: $0.isInFloatingZone
            )
        }

        return LauncherShortcutTargetPolicy.resolveRepeatedTarget(
            currentTarget: targetedZoneManager.targetedDestination,
            existingSession: existingSession,
            activeWindow: activeWindow
        )
    }

    /// "Toggle Target Zone w/ Focused Window" shortcut. See `FocusedWindowToggleTargetPolicy` for the
    /// decision logic. Works while the Launcher/CmdTab chooser is open (tentative retarget).
    internal func toggleTargetZoneWithFocusedWindow() {
        let currentTarget = targetedZoneManager.targetedDestination
        let action = FocusedWindowToggleTargetPolicy.resolve(
            focusedWindowDestination: resolvedFocusedWindowZoneDestination(),
            currentTarget: currentTarget,
            currentTargetIsOccupied: currentTarget.flatMap { occupant(of: $0) } != nil
        )
        let reason = "shortcut-toggle-target-focused-window"
        // The toggle is a tentative in-chooser retarget: keep a visible Launcher/CmdTab anchored to the
        // new target (don't dismiss on an occupied zone), and remember the pre-toggle target so the
        // chooser restores it on cancel (or, for CmdTab, on choosing an already-open window).
        performTentativeChooserRetarget {
            switch action {
            case .none:
                Logger.debug("Toggle target zone w/ focused window: nothing focused in a zone and targeted zone empty; no-op")
            case .target(let destination):
                Logger.debug("Toggle target zone w/ focused window: targeting focused window's zone")
                applyTargetedDestination(destination, reason: reason)
            case .advance(let from):
                Logger.debug("Toggle target zone w/ focused window: targeted zone occupied; advancing off it")
                advanceTargetOffZone(from, reason: reason)
            }
        }
    }

    /// Wrap a target-changing keyboard shortcut so a visible Launcher follows the new target
    /// instead of dismissing on occupied tiling zones, and a closed Launcher stays closed (no
    /// auto-show is triggered). Used by zone navigation's empty-zone commit and "Toggle Target
    /// Zone w/ Focused Window".
    internal func performTargetChangeKeepingLauncherVisible(_ block: () -> Void) {
        let previous = keepLauncherVisibleAcrossTargetNavigation
        keepLauncherVisibleAcrossTargetNavigation = launcherController.isActive
        defer { keepLauncherVisibleAcrossTargetNavigation = previous }
        block()
    }

    /// Runs a tentative in-chooser retarget `block`: keeps a visible Launcher/CmdTab following the new
    /// target, and (re)binds the active chooser's retarget session so cancelling restores the
    /// pre-retarget target. Outside a chooser it just performs the retarget.
    private func performTentativeChooserRetarget(_ block: () -> Void) {
        // Capture the pre-retarget target as the session baseline so cancel can restore it. Only
        // create a session if the chooser doesn't already have one (e.g. from the "target zone with
        // active window" option, whose original target we must preserve).
        if let baseline = targetedZoneManager.targetedDestination {
            if launcherController.isActive, launcherRetargetSession == nil {
                launcherRetargetSession = TemporaryRetargetSession(originalTarget: baseline, temporaryTarget: baseline)
            }
            if cmdTabController.isActive, cmdTabRetargetSession == nil {
                cmdTabRetargetSession = TemporaryRetargetSession(originalTarget: baseline, temporaryTarget: baseline)
            }
        }

        // Suppress the refresh-path session invalidation for this retarget so the session is rebound
        // (below) rather than committed; ordinary navigation/external retargets still invalidate it.
        let wasApplyingTentative = isApplyingTentativeChooserRetarget
        isApplyingTentativeChooserRetarget = true
        performTargetChangeKeepingLauncherVisible(block)
        isApplyingTentativeChooserRetarget = wasApplyingTentative

        // Rebind the active chooser's session to the new target (preserving its original) so the
        // restore-on-cancel check recognizes this as the session's current target.
        guard let current = targetedZoneManager.targetedDestination else { return }
        if let session = launcherRetargetSession {
            launcherRetargetSession = TemporaryRetargetSession(originalTarget: session.originalTarget, temporaryTarget: current)
        }
        if let session = cmdTabRetargetSession {
            cmdTabRetargetSession = TemporaryRetargetSession(originalTarget: session.originalTarget, temporaryTarget: current)
        }
    }

    /// Resolves the destination (tiling or floating zone) of the currently focused managed window,
    /// or nil if there is no focused managed window assigned to a zone.
    internal func resolvedFocusedWindowZoneDestination() -> TargetedZoneManager.TargetedDestination? {
        currentActiveManagedWindowForTriggeredTargeting().flatMap { targetedDestination(for: $0) }
    }

    /// Whether `destination` still exists: its tiling zone, or its floating zone's screen.
    internal func destinationExists(_ destination: TargetedZoneManager.TargetedDestination) -> Bool {
        switch destination {
        case .tiled(let key):
            return screenContexts[key.screenId]?.zoneController.zone(at: key.index) != nil
        case .floating(let screenId):
            return screenContexts[screenId] != nil
        }
    }

    /// The managed window `destination` currently holds, if any.
    internal func occupant(of destination: TargetedZoneManager.TargetedDestination) -> ManagedWindow? {
        switch destination {
        case .tiled(let key):
            guard let zone = screenContexts[key.screenId]?.zoneController.zone(at: key.index),
                  let windowId = zone.occupantWindowId else {
                return nil
            }
            return windowController.window(withId: windowId)
        case .floating(let screenId):
            return floatingZoneOccupant(on: screenId)
        }
    }

    /// The targeted zone is occupied, so advancing mirrors the standard retarget-after-fill.
    private func advanceTargetOffZone(
        _ destination: TargetedZoneManager.TargetedDestination,
        reason: String
    ) {
        targetedZoneManager.retargetAsIfJustFilled(destination, reason: reason)
    }

    internal func currentActiveManagedWindowForTriggeredTargeting() -> ManagedWindow? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else {
            return nil
        }

        if let focused = windowController.focusedWindowIfTracked(pid: pid),
           focused.zoneIndex != nil || isWindowInFloatingZone(focused.windowId) {
            return focused
        }

        guard let currentId = currentFrontmostManagedWindowId,
              let current = windowController.window(withId: currentId),
              current.backing.pid == pid,
              current.zoneIndex != nil || isWindowInFloatingZone(currentId) else {
            return nil
        }

        return current
    }

    internal func targetedDestination(for managed: ManagedWindow) -> TargetedZoneManager.TargetedDestination? {
        if let zoneIndex = managed.zoneIndex,
           let screenId = managed.screenDisplayId ?? detectScreenId(for: managed) {
            return .tiled(ZoneKey(screenId: screenId, index: zoneIndex))
        }

        guard isWindowInFloatingZone(managed.windowId) else {
            return nil
        }

        guard let screenId = managed.screenDisplayId
            ?? floatingZoneCoordinator.occupants.first(where: { $0.value == managed.windowId })?.key
            ?? detectScreenId(for: managed) else {
            return nil
        }

        return .floating(screenId: screenId)
    }

    internal func applyTargetedDestination(
        _ destination: TargetedZoneManager.TargetedDestination?,
        reason: String
    ) {
        guard let destination else {
            targetedZoneManager.setTargetedZone(nil, reason: reason)
            return
        }

        switch destination {
        case .tiled(let key):
            targetedZoneManager.setTargetedZone(key, reason: reason)
        case .floating(let screenId):
            targetedZoneManager.setFloatingTarget(on: screenId, reason: reason)
        }
    }

    private func scheduleStableWindowActivityRecording(windowId: Int, pid: pid_t) {
        cancelPendingWindowActivityRecord()
        let token = pendingWindowActivityRecordToken
        let focusBeganAt = Date()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.pendingWindowActivityRecordToken == token else {
                return
            }
            self.pendingWindowActivityRecordWorkItem = nil

            guard !self.isActivityRecordingSuppressed() else {
                return
            }
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
                return
            }
            guard self.currentFrontmostManagedWindowId == windowId else {
                return
            }
            guard self.windowController.window(withId: windowId) != nil else {
                return
            }

            self.windowController.recordWindowActivity(windowId: windowId, at: focusBeganAt)
        }

        pendingWindowActivityRecordWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + windowActivityRecordingStabilityDelay, execute: workItem)
    }

    private func currentActiveManagedWindowContextForTriggeredTargeting() -> (
        screenId: CGDirectDisplayID,
        zoneIndex: Int?,
        isInFloatingZone: Bool
    )? {
        currentActiveManagedWindowForTriggeredTargeting().flatMap { managed in
            targetedDestination(for: managed).flatMap { destination in
                switch destination {
                case .tiled(let key):
                    return (screenId: key.screenId, zoneIndex: key.index, isInFloatingZone: false)
                case .floating(let screenId):
                    return (screenId: screenId, zoneIndex: nil, isInFloatingZone: true)
                }
            }
        }
    }
}
