import CoreGraphics

/// Control-Command + Vim-key target navigation over zones.
///
/// Every targetable zone — the tiling zones on every screen plus each screen's floating zone — is a
/// rectangle on one shared global plane. A direction press moves the target to the nearest zone in
/// that physical direction. Left and Right stay within the current layer (tiling or floating); only
/// Up and Down cross between the two. The geometry itself lives in `DirectionalRectNavigation`; this
/// file only supplies the zone-specific eligibility (layer) and tie-break rules. Deterministic and
/// OS-free so it is covered by `--self-test`.

/// Identifies a navigable target zone without depending on live AppController state.
enum NavigableZoneIdentifier: Equatable {
    case tiling(screenId: CGDirectDisplayID, index: Int)
    case floating(screenId: CGDirectDisplayID)

    /// The display this zone lives on.
    var screenId: CGDirectDisplayID {
        switch self {
        case let .tiling(screenId, _): return screenId
        case let .floating(screenId): return screenId
        }
    }

    fileprivate var isFloating: Bool {
        if case .floating = self { return true }
        return false
    }

    /// Stable ordering used only to break exact geometric ties: prefer a tiling zone over the
    /// floating zone, then a lower index, then a lower display id.
    fileprivate var tieBreakKey: (Int, Int, CGDirectDisplayID) {
        switch self {
        case let .tiling(screenId, index): return (0, index, screenId)
        case let .floating(screenId): return (1, Int.max, screenId)
        }
    }
}

/// A targetable zone and its rectangle on the shared global plane.
struct NavigableZone {
    let id: NavigableZoneIdentifier
    /// Frame in a single global coordinate space shared by all screens (accessibility
    /// coordinates: origin at the primary display's top-left, y increasing downward).
    let frame: CGRect
}

enum DirectionalZoneNavigation {
    /// Returns the zone to target when pressing `direction` from `current`, or `nil` to stay put
    /// (no eligible zone lies in that direction). For Left and Right only same-layer zones are
    /// eligible (tiling↔tiling, floating↔floating); Up and Down consider both layers.
    static func nextZone(
        from current: NavigableZoneIdentifier,
        direction: ZoneNavigationDirection,
        among zones: [NavigableZone]
    ) -> NavigableZoneIdentifier? {
        guard let source = zones.first(where: { $0.id == current })?.frame else {
            return nil
        }
        let isVertical = (direction == .up || direction == .down)
        let items = zones.map {
            DirectionalRectNavigation.Item(id: $0.id, frame: $0.frame, screenId: $0.id.screenId)
        }

        return DirectionalRectNavigation.nearest(
            from: source,
            sourceScreenId: current.screenId,
            direction: direction,
            among: items,
            isEligible: { isVertical || $0.isFloating == current.isFloating },
            isExcluded: { $0 == current },
            tieBreak: { tieBreakLess($0.id, $1.id) }
        )
    }

    private static func tieBreakLess(_ lhs: NavigableZoneIdentifier, _ rhs: NavigableZoneIdentifier) -> Bool {
        let lhsKey = lhs.tieBreakKey
        let rhsKey = rhs.tieBreakKey
        if lhsKey.0 != rhsKey.0 { return lhsKey.0 < rhsKey.0 }
        if lhsKey.1 != rhsKey.1 { return lhsKey.1 < rhsKey.1 }
        return lhsKey.2 < rhsKey.2
    }
}
