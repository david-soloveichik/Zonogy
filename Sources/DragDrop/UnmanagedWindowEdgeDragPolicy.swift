import CoreGraphics

/// Pure policy for edge-pill drops from untracked windows that belong to manageable apps.
enum UnmanagedWindowEdgeDragPolicy {
    enum EdgeDropTarget: Equatable {
        case addZone(CGDirectDisplayID)
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
        hoveredAddZoneScreenId: CGDirectDisplayID?,
        hoveredFloatingScreenId: CGDirectDisplayID?
    ) -> EdgeDropTarget? {
        if let hoveredAddZoneScreenId {
            return .addZone(hoveredAddZoneScreenId)
        }
        if let hoveredFloatingScreenId {
            return .floatingZone(hoveredFloatingScreenId)
        }
        return nil
    }
}
