import CoreGraphics

/// Handles drag behavior for windows in the temporary (floating) zone.
protocol TemporaryDragHandlerHost: AnyObject {
    func isControlCommandDragActive() -> Bool
    func currentCursorAccessibilityPoint() -> CGPoint?
    func resolveAddZoneDropTarget(cursorPoint: CGPoint?) -> CGDirectDisplayID?
    func updateAddZoneIndicatorHighlight(screenId: CGDirectDisplayID?)
    func resolveTemporaryDropTarget(cursorPoint: CGPoint?) -> CGDirectDisplayID?
    func updateTemporaryIndicatorHighlight(screenId: CGDirectDisplayID?)
    func promoteFloatingDragToZone(windowId: Int, frame: CGRect, originScreenId: CGDirectDisplayID?)
    func revertTemporaryDragToTiled(
        windowId: Int,
        frame: CGRect,
        originZoneKey: ZoneKey?,
        originScreenId: CGDirectDisplayID?
    )
    func finalizeFloatingTemporaryDrop(
        windowId: Int,
        finalFrame: CGRect,
        hoveredAddZoneScreenId: CGDirectDisplayID?,
        finalCursorPoint: CGPoint?
    )
}

/// Encapsulates floating temporary-zone drag behaviour so AppController stays lean.
final class TemporaryDragHandler {
    private struct State {
        let windowId: Int
        let originScreenId: CGDirectDisplayID?
        let originZoneKey: ZoneKey?
        let requiresControlCommand: Bool
        var hoveredAddZoneScreenId: CGDirectDisplayID?
        var hoveredTemporaryScreenId: CGDirectDisplayID?
        var lastCursorPoint: CGPoint?
    }

    weak var host: TemporaryDragHandlerHost?
    private var state: State?

    init(host: TemporaryDragHandlerHost) {
        self.host = host
    }

    func beginDrag(
        windowId: Int,
        originScreenId: CGDirectDisplayID?,
        originZoneKey: ZoneKey? = nil,
        requiresControlCommand: Bool = false
    ) {
        state = State(
            windowId: windowId,
            originScreenId: originScreenId,
            originZoneKey: originZoneKey,
            requiresControlCommand: requiresControlCommand,
            hoveredAddZoneScreenId: nil,
            hoveredTemporaryScreenId: nil,
            lastCursorPoint: nil
        )
    }

    func updateDrag(frame: CGRect) {
        guard var current = state, let host else {
            return
        }

        if current.requiresControlCommand {
            if !host.isControlCommandDragActive() {
                state = nil
                host.revertTemporaryDragToTiled(
                    windowId: current.windowId,
                    frame: frame,
                    originZoneKey: current.originZoneKey,
                    originScreenId: current.originScreenId
                )
                return
            }
        } else if host.isControlCommandDragActive() {
            host.promoteFloatingDragToZone(windowId: current.windowId, frame: frame, originScreenId: current.originScreenId)
            state = nil
            return
        }

        let cursorPoint = host.currentCursorAccessibilityPoint()
        current.lastCursorPoint = cursorPoint
        let addZoneTarget = host.resolveAddZoneDropTarget(cursorPoint: cursorPoint)
        if current.hoveredAddZoneScreenId != addZoneTarget {
            current.hoveredAddZoneScreenId = addZoneTarget
            host.updateAddZoneIndicatorHighlight(screenId: addZoneTarget)
        }

        let temporaryTarget = host.resolveTemporaryDropTarget(cursorPoint: cursorPoint)
        if current.hoveredTemporaryScreenId != temporaryTarget {
            current.hoveredTemporaryScreenId = temporaryTarget
            host.updateTemporaryIndicatorHighlight(screenId: temporaryTarget)
        }

        state = current
    }

    func endDrag(finalFrame: CGRect) {
        guard let current = state, let host else {
            return
        }
        state = nil
        let finalCursorPoint = current.lastCursorPoint ?? host.currentCursorAccessibilityPoint()
        host.finalizeFloatingTemporaryDrop(
            windowId: current.windowId,
            finalFrame: finalFrame,
            hoveredAddZoneScreenId: current.hoveredAddZoneScreenId,
            finalCursorPoint: finalCursorPoint
        )
        host.updateAddZoneIndicatorHighlight(screenId: nil)
        host.updateTemporaryIndicatorHighlight(screenId: nil)
    }

    func abortDrag() {
        state = nil
        host?.updateAddZoneIndicatorHighlight(screenId: nil)
        host?.updateTemporaryIndicatorHighlight(screenId: nil)
    }

    var isActive: Bool {
        state != nil
    }
}
