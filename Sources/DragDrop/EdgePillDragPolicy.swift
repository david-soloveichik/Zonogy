import CoreGraphics

/// Resolves precedence between edge-pill targets and underlying zone targets during drags. A
/// floating zone hovered through its window counts as its pill.
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

    /// The floating zone hovered at `point`: through an indicator (the targeted zone's first, should
    /// indicators overlap) or, since edge indicators win over the windows beneath them, else through
    /// one of `floatingWindowFrames`.
    static func floatingTarget(
        at point: CGPoint,
        indicatorHitAreas: [CGDirectDisplayID: CGRect],
        targetedScreenId: CGDirectDisplayID?,
        floatingWindowFrames: [CGDirectDisplayID: CGRect] = [:]
    ) -> CGDirectDisplayID? {
        if let targetedScreenId, indicatorHitAreas[targetedScreenId]?.contains(point) == true {
            return targetedScreenId
        }
        if let screenId = indicatorHitAreas.first(where: { $0.value.contains(point) })?.key {
            return screenId
        }
        return floatingWindowFrames.first(where: { $0.value.contains(point) })?.key
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
