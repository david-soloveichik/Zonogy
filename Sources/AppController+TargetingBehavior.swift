/// Targeting behavior helpers, including focus-follow targeting mode.

import AppKit
import Foundation

extension AppController {
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

