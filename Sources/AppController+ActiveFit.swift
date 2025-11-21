import Foundation
import AppKit

/// Manages the ActiveFit behavior that keeps active right-column windows fully on-screen without permanently altering zones.
extension AppController {
    struct ActiveFitState {
        let windowId: Int
        var zoneKey: ZoneKey
        var appliedFrame: CGRect
    }

    internal func handleActiveFitFocusChange(pid: pid_t) {
        guard pid != getpid() else {
            activeFitDeactivate(reason: "focus-self")
            return
        }

        guard let managed = windowController.focusedWindowIfTracked(pid: pid),
              !managed.isPlaceholder,
              let zoneIndex = managed.zoneIndex,
              zoneIndex >= 2 else {
            activeFitDeactivate(reason: "focus-ineligible")
            return
        }

        guard !isActiveFitSuppressed(windowId: managed.windowId) else {
            Logger.debug("ActiveFit focus change ignored for window \(managed.windowId); behavior suppressed")
            return
        }

        let screenId = managed.screenDisplayId ?? detectScreenId(for: managed)
        guard let screenId else {
            activeFitDeactivate(reason: "focus-no-screen")
            return
        }

        applyActiveFitIfNeeded(to: managed, screenId: screenId, zoneIndex: zoneIndex, reason: "focus-change")
    }

    internal func handleActiveFitActivationCandidate(pid: pid_t?) {
        guard let pid else {
            activeFitDeactivate(reason: "workspace-no-application")
            return
        }
        handleActiveFitFocusChange(pid: pid)
    }

    internal func activeFitShouldSkipSync(for zoneKey: ZoneKey, windowId: Int) -> Bool {
        guard let state = activeFitState else {
            return false
        }
        return state.windowId == windowId && state.zoneKey == zoneKey
    }

    internal func activeFitHandleAssignmentChange(managed: ManagedWindow, screenId: CGDirectDisplayID, zoneIndex: Int?) {
        if dragDropCoordinator.currentDragWindowId == managed.windowId {
            Logger.debug("ActiveFit assignment change ignored for window \(managed.windowId); drag in progress")
            return
        }
        guard let state = activeFitState, state.windowId == managed.windowId else {
            if let zoneIndex {
                handleAssignmentForPotentialActiveFit(managed: managed, screenId: screenId, zoneIndex: zoneIndex)
            }
            return
        }

        guard let zoneIndex else {
            Logger.debug("ActiveFit clearing state for window \(managed.windowId) due to assignment removal")
            activeFitState = nil
            return
        }

        guard zoneIndex >= 2 else {
            Logger.debug("ActiveFit clearing state for window \(managed.windowId) due to reassignment to zone \(zoneIndex)")
            activeFitClearForWindowIfNeeded(windowId: managed.windowId, restoreToZone: true, reason: "assignment-zone<2")
            return
        }

        let updatedKey = ZoneKey(screenId: screenId, index: zoneIndex)
        if state.zoneKey != updatedKey {
            Logger.debug("ActiveFit updating zone key for window \(managed.windowId) to zone \(zoneIndex) on screen \(screenId)")
            activeFitState = ActiveFitState(windowId: state.windowId, zoneKey: updatedKey, appliedFrame: state.appliedFrame)
        }

        applyActiveFitIfNeeded(to: managed, screenId: screenId, zoneIndex: zoneIndex, reason: "assignment-change")
    }

    internal func activeFitClearForWindowIfNeeded(windowId: Int, restoreToZone: Bool = true, reason: String) {
        guard let state = activeFitState, state.windowId == windowId else {
            return
        }

        if restoreToZone {
            restoreActiveFitState(state: state, reason: reason)
        } else {
            Logger.debug("ActiveFit dropping state for window \(windowId) without restore (\(reason))")
            activeFitState = nil
        }
    }

    internal func activeFitDeactivate(reason: String) {
        guard let state = activeFitState else {
            return
        }
        restoreActiveFitState(state: state, reason: reason)
    }

    private func applyActiveFitIfNeeded(
        to managed: ManagedWindow,
        screenId: CGDirectDisplayID,
        zoneIndex: Int,
        reason: String
    ) {
        guard let context = screenContexts[screenId],
              let descriptor = descriptor(for: screenId),
              let zone = context.zoneController.zone(at: zoneIndex) else {
            activeFitDeactivate(reason: "missing-context")
            return
        }

        guard !isActiveFitSuppressed(windowId: managed.windowId) else {
            Logger.debug("ActiveFit apply skipped for window \(managed.windowId); behavior suppressed")
            return
        }

        let zoneFrame = frameWithMargin(for: zone, in: context.zoneController)

        // Ensure we perform the canonical zone resize before deciding whether overflow exists.
        // This prevents ActiveFit from acting on stale dimensions (e.g., when a window just moved from another screen).
        if activeFitState == nil {
            windowController.moveWindow(managed, to: zoneFrame, on: descriptor)
        }

        let targetOrigin = zoneFrame.origin
        let actualFrame = windowController.actualFrameInScreenCoordinates(for: managed, on: descriptor)
        let screenBounds = descriptor.visibleScreenBounds

        guard let revealFrame = ActiveFitPolicy.revealFrameIfNeeded(
            zoneIndex: zoneIndex,
            zoneOrigin: targetOrigin,
            windowSize: actualFrame.size,
            screenBounds: screenBounds,
            tolerance: activeFitOverflowTolerance
        ) else {
            activeFitDeactivateIfMatches(windowId: managed.windowId, reason: "no-overflow")
            return
        }

        if let existing = activeFitState, existing.windowId != managed.windowId {
            restoreActiveFitState(state: existing, reason: "handoff")
        }

        if let existing = activeFitState,
           existing.windowId == managed.windowId,
           framesClose(existing.appliedFrame, revealFrame) {
            return
        }

        let zoneKey = ZoneKey(screenId: screenId, index: zoneIndex)
        Logger.debug("ActiveFit translating window \(managed.windowId) to \(revealFrame.origin) (reason: \(reason))")
        windowController.moveWindow(managed, to: revealFrame, on: descriptor)
        activeFitState = ActiveFitState(windowId: managed.windowId, zoneKey: zoneKey, appliedFrame: revealFrame)
    }

    private func activeFitDeactivateIfMatches(windowId: Int, reason: String) {
        guard let state = activeFitState, state.windowId == windowId else {
            return
        }
        restoreActiveFitState(state: state, reason: reason)
    }

    private func restoreActiveFitState(state: ActiveFitState, reason: String) {
        guard let context = screenContexts[state.zoneKey.screenId],
              let descriptor = descriptor(for: state.zoneKey.screenId),
              let zone = context.zoneController.zone(at: state.zoneKey.index),
              let managed = windowController.window(withId: state.windowId) else {
            Logger.debug("ActiveFit clearing state for window \(state.windowId) without restore (\(reason))")
            activeFitState = nil
            return
        }

        let targetFrame = frameWithMargin(for: zone, in: context.zoneController)
        Logger.debug("ActiveFit restoring window \(state.windowId) to zone \(state.zoneKey.index) (reason: \(reason))")
        windowController.moveWindow(managed, to: targetFrame, on: descriptor)
        activeFitState = nil
    }

    private func framesClose(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) <= activeFitOverflowTolerance &&
            abs(lhs.origin.y - rhs.origin.y) <= activeFitOverflowTolerance &&
            abs(lhs.size.width - rhs.size.width) <= activeFitOverflowTolerance &&
            abs(lhs.size.height - rhs.size.height) <= activeFitOverflowTolerance
    }

    private func handleAssignmentForPotentialActiveFit(
        managed: ManagedWindow,
        screenId: CGDirectDisplayID,
        zoneIndex: Int,
        reason: String = "assignment-change"
    ) {
        guard zoneIndex >= 2 else {
            activeFitClearForWindowIfNeeded(windowId: managed.windowId, restoreToZone: true, reason: "assignment-zone<2")
            return
        }

        guard !isActiveFitSuppressed(windowId: managed.windowId), isWindowActive(managed) else {
            return
        }

        applyActiveFitIfNeeded(to: managed, screenId: screenId, zoneIndex: zoneIndex, reason: reason)
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

    internal func activeFitSuspendForDrag(windowId: Int) {
        guard activeFitSuppressedWindowIds.insert(windowId).inserted else {
            return
        }
        // Leave the window exactly where the user grabbed it; we'll snap on drop.
        activeFitClearForWindowIfNeeded(windowId: windowId, restoreToZone: false, reason: "drag-begin")
        Logger.debug("ActiveFit suspended for window \(windowId) during drag")
    }

    internal func activeFitResumeAfterDrag(windowId: Int) {
        guard activeFitSuppressedWindowIds.remove(windowId) != nil else {
            return
        }
        Logger.debug("ActiveFit resumed for window \(windowId) after drag")
        guard let managed = windowController.window(withId: windowId),
              let screenId = managed.screenDisplayId,
              let zoneIndex = managed.zoneIndex else {
            return
        }
        handleAssignmentForPotentialActiveFit(managed: managed, screenId: screenId, zoneIndex: zoneIndex, reason: "drag-end")
    }

    internal func activeFitClearSuppressionForWindow(_ windowId: Int) {
        if dragDropCoordinator.currentDragWindowId == windowId {
            Logger.debug("ActiveFit suppression retained for window \(windowId) while drag is active")
            return
        }
        activeFitSuppressedWindowIds.remove(windowId)
    }

    /// Temporarily disables and immediately reevaluates ActiveFit after structural zone changes.
    /// This ensures oversized windows snap back to the new zone geometry and reapply ActiveFit if still needed.
    internal func activeFitRefreshAfterZoneTopologyChange(reason: String) {
        guard let state = activeFitState,
              let managed = windowController.window(withId: state.windowId) else {
            return
        }

        let screenId = managed.screenDisplayId ?? state.zoneKey.screenId
        let zoneIndex = managed.zoneIndex ?? state.zoneKey.index

        activeFitDeactivate(reason: reason)

        guard zoneIndex >= 2,
              screenContexts[screenId]?.zoneController.zone(at: zoneIndex) != nil else {
            return
        }

        handleAssignmentForPotentialActiveFit(
            managed: managed,
            screenId: screenId,
            zoneIndex: zoneIndex,
            reason: reason
        )
    }

    private func isActiveFitSuppressed(windowId: Int) -> Bool {
        activeFitSuppressedWindowIds.contains(windowId)
    }
}
