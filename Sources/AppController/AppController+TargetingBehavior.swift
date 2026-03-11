/// Targeting behavior helpers, including focus-follow targeting mode.

import AppKit
import Foundation

extension AppController {
    /// Returns the target destination for the focused window when a zone is removed (follows-focus mode only).
    /// Returns nil if not in follows-focus mode or no suitable target found.
    internal func followsFocusTargetOnZoneRemoval(
        removedIndex: Int,
        removedScreenId: CGDirectDisplayID
    ) -> TargetedZoneManager.TargetedDestination? {
        guard targetingMode == .followsFocus,
              let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let focused = windowController.focusedWindowIfTracked(pid: pid),
              let focusedScreenId = focused.screenDisplayId ?? detectScreenId(for: focused) else {
            return nil
        }

        if let focusedZoneIndex = focused.zoneIndex {
            // Adjust index only if removing a zone on the same screen with lower index
            let adjustedIndex = (focusedScreenId == removedScreenId && focusedZoneIndex > removedIndex)
                ? focusedZoneIndex - 1
                : focusedZoneIndex
            let key = ZoneKey(screenId: focusedScreenId, index: adjustedIndex)
            let screenIndex = screenContextStore.loggingIndex(for: focusedScreenId)
            Logger.debug("Zone removal: targeting active window's zone \(adjustedIndex) on screen \(screenIndex) in follows-focus mode")
            return .tiled(key)
        }

        if isWindowInFloatingZone(focused.windowId) {
            let screenIndex = screenContextStore.loggingIndex(for: focusedScreenId)
            Logger.debug("Zone removal: targeting floating zone on screen \(screenIndex) in follows-focus mode")
            return .floating(screenId: focusedScreenId)
        }

        return nil
    }

    internal func recordActiveWindowForHistory(windowId: Int, reason: String) {
        cancelPendingWindowActivityRecord()
        windowController.recordWindowActivity(windowId: windowId)
        updateTargetingFromActiveWindowIfNeeded(windowId: windowId, reason: reason)
    }

    /// Update targeting immediately, but only record window activity if the window remains focused for
    /// `windowActivityRecordingStabilityDelay`.
    /// CmdTab/Launcher recency should ignore brief intermediate activations that can occur during
    /// app/window switching flows (e.g., the app's previously-frontmost window becomes key briefly).
    internal func recordActiveWindowForHistoryDebounced(windowId: Int, pid: pid_t, reason: String) {
        updateTargetingFromActiveWindowIfNeeded(windowId: windowId, reason: reason)
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

    private func updateTargetingFromActiveWindowIfNeeded(windowId: Int, reason: String) {
        guard targetingMode == .followsFocus,
              let managed = windowController.window(withId: windowId) else {
            return
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
