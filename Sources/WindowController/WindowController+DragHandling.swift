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

    // Returns true once the pointer has moved far enough (with button down) to
    // consider the gesture a live drag; false keeps accumulating movement.
    internal func ensureManualDragBegan(for managed: ManagedWindow, frame: CGRect) -> Bool {
        if currentDraggingWindowId == managed.windowId {
            return true
        }

        guard MouseButtons.isLeftMouseButtonDown() else {
            dragCandidate = nil
            updateMouseUpGlobalMonitorInstallation()
            return false
        }

        if let candidate = dragCandidate, candidate.windowId == managed.windowId {
            let deltaX = frame.midX - candidate.originFrame.midX
            let deltaY = frame.midY - candidate.originFrame.midY
            if hypot(deltaX, deltaY) >= dragActivationDistance {
                startManualDrag(for: managed, with: candidate.originFrame, trigger: .accessibility)
                return true
            }
            return false
        }

        dragCandidate = DragCandidate(windowId: managed.windowId, originFrame: frame)
        updateMouseUpGlobalMonitorInstallation()
        return false
    }

    internal func handleMouseUp() {
        defer {
            updateMouseUpGlobalMonitorInstallation()
        }

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
