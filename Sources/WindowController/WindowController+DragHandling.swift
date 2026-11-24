import Foundation
import AppKit
import ApplicationServices

/// Manual drag/move/resize coordination for managed windows and placeholders.
extension WindowController {
    private enum ManualDragTrigger: String {
        case accessibility = "ax-moved"
    }

    private func startManualDrag(for managed: ManagedWindow, with frame: CGRect, trigger: ManualDragTrigger) {
        currentDraggingWindowId = managed.windowId
        dragCandidate = nil
        updateMouseUpGlobalMonitorInstallation()
        let targetDescription = delegate?.debugTargetedZoneDescription() ?? "unknown"
        Logger.debug(
            "User began dragging window \(managed.windowId) (trigger: \(trigger.rawValue), cursorTargetedZone: \(targetDescription))"
        )
        delegate?.windowManualMoveDidBegin(windowId: managed.windowId, frame: frame)
    }

    // Returns true once the window has moved far enough (with button down) to
    // consider the gesture a live drag; false keeps accumulating movement. See
    // ManualDragGatePolicy.candidateOrigin for where movement counts from; `previousFrame`
    // is the window's frame as observed before this report.
    internal func ensureManualDragBegan(for managed: ManagedWindow, frame: CGRect, previousFrame: CGRect?) -> Bool {
        // One left button means one gesture — see ManualDragGatePolicy for the ownership rules.
        switch ManualDragGatePolicy.gate(
            windowId: managed.windowId,
            blockedUntilMouseUp: manualDragBlockedUntilMouseUp,
            cursorDrivenDragActive: delegate?.isCursorDrivenDragActive() == true,
            currentDraggingWindowId: currentDraggingWindowId
        ) {
        case .blocked:
            return false
        case .continueCurrentDrag:
            return true
        case .mayBecomeCandidate:
            break
        }

        guard MouseButtons.isLeftMouseButtonDown() else {
            dragCandidate = nil
            updateMouseUpGlobalMonitorInstallation()
            return false
        }

        let candidateOrigin = dragCandidate.flatMap { $0.windowId == managed.windowId ? $0.originFrame : nil }
        let originFrame = ManualDragGatePolicy.candidateOrigin(
            candidateOrigin: candidateOrigin,
            previousFrame: previousFrame,
            frame: frame
        )
        if ManualDragGatePolicy.startsDrag(origin: originFrame, frame: frame, threshold: dragActivationDistance) {
            startManualDrag(for: managed, with: originFrame, trigger: .accessibility)
            return true
        }
        if originFrame != candidateOrigin {
            dragCandidate = DragCandidate(windowId: managed.windowId, originFrame: originFrame)
            updateMouseUpGlobalMonitorInstallation()
        }
        return false
    }

    /// True if the window was moved by its own application within the suppression window.
    internal func isExternallyMovingRecently(windowId: Int) -> Bool {
        guard let movedAt = lastExternalMoveByWindowId[windowId] else {
            return false
        }
        return Date().timeIntervalSince(movedAt) < Self.externalMoveReassertSuppressionWindow
    }

    /// Ends manual-move tracking for `windowId` without delivering an end/abort event — for a
    /// window whose drag Zonogy terminally tore down mid-gesture (e.g. evicted from its
    /// floating zone). A no-op when no gesture involves the window; only the matching field is
    /// cleared, so cancelling a mere candidate cannot kill another window's live drag. The rest
    /// of the gesture is blocked through mouse-up: with the button still held, the window's
    /// next AX move would otherwise seed a fresh candidate and restart the drag; the block
    /// also keeps the global mouse-up monitor installed so it gets cleared. Returns whether a
    /// gesture was actually cancelled.
    @discardableResult
    internal func cancelManualDragTracking(windowId: Int) -> Bool {
        let matchedCandidate = dragCandidate?.windowId == windowId
        let matchedCurrent = currentDraggingWindowId == windowId
        guard matchedCandidate || matchedCurrent else {
            return false
        }
        if matchedCandidate {
            dragCandidate = nil
        }
        if matchedCurrent {
            currentDraggingWindowId = nil
        }
        manualDragBlockedUntilMouseUp = true
        updateMouseUpGlobalMonitorInstallation()
        return true
    }

    /// Claims the in-progress mouse gesture for a cursor-driven chooser-row drag: drops any
    /// manual-drag candidate seeded before the row crossed its drag threshold, and blocks new
    /// candidates until the gesture's mouse-up (surviving an early cancellation of the row
    /// session, e.g. via Escape, while the button stays held).
    internal func suppressManualDragUntilMouseUp() {
        dragCandidate = nil
        manualDragBlockedUntilMouseUp = true
        updateMouseUpGlobalMonitorInstallation()
    }

    /// The pointer moved with the button held. A live drag follows it even while the window's
    /// moves go unreported (macOS can stop reporting them once the pointer crosses onto another
    /// display, until release), passing along the window's last observed frame.
    internal func handleMouseDragged() {
        guard let windowId = currentDraggingWindowId,
              let frame = windowRegistry.window(withId: windowId)?.cachedFrame else {
            return
        }
        delegate?.windowManualMoveDidUpdate(windowId: windowId, frame: frame)
    }

    internal func handleMouseUp() {
        defer {
            // After the gesture's own bookkeeping below, so the action sees its outcome.
            let action = leftMouseUpAction
            leftMouseUpAction = nil
            action?()
            updateMouseUpGlobalMonitorInstallation()
        }
        manualDragBlockedUntilMouseUp = false

        // If the user never crossed the activation threshold, treat the gesture as a
        // cancelled drag and trigger a manual move end so the window snaps back.
        let cancelledCandidate = dragCandidate
        dragCandidate = nil

        if let windowId = currentDraggingWindowId {
            currentDraggingWindowId = nil

            guard let managed = windowRegistry.window(withId: windowId) else {
                // Inform the delegate that the drag died because the backing window disappeared.
                delegate?.windowManualMoveDidAbort(windowId: windowId)
                return
            }

            Logger.debug("Finished dragging window \(windowId)")
            let accessibilityFrame = actualFrameInAccessibilityCoordinates(for: managed) ?? .zero
            delegate?.windowManualMoveDidEnd(windowId: windowId, finalFrame: accessibilityFrame)
            return
        }

        guard let candidate = cancelledCandidate,
              let managed = windowRegistry.window(withId: candidate.windowId) else {
            return
        }

        Logger.debug("Cancelled drag candidate for window \(managed.windowId); re-syncing to zone")
        let accessibilityFrame = actualFrameInAccessibilityCoordinates(for: managed) ?? .zero
        delegate?.windowManualMoveDidEnd(windowId: managed.windowId, finalFrame: accessibilityFrame)
    }

}
