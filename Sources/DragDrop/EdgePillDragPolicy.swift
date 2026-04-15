import CoreGraphics

/// Resolves precedence between edge-pill targets and underlying zone targets during drags.
enum EdgePillDragPolicy {
    enum DropDecision: Equatable {
        case addZone(CGDirectDisplayID)
        case floatingZone(CGDirectDisplayID)
        case zone(ZoneKey)
        case fallback
    }

    static func effectiveZoneHover(
        hoveredZoneKey: ZoneKey?,
        hoveredAddZoneScreenId: CGDirectDisplayID?,
        hoveredFloatingScreenId: CGDirectDisplayID?
    ) -> ZoneKey? {
        guard hoveredAddZoneScreenId == nil,
              hoveredFloatingScreenId == nil else {
            return nil
        }
        return hoveredZoneKey
    }

    static func dropDecision(
        hoveredAddZoneScreenId: CGDirectDisplayID?,
        hoveredFloatingScreenId: CGDirectDisplayID?,
        hoveredZoneKey: ZoneKey?
    ) -> DropDecision {
        if let hoveredAddZoneScreenId {
            return .addZone(hoveredAddZoneScreenId)
        }
        if let hoveredFloatingScreenId {
            return .floatingZone(hoveredFloatingScreenId)
        }
        if let hoveredZoneKey {
            return .zone(hoveredZoneKey)
        }
        return .fallback
    }
}
