/// Targeting behavior helpers, including focus-follow targeting mode.

import AppKit
import Foundation

extension AppController {
    internal func retargetToActiveTiledWindowAfterFloatingZoneEmptyingIfNeeded(
        emptiedFloatingScreenId: CGDirectDisplayID,
        excludingWindowId removedWindowId: Int,
        reason: String
    ) {
        guard targetingMode == .followsFocus else {
            return
        }

        guard let destination = activeTiledWindowDestinationForFloatingZoneEmptyRetarget(
            excludingWindowId: removedWindowId
        ) else {
            Logger.debug(
                "Floating zone emptied on screen \(screenContextStore.loggingIndex(for: emptiedFloatingScreenId)); " +
                "no active tiled window available for follows-focus retarget (reason: \(reason))"
            )
            return
        }

        Logger.debug(
            "Floating zone emptied on screen \(screenContextStore.loggingIndex(for: emptiedFloatingScreenId)); " +
            "follows-focus retarget -> zone \(destination.index) on screen " +
            "\(screenContextStore.loggingIndex(for: destination.screenId)) (reason: \(reason))"
        )
        targetedZoneManager.setTargetedZone(
            destination,
            reason: "floating-emptied-\(reason)"
        )
    }

    /// Returns the target destination when a zone is removed in follows-focus mode.
    /// Delegates to FollowsFocusZoneRemovalPolicy for the pure selection logic.
    internal func followsFocusTargetOnZoneRemoval(
        removedIndex: Int,
        removedScreenId: CGDirectDisplayID
    ) -> TargetedZoneManager.TargetedDestination? {
        guard targetingMode == .followsFocus else { return nil }

        let activeCandidate: FollowsFocusZoneRemovalPolicy.Candidate? = {
            guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
                  let focused = windowController.focusedWindowIfTracked(pid: pid),
                  let screenId = focused.screenDisplayId ?? detectScreenId(for: focused) else {
                return nil
            }
            return FollowsFocusZoneRemovalPolicy.Candidate(
                windowId: focused.windowId,
                zoneIndex: focused.zoneIndex,
                screenId: screenId,
                isInFloatingZone: isWindowInFloatingZone(focused.windowId)
            )
        }()

        let recencyCandidates: [FollowsFocusZoneRemovalPolicy.Candidate] = windowController.allWindowsOrderedByRecency().compactMap { window in
            guard let screenId = window.screenDisplayId ?? detectScreenId(for: window) else { return nil }
            return FollowsFocusZoneRemovalPolicy.Candidate(
                windowId: window.windowId,
                zoneIndex: window.zoneIndex,
                screenId: screenId,
                isInFloatingZone: isWindowInFloatingZone(window.windowId)
            )
        }

        let destination = FollowsFocusZoneRemovalPolicy.selectDestination(
            activeCandidate: activeCandidate,
            recencyCandidates: recencyCandidates,
            removedIndex: removedIndex,
            removedScreenId: removedScreenId
        )

        Logger.debug("Zone removal: follows-focus retarget → \(destination) (active=\(activeCandidate != nil))")
        return destination
    }

    internal func recordActiveWindowForHistory(windowId: Int, reason: String) {
        cancelPendingWindowActivityRecord()
        windowController.recordWindowActivity(windowId: windowId)
        updateTargetingFromActiveWindowIfNeeded(windowId: windowId, reason: reason)
    }

    /// Update targeting immediately when this activation would change shared managed-window recency,
    /// but only record window activity if the window remains focused for
    /// `windowActivityRecordingStabilityDelay`.
    /// CmdTab/Launcher recency should ignore brief intermediate activations that can occur during
    /// app/window switching flows (e.g., the app's previously-frontmost window becomes key briefly).
    internal func recordActiveWindowForHistoryDebounced(windowId: Int, pid: pid_t, reason: String) {
        if shouldSuppressFollowsFocusRetargetDuringActivation(pid: pid, reason: reason) {
            return
        }

        // In follows-focus mode, only retarget if this window is not already the most recently
        // active managed window. This avoids spurious retargeting from OS re-activation
        // notifications for the already-active window, which could override the user's manual
        // targeting choice.
        if !windowController.isMostRecentlyActive(windowId: windowId) {
            updateTargetingFromActiveWindowIfNeeded(windowId: windowId, reason: reason)
        }
        scheduleStableWindowActivityRecording(windowId: windowId, pid: pid)
    }

    internal func cancelPendingWindowActivityRecord() {
        pendingWindowActivityRecordToken += 1
        pendingWindowActivityRecordWorkItem?.cancel()
        pendingWindowActivityRecordWorkItem = nil
    }

    internal func retargetToFocusedWindowZoneIfPossible(reason: String) {
        guard targetingMode == .followsFocus,
              let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let focused = windowController.focusedWindowIfTracked(pid: pid) else {
            return
        }

        updateTargetingFromActiveWindowIfNeeded(windowId: focused.windowId, reason: reason)
    }

    private func activeTiledWindowDestinationForFloatingZoneEmptyRetarget(
        excludingWindowId removedWindowId: Int
    ) -> ZoneKey? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else {
            return nil
        }

        let activeManaged: ManagedWindow? = {
            if let focused = windowController.focusedWindowIfTracked(pid: pid),
               focused.windowId != removedWindowId {
                return focused
            }

            if let currentId = currentFrontmostManagedWindowId,
               currentId != removedWindowId,
               let current = windowController.window(withId: currentId),
               current.backing.pid == pid,
               (current.zoneIndex != nil || isWindowInFloatingZone(currentId)) {
                return current
            }

            return nil
        }()

        guard let activeManaged,
              let zoneIndex = activeManaged.zoneIndex,
              let screenId = activeManaged.screenDisplayId ?? detectScreenId(for: activeManaged) else {
            return nil
        }

        return FollowsFocusZoneRemovalPolicy.selectFloatingZoneEmptyDestination(
            activeScreenId: screenId,
            activeZoneIndex: zoneIndex
        )
    }

    private func updateTargetingFromActiveWindowIfNeeded(windowId: Int, reason: String) {
        guard targetingMode == .followsFocus,
              let managed = windowController.window(withId: windowId) else {
            return
        }

        // Check empty-zone retarget protection: when a tiled window was just closed/minimized
        // and its zone retargeted, suppress the automatic same-app sibling focus fallback.
        let now = Date()
        if let protection = emptyZoneRetargetProtection {
            if now >= protection.deadline {
                emptyZoneRetargetProtection = nil
            } else if EmptyZoneRetargetProtectionPolicy.shouldSuppressRetarget(
                protectedZone: protection.zone,
                protectedPid: protection.pid,
                protectedWindowId: protection.fallbackWindowId,
                currentTarget: targetedZoneManager.targetedDestination,
                incomingPid: managed.backing.pid,
                incomingWindowId: managed.windowId,
                deadline: protection.deadline,
                now: now
            ) {
                Logger.debug(
                    "Suppressing follows-focus retarget for window \(windowId) — " +
                    "preserving empty-zone retarget on zone \(protection.zone.index) " +
                    "(protected fallback window \(protection.fallbackWindowId), reason: \(reason))"
                )
                return
            }
        }

        if let zoneIndex = managed.zoneIndex {
            guard let screenId = managed.screenDisplayId ?? detectScreenId(for: managed) else {
                return
            }
            targetedZoneManager.setTargetedZone(
                ZoneKey(screenId: screenId, index: zoneIndex),
                reason: "focus-follow-\(reason)"
            )
            return
        }

        guard isWindowInFloatingZone(windowId) else {
            return
        }

        guard let screenId = managed.screenDisplayId
            ?? floatingZoneCoordinator.occupants.first(where: { $0.value == windowId })?.key
            ?? detectScreenId(for: managed) else {
            return
        }

        targetedZoneManager.setFloatingTarget(
            on: screenId,
            reason: "focus-follow-\(reason)"
        )
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
}
