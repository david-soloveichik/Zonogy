import CoreGraphics

/// Pure geometric model for Control-Command + arrow-key target navigation.
///
/// Every targetable zone — the tiling zones on every screen plus each screen's floating zone —
/// is treated as a rectangle on one shared global plane. An arrow press moves the target to the
/// nearest zone in that physical direction. Left and Right stay within the current layer (tiling
/// or floating); only Up and Down cross between the two. This file is deterministic and OS-free so
/// it is covered by `--self-test`.

/// The four arrow directions used for target navigation.
enum ZoneNavigationDirection {
    case up
    case down
    case left
    case right
}

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
    /// Absorbs floating-point noise when deciding whether a candidate is "ahead".
    private static let directionEpsilon: CGFloat = 0.5
    /// Minimum perpendicular overlap for a candidate to count as edge-aligned with the source.
    private static let overlapTolerance: CGFloat = 1.0

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
        let sourceScreen = current.screenId
        let isVertical = (direction == .up || direction == .down)

        func isAhead(_ frame: CGRect) -> Bool {
            switch direction {
            case .right: return frame.midX > source.midX + directionEpsilon
            case .left:  return frame.midX < source.midX - directionEpsilon
            case .down:  return frame.midY > source.midY + directionEpsilon
            case .up:    return frame.midY < source.midY - directionEpsilon
            }
        }

        /// Edge-to-edge travel distance along the press axis (clamped to ≥ 0 for adjacent or
        /// overlapping zones), so "nearest in the pressed direction" prefers same-screen
        /// neighbors over the next display.
        func primaryGap(_ frame: CGRect) -> CGFloat {
            switch direction {
            case .right: return max(0, frame.minX - source.maxX)
            case .left:  return max(0, source.minX - frame.maxX)
            case .down:  return max(0, frame.minY - source.maxY)
            case .up:    return max(0, source.minY - frame.maxY)
            }
        }

        func perpendicularOverlap(_ frame: CGRect) -> CGFloat {
            if isVertical {
                return min(source.maxX, frame.maxX) - max(source.minX, frame.minX)
            } else {
                return min(source.maxY, frame.maxY) - max(source.minY, frame.minY)
            }
        }

        func perpendicularCenterDistance(_ frame: CGRect) -> CGFloat {
            isVertical ? abs(frame.midX - source.midX) : abs(frame.midY - source.midY)
        }

        func centerDistance(_ frame: CGRect) -> CGFloat {
            let dx = frame.midX - source.midX
            let dy = frame.midY - source.midY
            return (dx * dx + dy * dy).squareRoot()
        }

        /// 0 when the candidate is on the same screen as the source, 1 otherwise. Used as a
        /// tie-break so an equally-near same-screen zone (e.g. this screen's floating bar) wins
        /// over a zone on an adjacent display whose edge coincides with this one's.
        func sameScreenRank(_ id: NavigableZoneIdentifier) -> CGFloat {
            id.screenId == sourceScreen ? 0 : 1
        }

        func isEligible(_ id: NavigableZoneIdentifier) -> Bool {
            isVertical || id.isFloating == current.isFloating
        }

        let ahead = zones.filter { $0.id != current && isAhead($0.frame) && isEligible($0.id) }
        if ahead.isEmpty {
            return nil
        }

        // Prefer zones that overlap the source along the perpendicular edge; among those pick the
        // nearest in the pressed direction.
        let aligned = ahead.filter { perpendicularOverlap($0.frame) > overlapTolerance }
        if let best = bestZone(aligned, keyedBy: [
            { primaryGap($0.frame) },
            { sameScreenRank($0.id) },
            { perpendicularCenterDistance($0.frame) },
        ]) {
            return best
        }

        // Fallback so diagonally-placed displays stay reachable: nearest ahead zone by center.
        return bestZone(ahead, keyedBy: [
            { centerDistance($0.frame) },
            { sameScreenRank($0.id) },
        ])
    }

    /// Returns the id of the zone minimizing the ordered list of numeric keys, breaking exact
    /// ties with `NavigableZoneIdentifier.tieBreakKey`.
    private static func bestZone(
        _ zones: [NavigableZone],
        keyedBy keys: [(NavigableZone) -> CGFloat]
    ) -> NavigableZoneIdentifier? {
        zones.min { lhs, rhs in
            for key in keys {
                let lhsValue = key(lhs)
                let rhsValue = key(rhs)
                if lhsValue != rhsValue {
                    return lhsValue < rhsValue
                }
            }
            return tieBreakLess(lhs.id, rhs.id)
        }?.id
    }

    private static func tieBreakLess(_ lhs: NavigableZoneIdentifier, _ rhs: NavigableZoneIdentifier) -> Bool {
        let lhsKey = lhs.tieBreakKey
        let rhsKey = rhs.tieBreakKey
        if lhsKey.0 != rhsKey.0 { return lhsKey.0 < rhsKey.0 }
        if lhsKey.1 != rhsKey.1 { return lhsKey.1 < rhsKey.1 }
        return lhsKey.2 < rhsKey.2
    }
}
