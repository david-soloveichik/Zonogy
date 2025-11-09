import Foundation
import AppKit

/// Manages the KeyFit behavior that keeps active right-column windows fully on-screen without permanently altering zones.
extension AppController {
    struct KeyFitState {
        let windowId: Int
        var zoneKey: ZoneKey
        var appliedFrame: CGRect
    }

    internal func handleKeyFitFocusChange(pid: pid_t) {
        guard pid != getpid() else {
            keyFitDeactivate(reason: "focus-self")
            return
        }

        guard let managed = windowController.focusedWindowIfTracked(pid: pid),
              !managed.isPlaceholder,
              let zoneIndex = managed.zoneIndex,
              zoneIndex >= 2 else {
            keyFitDeactivate(reason: "focus-ineligible")
            return
        }

        guard !isKeyFitSuppressed(windowId: managed.windowId) else {
            Logger.debug("KeyFit focus change ignored for window \(managed.windowId); behavior suppressed")
            return
        }

        let screenId = managed.screenDisplayId ?? detectScreenId(for: managed)
        guard let screenId else {
            keyFitDeactivate(reason: "focus-no-screen")
            return
        }

        applyKeyFitIfNeeded(to: managed, screenId: screenId, zoneIndex: zoneIndex, reason: "focus-change")
    }

    internal func handleKeyFitActivationCandidate(pid: pid_t?) {
        guard let pid else {
            keyFitDeactivate(reason: "workspace-no-application")
            return
        }
        handleKeyFitFocusChange(pid: pid)
    }

    internal func keyFitShouldSkipSync(for zoneKey: ZoneKey, windowId: Int) -> Bool {
        guard let state = keyFitState else {
            return false
        }
        return state.windowId == windowId && state.zoneKey == zoneKey
    }

    internal func keyFitHandleAssignmentChange(managed: ManagedWindow, screenId: CGDirectDisplayID, zoneIndex: Int?) {
        guard let state = keyFitState, state.windowId == managed.windowId else {
            if let zoneIndex {
                handleAssignmentForPotentialKeyFit(managed: managed, screenId: screenId, zoneIndex: zoneIndex)
            }
            return
        }

        guard let zoneIndex else {
            Logger.debug("KeyFit clearing state for window \(managed.windowId) due to assignment removal")
            keyFitState = nil
            return
        }

        guard zoneIndex >= 2 else {
            Logger.debug("KeyFit clearing state for window \(managed.windowId) due to reassignment to zone \(zoneIndex)")
            keyFitClearForWindowIfNeeded(windowId: managed.windowId, restoreToZone: true, reason: "assignment-zone<2")
            return
        }

        let updatedKey = ZoneKey(screenId: screenId, index: zoneIndex)
        if state.zoneKey != updatedKey {
            Logger.debug("KeyFit updating zone key for window \(managed.windowId) to zone \(zoneIndex) on screen \(screenId)")
            keyFitState = KeyFitState(windowId: state.windowId, zoneKey: updatedKey, appliedFrame: state.appliedFrame)
        }

        applyKeyFitIfNeeded(to: managed, screenId: screenId, zoneIndex: zoneIndex, reason: "assignment-change")
    }

    internal func keyFitClearForWindowIfNeeded(windowId: Int, restoreToZone: Bool = true, reason: String) {
        guard let state = keyFitState, state.windowId == windowId else {
            return
        }

        if restoreToZone {
            restoreKeyFitState(state: state, reason: reason)
        } else {
            Logger.debug("KeyFit dropping state for window \(windowId) without restore (\(reason))")
            keyFitState = nil
        }
    }

    internal func keyFitDeactivate(reason: String) {
        guard let state = keyFitState else {
            return
        }
        restoreKeyFitState(state: state, reason: reason)
    }

    private func applyKeyFitIfNeeded(
        to managed: ManagedWindow,
        screenId: CGDirectDisplayID,
        zoneIndex: Int,
        reason: String
    ) {
        guard let context = screenContexts[screenId],
              let descriptor = descriptor(for: screenId),
              let zone = context.zoneController.zone(at: zoneIndex) else {
            keyFitDeactivate(reason: "missing-context")
            return
        }

        guard !isKeyFitSuppressed(windowId: managed.windowId) else {
            Logger.debug("KeyFit apply skipped for window \(managed.windowId); behavior suppressed")
            return
        }

        let targetOrigin = frameWithMargin(for: zone, in: context.zoneController).origin
        let actualFrame = windowController.actualFrameInScreenCoordinates(for: managed, on: descriptor)
        let screenBounds = descriptor.visibleScreenBounds

        guard let revealFrame = KeyFitPolicy.revealFrameIfNeeded(
            zoneIndex: zoneIndex,
            zoneOrigin: targetOrigin,
            windowSize: actualFrame.size,
            screenBounds: screenBounds,
            tolerance: keyFitOverflowTolerance
        ) else {
            keyFitDeactivateIfMatches(windowId: managed.windowId, reason: "no-overflow")
            return
        }

        if let existing = keyFitState, existing.windowId != managed.windowId {
            restoreKeyFitState(state: existing, reason: "handoff")
        }

        if let existing = keyFitState,
           existing.windowId == managed.windowId,
           framesClose(existing.appliedFrame, revealFrame) {
            return
        }

        let zoneKey = ZoneKey(screenId: screenId, index: zoneIndex)
        Logger.debug("KeyFit translating window \(managed.windowId) to \(revealFrame.origin) (reason: \(reason))")
        windowController.moveWindow(managed, to: revealFrame, on: descriptor)
        keyFitState = KeyFitState(windowId: managed.windowId, zoneKey: zoneKey, appliedFrame: revealFrame)
    }

    private func keyFitDeactivateIfMatches(windowId: Int, reason: String) {
        guard let state = keyFitState, state.windowId == windowId else {
            return
        }
        restoreKeyFitState(state: state, reason: reason)
    }

    private func restoreKeyFitState(state: KeyFitState, reason: String) {
        guard let context = screenContexts[state.zoneKey.screenId],
              let descriptor = descriptor(for: state.zoneKey.screenId),
              let zone = context.zoneController.zone(at: state.zoneKey.index),
              let managed = windowController.window(withId: state.windowId) else {
            Logger.debug("KeyFit clearing state for window \(state.windowId) without restore (\(reason))")
            keyFitState = nil
            return
        }

        let targetFrame = frameWithMargin(for: zone, in: context.zoneController)
        Logger.debug("KeyFit restoring window \(state.windowId) to zone \(state.zoneKey.index) (reason: \(reason))")
        windowController.moveWindow(managed, to: targetFrame, on: descriptor)
        keyFitState = nil
    }

    private func framesClose(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) <= keyFitOverflowTolerance &&
            abs(lhs.origin.y - rhs.origin.y) <= keyFitOverflowTolerance &&
            abs(lhs.size.width - rhs.size.width) <= keyFitOverflowTolerance &&
            abs(lhs.size.height - rhs.size.height) <= keyFitOverflowTolerance
    }

    private func handleAssignmentForPotentialKeyFit(
        managed: ManagedWindow,
        screenId: CGDirectDisplayID,
        zoneIndex: Int,
        reason: String = "assignment-change"
    ) {
        guard zoneIndex >= 2 else {
            keyFitClearForWindowIfNeeded(windowId: managed.windowId, restoreToZone: true, reason: "assignment-zone<2")
            return
        }

        guard !isKeyFitSuppressed(windowId: managed.windowId), isWindowActive(managed) else {
            return
        }

        applyKeyFitIfNeeded(to: managed, screenId: screenId, zoneIndex: zoneIndex, reason: reason)
    }

    private func isWindowActive(_ managed: ManagedWindow) -> Bool {
        if managed.isPlaceholder {
            return false
        }

        switch managed.backing {
        case .appKit(let window):
            return window.isKeyWindow
        case .accessibility(_, let pid, _):
            guard let frontmostPid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
                  frontmostPid == pid else {
                return false
            }
            guard let focused = windowController.focusedWindowIfTracked(pid: pid) else {
                return false
            }
            return focused.windowId == managed.windowId
        }
    }

    internal func keyFitSuspendForDrag(windowId: Int) {
        guard keyFitSuppressedWindowIds.insert(windowId).inserted else {
            return
        }
        // Leave the window exactly where the user grabbed it; we'll snap on drop.
        keyFitClearForWindowIfNeeded(windowId: windowId, restoreToZone: false, reason: "drag-begin")
        Logger.debug("KeyFit suspended for window \(windowId) during drag")
    }

    internal func keyFitResumeAfterDrag(windowId: Int) {
        guard keyFitSuppressedWindowIds.remove(windowId) != nil else {
            return
        }
        Logger.debug("KeyFit resumed for window \(windowId) after drag")
        guard let managed = windowController.window(withId: windowId),
              let screenId = managed.screenDisplayId,
              let zoneIndex = managed.zoneIndex else {
            return
        }
        handleAssignmentForPotentialKeyFit(managed: managed, screenId: screenId, zoneIndex: zoneIndex, reason: "drag-end")
    }

    internal func keyFitClearSuppressionForWindow(_ windowId: Int) {
        keyFitSuppressedWindowIds.remove(windowId)
    }

    /// Temporarily disables and immediately reevaluates KeyFit after structural zone changes.
    /// This ensures oversized windows snap back to the new zone geometry and reapply KeyFit if still needed.
    internal func keyFitRefreshAfterZoneTopologyChange(reason: String) {
        guard let state = keyFitState,
              let managed = windowController.window(withId: state.windowId) else {
            return
        }

        let screenId = managed.screenDisplayId ?? state.zoneKey.screenId
        let zoneIndex = managed.zoneIndex ?? state.zoneKey.index

        keyFitDeactivate(reason: reason)

        guard zoneIndex >= 2,
              screenContexts[screenId]?.zoneController.zone(at: zoneIndex) != nil else {
            return
        }

        handleAssignmentForPotentialKeyFit(
            managed: managed,
            screenId: screenId,
            zoneIndex: zoneIndex,
            reason: reason
        )
    }

    private func isKeyFitSuppressed(windowId: Int) -> Bool {
        keyFitSuppressedWindowIds.contains(windowId)
    }
}
