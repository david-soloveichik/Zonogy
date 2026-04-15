import CoreGraphics

/// Pure policy for which tiling zones may highlight and accept cursor-driven drops.
enum CursorDrivenZoneDropPolicy {
    case allZones
    case emptyZonesOnlyUnlessControlCommand

    static func effectiveTilingZoneHover(
        hoveredZoneKey: ZoneKey?,
        hoveredZoneIsEmpty: Bool?,
        isControlCommandHeld: Bool,
        policy: CursorDrivenZoneDropPolicy
    ) -> ZoneKey? {
        guard let hoveredZoneKey,
              let hoveredZoneIsEmpty else {
            return nil
        }

        switch policy {
        case .allZones:
            return hoveredZoneKey
        case .emptyZonesOnlyUnlessControlCommand:
            if hoveredZoneIsEmpty || isControlCommandHeld {
                return hoveredZoneKey
            }
            return nil
        }
    }
}
