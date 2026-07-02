import CoreGraphics

/// Handles drag behavior for windows in the floating zone.
protocol FloatingDragHandlerHost: AnyObject {
    var areGestureModifiersHeld: Bool { get }
    func currentCursorAccessibilityPoint() -> CGPoint?
    func resolveAddZoneDropTarget(cursorPoint: CGPoint?) -> AddZonePillKey?
    func updateAddZoneIndicatorHighlight(pill: AddZonePillKey?)
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
        hoveredAddZonePill: AddZonePillKey?,
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
        let requiresGestureModifiers: Bool
        var hoveredAddZonePill: AddZonePillKey?
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
        requiresGestureModifiers: Bool = false
    ) {
        state = State(
            windowId: windowId,
            originScreenId: originScreenId,
            originZoneKey: originZoneKey,
            requiresGestureModifiers: requiresGestureModifiers,
            hoveredAddZonePill: nil,
            hoveredFloatingScreenId: nil,
            lastCursorPoint: nil
        )
    }

    func updateDrag(frame: CGRect) {
        guard var current = state, let host else {
            return
        }

        if current.requiresGestureModifiers {
            if !host.areGestureModifiersHeld {
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
        } else if host.areGestureModifiersHeld {
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
        if !current.requiresGestureModifiers {
            let emptyZone = EdgePillDragPolicy.effectiveZoneHover(
                hoveredZoneKey: host.resolveEmptyTilingZoneUnderCursor(cursorPoint: cursorPoint),
                hoveredAddZonePill: addZoneTarget,
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

        if current.hoveredAddZonePill != addZoneTarget {
            current.hoveredAddZonePill = addZoneTarget
            host.updateAddZoneIndicatorHighlight(pill: addZoneTarget)
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
            hoveredAddZonePill: current.hoveredAddZonePill,
            hoveredFloatingScreenId: current.hoveredFloatingScreenId,
            hoveredZoneKey: host.areGestureModifiersHeld ? nil : current.hoveredEmptyZoneKey
        ) {
        case .addZone(let pill):
            host.finalizeFloatingDrop(
                windowId: current.windowId,
                finalFrame: finalFrame,
                hoveredAddZonePill: pill,
                hoveredFloatingScreenId: nil,
                finalCursorPoint: finalCursorPoint
            )
        case .floatingZone(let screenId):
            host.finalizeFloatingDrop(
                windowId: current.windowId,
                finalFrame: finalFrame,
                hoveredAddZonePill: nil,
                hoveredFloatingScreenId: screenId,
                finalCursorPoint: finalCursorPoint
            )
        case .zone(let emptyZoneKey):
            host.finalizeFloatingDropIntoEmptyZone(windowId: current.windowId, zoneKey: emptyZoneKey)
        case .fallback:
            host.finalizeFloatingDrop(
                windowId: current.windowId,
                finalFrame: finalFrame,
                hoveredAddZonePill: nil,
                hoveredFloatingScreenId: nil,
                finalCursorPoint: finalCursorPoint
            )
        }
        host.updateAddZoneIndicatorHighlight(pill: nil)
        host.updateFloatingIndicatorHighlight(screenId: nil)
    }

    func abortDrag() {
        if var current = state {
            tearDownOverlaysIfNeeded(&current)
        }
        state = nil
        host?.updateAddZoneIndicatorHighlight(pill: nil)
        host?.updateFloatingIndicatorHighlight(screenId: nil)
    }

    var isActive: Bool {
        state != nil
    }

    /// The window currently being dragged in the floating zone, if any.
    var draggingWindowId: Int? {
        state?.windowId
    }

    private func tearDownOverlaysIfNeeded(_ current: inout State) {
        if current.isOverlayShowing {
            host?.tearDownFloatingDragOverlays()
            current.isOverlayShowing = false
        }
    }
}
