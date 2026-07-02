import Foundation

/// The tiling layout model: which screen halves zones live on and which edges carry add-zone bars.
///
/// Zones tile the screen as two side-by-side columns. A side holding two zones stacks them
/// top/bottom (lower zone index on top); a side holding none cedes the full width to the other.
/// The layout style fixes each side's capacity and, for the single-bar styles, which side each
/// zone index belongs to.

/// Which screen half a tiling zone belongs to.
enum ZoneSide: String, CaseIterable, Hashable {
    case left
    case right

    var opposite: ZoneSide {
        self == .left ? .right : .left
    }
}

/// User-selectable tiling layout.
enum ZoneLayoutStyle: String, CaseIterable {
    /// Add-zone bar on the right edge; zone 1 fills the left side. Up to 3 zones.
    case rightBar
    /// Mirror image: add-zone bar on the left edge; zone 1 fills the right side. Up to 3 zones.
    case leftBar
    /// Add-zone bars on both edges; each side holds up to two zones. Up to 4 zones.
    case dualBar

    /// Screen edges that display an add-zone bar.
    var barSides: [ZoneSide] {
        switch self {
        case .rightBar:
            return [.right]
        case .leftBar:
            return [.left]
        case .dualBar:
            return [.left, .right]
        }
    }

    /// Maximum number of zones a side can hold.
    func sideCapacity(_ side: ZoneSide) -> Int {
        switch self {
        case .rightBar:
            return side == .right ? 2 : 1
        case .leftBar:
            return side == .left ? 2 : 1
        case .dualBar:
            return 2
        }
    }

    var maxZoneCount: Int {
        ZoneSide.allCases.reduce(0) { $0 + sideCapacity($1) }
    }

    /// Side order tried for adds that do not come from a specific add-zone bar
    /// (keyboard shortcut, startup seeding, forced zone counts).
    var preferredAddSideOrder: [ZoneSide] {
        switch self {
        case .rightBar:
            return [.right]
        case .leftBar:
            return [.left]
        case .dualBar:
            return [.right, .left]
        }
    }

    /// The fixed side for each zone index in the single-bar styles, or `nil` for `dualBar`,
    /// where side membership is state carried by the zones (it depends on which bar added them).
    func fixedSides(zoneCount: Int) -> [ZoneSide]? {
        switch self {
        case .rightBar:
            return Array([ZoneSide.left, .right, .right].prefix(max(1, zoneCount)))
        case .leftBar:
            return Array([ZoneSide.right, .left, .left].prefix(max(1, zoneCount)))
        case .dualBar:
            return nil
        }
    }

    /// Canonical sides for a fresh set of `zoneCount` zones, following `preferredAddSideOrder`.
    /// Used when sides cannot be carried over (seeding, forced counts, degenerate repairs).
    func canonicalSides(zoneCount: Int) -> [ZoneSide] {
        if let fixed = fixedSides(zoneCount: zoneCount) {
            return fixed
        }
        // dualBar fill order: full screen, left|right, then right stacks, then left stacks.
        return Array([ZoneSide.left, .right, .right, .left].prefix(max(1, zoneCount)))
    }
}
