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

        if isWindowInTemporaryZone(focused.windowId) {
            let screenIndex = screenContextStore.loggingIndex(for: focusedScreenId)
            Logger.debug("Zone removal: targeting temporary zone on screen \(screenIndex) in follows-focus mode")
            return .temporary(screenId: focusedScreenId)
        }

        return nil
    }

    internal func recordActiveWindowForHistory(windowId: Int, reason: String) {
        windowController.recordWindowActivity(windowId: windowId)
        updateTargetingFromActiveWindowIfNeeded(windowId: windowId, reason: reason)
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

        guard isWindowInTemporaryZone(windowId) else {
            return
        }

        guard let screenId = managed.screenDisplayId
            ?? temporaryZoneCoordinator.occupants.first(where: { $0.value == windowId })?.key
            ?? detectScreenId(for: managed) else {
            return
        }

        targetedZoneManager.setTemporaryTarget(
            on: screenId,
            reason: "focus-follow-\(reason)"
        )
    }
}

