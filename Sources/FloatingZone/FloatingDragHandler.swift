import CoreGraphics

/// Handles drag behavior for windows in the floating zone.
protocol FloatingDragHandlerHost: AnyObject {
    func isControlCommandDragActive() -> Bool
    func currentCursorAccessibilityPoint() -> CGPoint?
    func resolveAddZoneDropTarget(cursorPoint: CGPoint?) -> CGDirectDisplayID?
    func updateAddZoneIndicatorHighlight(screenId: CGDirectDisplayID?)
    func resolveFloatingDropTarget(cursorPoint: CGPoint?) -> CGDirectDisplayID?
    func updateFloatingIndicatorHighlight(screenId: CGDirectDisplayID?)
    func promoteFloatingDragToZone(windowId: Int, frame: CGRect, originScreenId: CGDirectDisplayID?)
    func revertFloatingDragToTiled(
        windowId: Int,
        frame: CGRect,
        originZoneKey: ZoneKey?,
        originScreenId: CGDirectDisplayID?
    )
    func finalizeFloatingDrop(
        windowId: Int,
        finalFrame: CGRect,
        hoveredAddZoneScreenId: CGDirectDisplayID?,
        finalCursorPoint: CGPoint?
    )

    // Empty-zone auto-promotion for normal floating drags
    func resolveEmptyTilingZoneUnderCursor(cursorPoint: CGPoint?) -> ZoneKey?
    func presentFloatingDragOverlays()
    func tearDownFloatingDragOverlays()
    func updateFloatingDragOverlayHighlight(zoneKey: ZoneKey?)
    func finalizeFloatingDropIntoEmptyZone(windowId: Int, zoneKey: ZoneKey)
}

/// Encapsulates floating floating-zone drag behaviour so AppController stays lean.
final class FloatingDragHandler {
    private struct State {
        let windowId: Int
        let originScreenId: CGDirectDisplayID?
        let originZoneKey: ZoneKey?
        let requiresControlCommand: Bool
        var hoveredAddZoneScreenId: CGDirectDisplayID?
        var hoveredFloatingScreenId: CGDirectDisplayID?
        var hoveredEmptyZoneKey: ZoneKey?
        var isOverlayShowing: Bool = false
        var lastCursorPoint: CGPoint?
    }

    weak var host: FloatingDragHandlerHost?
    private var state: State?

    init(host: FloatingDragHandlerHost) {
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
            hoveredFloatingScreenId: nil,
            lastCursorPoint: nil
        )
    }

    func updateDrag(frame: CGRect) {
        guard var current = state, let host else {
            return
        }

        if current.requiresControlCommand {
            if !host.isControlCommandDragActive() {
                tearDownOverlaysIfNeeded(&current)
                state = nil
                host.revertFloatingDragToTiled(
                    windowId: current.windowId,
                    frame: frame,
                    originZoneKey: current.originZoneKey,
                    originScreenId: current.originScreenId
                )
                return
            }
        } else if host.isControlCommandDragActive() {
            tearDownOverlaysIfNeeded(&current)
            host.promoteFloatingDragToZone(windowId: current.windowId, frame: frame, originScreenId: current.originScreenId)
            state = nil
            return
        }

        let cursorPoint = host.currentCursorAccessibilityPoint()
        current.lastCursorPoint = cursorPoint

        // Auto-promote to zone overlay when cursor is over an empty tiling zone
        if !current.requiresControlCommand {
            let emptyZone = host.resolveEmptyTilingZoneUnderCursor(cursorPoint: cursorPoint)
            if current.hoveredEmptyZoneKey != emptyZone {
                current.hoveredEmptyZoneKey = emptyZone
                if emptyZone != nil && !current.isOverlayShowing {
                    host.presentFloatingDragOverlays()
                    current.isOverlayShowing = true
                } else if emptyZone == nil && current.isOverlayShowing {
                    host.tearDownFloatingDragOverlays()
                    current.isOverlayShowing = false
                }
                host.updateFloatingDragOverlayHighlight(zoneKey: emptyZone)
            }
        }

        let addZoneTarget = host.resolveAddZoneDropTarget(cursorPoint: cursorPoint)
        if current.hoveredAddZoneScreenId != addZoneTarget {
            current.hoveredAddZoneScreenId = addZoneTarget
            host.updateAddZoneIndicatorHighlight(screenId: addZoneTarget)
        }

        let floatingTarget = host.resolveFloatingDropTarget(cursorPoint: cursorPoint)
        if current.hoveredFloatingScreenId != floatingTarget {
            current.hoveredFloatingScreenId = floatingTarget
            host.updateFloatingIndicatorHighlight(screenId: floatingTarget)
        }

        state = current
    }

    func endDrag(finalFrame: CGRect) {
        guard var current = state, let host else {
            return
        }
        state = nil

        // Recheck modifier state: if Control-Command was pressed after the last
        // drag update, suppress the auto-promoted empty-zone drop.
        if current.hoveredEmptyZoneKey != nil && host.isControlCommandDragActive() {
            current.hoveredEmptyZoneKey = nil
        }

        tearDownOverlaysIfNeeded(&current)

        // Drop onto empty tiling zone (auto-promoted)
        if let emptyZoneKey = current.hoveredEmptyZoneKey {
            host.finalizeFloatingDropIntoEmptyZone(windowId: current.windowId, zoneKey: emptyZoneKey)
            host.updateAddZoneIndicatorHighlight(screenId: nil)
            host.updateFloatingIndicatorHighlight(screenId: nil)
            return
        }

        let finalCursorPoint = current.lastCursorPoint ?? host.currentCursorAccessibilityPoint()
        host.finalizeFloatingDrop(
            windowId: current.windowId,
            finalFrame: finalFrame,
            hoveredAddZoneScreenId: current.hoveredAddZoneScreenId,
            finalCursorPoint: finalCursorPoint
        )
        host.updateAddZoneIndicatorHighlight(screenId: nil)
        host.updateFloatingIndicatorHighlight(screenId: nil)
    }

    func abortDrag() {
        if var current = state {
            tearDownOverlaysIfNeeded(&current)
        }
        state = nil
        host?.updateAddZoneIndicatorHighlight(screenId: nil)
        host?.updateFloatingIndicatorHighlight(screenId: nil)
    }

    var isActive: Bool {
        state != nil
    }

    private func tearDownOverlaysIfNeeded(_ current: inout State) {
        if current.isOverlayShowing {
            host?.tearDownFloatingDragOverlays()
            current.isOverlayShowing = false
        }
    }
}
