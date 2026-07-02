import CoreGraphics

/// Resolves precedence between edge-pill targets and underlying zone targets during drags.
enum EdgePillDragPolicy {
    enum DropDecision: Equatable {
        case addZone(AddZonePillKey)
        case floatingZone(CGDirectDisplayID)
        case zone(ZoneKey)
        case fallback
    }

    static func effectiveZoneHover(
        hoveredZoneKey: ZoneKey?,
        hoveredAddZonePill: AddZonePillKey?,
        hoveredFloatingScreenId: CGDirectDisplayID?
    ) -> ZoneKey? {
        guard hoveredAddZonePill == nil,
              hoveredFloatingScreenId == nil else {
            return nil
        }
        return hoveredZoneKey
    }

    static func dropDecision(
        hoveredAddZonePill: AddZonePillKey?,
        hoveredFloatingScreenId: CGDirectDisplayID?,
        hoveredZoneKey: ZoneKey?
    ) -> DropDecision {
        if let hoveredAddZonePill {
            return .addZone(hoveredAddZonePill)
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
