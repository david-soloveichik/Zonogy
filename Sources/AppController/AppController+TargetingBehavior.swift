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
        let activeWindow = currentActiveManagedWindowForTriggeredTargeting().flatMap { managed in
            targetedDestination(for: managed).flatMap { destination in
                switch destination {
                case .tiled(let key):
                    return ActiveWindowTriggeredTargetPolicy.ActiveWindow(
                        screenId: key.screenId,
                        zoneIndex: key.index,
                        isInFloatingZone: false
                    )
                case .floating(let screenId):
                    return ActiveWindowTriggeredTargetPolicy.ActiveWindow(
                        screenId: screenId,
                        zoneIndex: nil,
                        isInFloatingZone: true
                    )
                }
            }
        }

        // Launcher never has an independent destination: if it is visible, it already occupies
        // the currently targeted destination, so feature-triggered retargeting should leave it alone.
        return ActiveWindowTriggeredTargetPolicy.resolveTarget(
            currentTarget: targetedZoneManager.targetedDestination,
            launcherOccupiesCurrentTarget: launcherController.isActive,
            activeWindow: activeWindow
        )
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
}
