import CoreGraphics

/// Handles drag behavior for windows in the floating zone.
protocol FloatingDragHandlerHost: AnyObject {
    var isControlCommandModifierHeld: Bool { get }
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
        hoveredFloatingScreenId: CGDirectDisplayID?,
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
            if !host.isControlCommandModifierHeld {
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
        } else if host.isControlCommandModifierHeld {
            tearDownOverlaysIfNeeded(&current)
            host.promoteFloatingDragToZone(windowId: current.windowId, frame: frame, originScreenId: current.originScreenId)
            state = nil
            return
        }

        let cursorPoint = host.currentCursorAccessibilityPoint()
        current.lastCursorPoint = cursorPoint

        let addZoneTarget = host.resolveAddZoneDropTarget(cursorPoint: cursorPoint)
        let floatingTarget = host.resolveFloatingDropTarget(cursorPoint: cursorPoint)

        // Auto-promote to zone overlay when cursor is over an empty tiling zone
        if !current.requiresControlCommand {
            let emptyZone = EdgePillDragPolicy.effectiveZoneHover(
                hoveredZoneKey: host.resolveEmptyTilingZoneUnderCursor(cursorPoint: cursorPoint),
                hoveredAddZoneScreenId: addZoneTarget,
                hoveredFloatingScreenId: floatingTarget
            )
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

        if current.hoveredAddZoneScreenId != addZoneTarget {
            current.hoveredAddZoneScreenId = addZoneTarget
            host.updateAddZoneIndicatorHighlight(screenId: addZoneTarget)
        }

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

        tearDownOverlaysIfNeeded(&current)

        let finalCursorPoint = current.lastCursorPoint ?? host.currentCursorAccessibilityPoint()
        switch EdgePillDragPolicy.dropDecision(
            hoveredAddZoneScreenId: current.hoveredAddZoneScreenId,
            hoveredFloatingScreenId: current.hoveredFloatingScreenId,
            hoveredZoneKey: host.isControlCommandModifierHeld ? nil : current.hoveredEmptyZoneKey
        ) {
        case .addZone(let screenId):
            host.finalizeFloatingDrop(
                windowId: current.windowId,
                finalFrame: finalFrame,
                hoveredAddZoneScreenId: screenId,
                hoveredFloatingScreenId: nil,
                finalCursorPoint: finalCursorPoint
            )
        case .floatingZone(let screenId):
            host.finalizeFloatingDrop(
                windowId: current.windowId,
                finalFrame: finalFrame,
                hoveredAddZoneScreenId: nil,
                hoveredFloatingScreenId: screenId,
                finalCursorPoint: finalCursorPoint
            )
        case .zone(let emptyZoneKey):
            host.finalizeFloatingDropIntoEmptyZone(windowId: current.windowId, zoneKey: emptyZoneKey)
        case .fallback:
            host.finalizeFloatingDrop(
                windowId: current.windowId,
                finalFrame: finalFrame,
                hoveredAddZoneScreenId: nil,
                hoveredFloatingScreenId: nil,
                finalCursorPoint: finalCursorPoint
            )
        }
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
