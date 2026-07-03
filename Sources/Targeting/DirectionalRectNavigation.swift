import CoreGraphics

/// The four arrow directions, shared by Control-Command target navigation and window-focus
/// navigation.
enum ZoneNavigationDirection {
    case up
    case down
    case left
    case right

    /// The reverse direction, used by window-focus navigation to back out of a pass-through stop.
    var opposite: ZoneNavigationDirection {
        switch self {
        case .up: return .down
        case .down: return .up
        case .left: return .right
        case .right: return .left
        }
    }
}

/// Pure "nearest rectangle in a physical direction" selector on a shared global plane.
///
/// Every candidate is a rectangle on one coordinate space (accessibility coordinates: origin at the
/// primary display's top-left, y increasing downward). Given a source rectangle and a direction, it
/// returns the id of the nearest eligible candidate strictly ahead in that direction. The selection
/// is deterministic and OS-free so it is covered by `--self-test`.
///
/// Both Control-Command gestures build on this: `DirectionalZoneNavigation` (target navigation over
/// zones) and `WindowFocusNavigation` (focus navigation over window rectangles).
enum DirectionalRectNavigation {
    /// A candidate rectangle and its identity on the shared global plane.
    struct Item<ID> {
        let id: ID
        let frame: CGRect
        /// The display this candidate lives on, used only for the same-screen tie-break.
        let screenId: CGDirectDisplayID
    }

    /// Absorbs floating-point noise when deciding whether a candidate is "ahead".
    private static let directionEpsilon: CGFloat = 0.5
    /// Minimum perpendicular overlap for a candidate to count as edge-aligned with the source.
    private static let overlapTolerance: CGFloat = 1.0

    /// Returns the id of the nearest eligible item strictly ahead of `sourceFrame` in `direction`,
    /// or nil if none qualifies. Prefers a candidate that overlaps the source along the
    /// perpendicular edge (nearest by primary-axis gap, then same-screen, then perpendicular center
    /// distance); otherwise falls back to nearest by center distance so diagonally-placed displays
    /// stay reachable. Exact ties are broken by `tieBreak`.
    static func nearest<ID>(
        from sourceFrame: CGRect,
        sourceScreenId: CGDirectDisplayID,
        direction: ZoneNavigationDirection,
        among items: [Item<ID>],
        isEligible: (ID) -> Bool = { _ in true },
        isExcluded: (ID) -> Bool,
        tieBreak: (Item<ID>, Item<ID>) -> Bool
    ) -> ID? {
        let source = sourceFrame
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
        /// overlapping candidates), so "nearest in the pressed direction" prefers same-screen
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
        /// tie-break so an equally-near same-screen candidate wins over one on an adjacent display
        /// whose edge coincides with this one's.
        func sameScreenRank(_ screenId: CGDirectDisplayID) -> CGFloat {
            screenId == sourceScreenId ? 0 : 1
        }

        let ahead = items.filter { !isExcluded($0.id) && isAhead($0.frame) && isEligible($0.id) }
        if ahead.isEmpty {
            return nil
        }

        // Prefer candidates that overlap the source along the perpendicular edge; among those pick
        // the nearest in the pressed direction.
        let aligned = ahead.filter { perpendicularOverlap($0.frame) > overlapTolerance }
        if let best = bestItem(aligned, keyedBy: [
            { primaryGap($0.frame) },
            { sameScreenRank($0.screenId) },
            { perpendicularCenterDistance($0.frame) },
        ], tieBreak: tieBreak) {
            return best
        }

        // Fallback so diagonally-placed displays stay reachable: nearest ahead candidate by center.
        return bestItem(ahead, keyedBy: [
            { centerDistance($0.frame) },
            { sameScreenRank($0.screenId) },
        ], tieBreak: tieBreak)
    }

    /// Returns the id of the item minimizing the ordered list of numeric keys, breaking exact ties
    /// with `tieBreak`.
    private static func bestItem<ID>(
        _ items: [Item<ID>],
        keyedBy keys: [(Item<ID>) -> CGFloat],
        tieBreak: (Item<ID>, Item<ID>) -> Bool
    ) -> ID? {
        items.min { lhs, rhs in
            for key in keys {
                let lhsValue = key(lhs)
                let rhsValue = key(rhs)
                if lhsValue != rhsValue {
                    return lhsValue < rhsValue
                }
            }
            return tieBreak(lhs, rhs)
        }?.id
    }
}
