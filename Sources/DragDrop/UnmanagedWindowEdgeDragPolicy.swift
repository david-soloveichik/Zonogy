import CoreGraphics

/// Pure policy for edge-pill drops from untracked windows that belong to manageable apps.
enum UnmanagedWindowEdgeDragPolicy {
    enum EdgeDropTarget: Equatable {
        case addZone(AddZonePillKey)
        case floatingZone(CGDirectDisplayID)
    }

    static func hasActivated(
        originFrame: CGRect,
        latestFrame: CGRect,
        threshold: CGFloat
    ) -> Bool {
        let deltaX = latestFrame.midX - originFrame.midX
        let deltaY = latestFrame.midY - originFrame.midY
        return hypot(deltaX, deltaY) >= threshold
    }

    static func edgeDropTarget(
        hoveredAddZonePill: AddZonePillKey?,
        hoveredFloatingScreenId: CGDirectDisplayID?
    ) -> EdgeDropTarget? {
        if let hoveredAddZonePill {
            return .addZone(hoveredAddZonePill)
        }
        if let hoveredFloatingScreenId {
            return .floatingZone(hoveredFloatingScreenId)
        }
        return nil
    }
}
