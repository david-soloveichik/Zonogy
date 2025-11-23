import Foundation
import AppKit
import ApplicationServices

/// Manual drag/move/resize coordination for managed windows and placeholders.
extension WindowController {
    private enum ManualDragTrigger: String {
        case accessibility = "ax-moved"
        case appKit = "window-will-move"
    }

    func constrainedPlaceholderSize(for windowId: Int, proposedSize: NSSize, currentSize: NSSize) -> NSSize {
        // Placeholders are not resizable by dragging edges anymore.
        return currentSize
    }

    private func startManualDrag(for managed: ManagedWindow, with frame: CGRect, trigger: ManualDragTrigger) {
        currentDraggingWindowId = managed.windowId
        dragCandidate = nil
        let targetDescription = delegate?.debugTargetedZoneDescription() ?? "unknown"
        Logger.debug(
            "User began dragging window \(managed.windowId) (trigger: \(trigger.rawValue), targetedZone: \(targetDescription))"
        )
        delegate?.windowManualMoveDidBegin(windowId: managed.windowId, frame: frame)
    }

    // Returns true once the pointer has moved far enough (with button down) to
    // consider the gesture a live drag; false keeps accumulating movement.
    internal func ensureManualDragBegan(for managed: ManagedWindow, frame: CGRect) -> Bool {
        if currentDraggingWindowId == managed.windowId {
            return true
        }

        guard isLeftMouseButtonDown() else {
            dragCandidate = nil
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
        return false
    }

    private func isLeftMouseButtonDown() -> Bool {
        if NSEvent.pressedMouseButtons & 0x1 != 0 {
            return true
        }
        return CGEventSource.buttonState(.combinedSessionState, button: .left)
    }

    internal func handleMouseUp() {
        // If the user never crossed the activation threshold, treat the gesture as a
        // cancelled drag and trigger a manual move end so the window snaps back.
        let cancelledCandidate = dragCandidate
        dragCandidate = nil

        if let windowId = currentDraggingWindowId {
            currentDraggingWindowId = nil

            guard let managed = windowRegistry.window(withId: windowId), !managed.isPlaceholder else {
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
              let managed = windowRegistry.window(withId: candidate.windowId),
              !managed.isPlaceholder else {
            return
        }

        Logger.debug("Cancelled drag candidate for window \(managed.windowId); re-syncing to zone")
        let accessibilityFrame = actualFrameInAccessibilityCoordinates(for: managed) ?? .zero
        delegate?.windowManualMoveDidEnd(windowId: managed.windowId, finalFrame: accessibilityFrame)
    }

    func windowWillStartLiveResize(windowId: Int) {
        guard let managed = windowRegistry.window(withId: windowId) else {
            return
        }

        if !managed.isPlaceholder {
            resizingWindowId = windowId
        }
    }

    func windowDidResize(windowId: Int) {
        // No-op for placeholders as they are resized programmatically or via handles.
    }

    func windowDidEndLiveResize(windowId: Int) {
        guard let managed = windowRegistry.window(withId: windowId) else {
            return
        }

        if !managed.isPlaceholder {
            guard resizingWindowId == windowId else {
                return
            }
            resizingWindowId = nil
            Logger.debug("Finished resizing window \(windowId), notifying delegate")
            if let screenFrame = actualFrameInScreenCoordinates(for: managed) {
                delegate?.windowManualResizeDidEnd(windowId: windowId, screenId: managed.screenDisplayId, frame: screenFrame)
            } else {
                delegate?.windowManualResizeDidEnd(windowId: windowId, screenId: managed.screenDisplayId, frame: .zero)
            }
        }
    }

    func windowWillMove(windowId: Int) {
        guard let managed = windowRegistry.window(withId: windowId), !managed.isPlaceholder else {
            return
        }

        let accessibilityFrame = actualFrameInAccessibilityCoordinates(for: managed) ?? .zero
        startManualDrag(for: managed, with: accessibilityFrame, trigger: .appKit)
    }

    func windowDidMove(windowId: Int) {
        guard currentDraggingWindowId == windowId,
              let managed = windowRegistry.window(withId: windowId),
              let accessibilityFrame = actualFrameInAccessibilityCoordinates(for: managed) else {
            return
        }
        delegate?.windowManualMoveDidUpdate(windowId: windowId, frame: accessibilityFrame)
    }
}