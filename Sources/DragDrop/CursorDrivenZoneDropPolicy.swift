import CoreGraphics

/// Pure policy for which tiling zones may highlight and accept cursor-driven drops.
enum CursorDrivenZoneDropPolicy {
    case allZones
    case emptyZonesOnlyUnlessGestureModifiers

    static func effectiveTilingZoneHover(
        hoveredZoneKey: ZoneKey?,
        hoveredZoneIsEmpty: Bool?,
        gestureModifiersHeld: Bool,
        policy: CursorDrivenZoneDropPolicy
    ) -> ZoneKey? {
        guard let hoveredZoneKey,
              let hoveredZoneIsEmpty else {
            return nil
        }

        switch policy {
        case .allZones:
            return hoveredZoneKey
        case .emptyZonesOnlyUnlessGestureModifiers:
            if hoveredZoneIsEmpty || gestureModifiersHeld {
                return hoveredZoneKey
            }
            return nil
        }
    }
}
