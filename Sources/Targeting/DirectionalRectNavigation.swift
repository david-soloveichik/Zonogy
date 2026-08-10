import CoreGraphics

/// The four arrow directions of Control-Command zone navigation.
enum ZoneNavigationDirection {
    case up
    case down
    case left
    case right

    /// The reverse direction; a press in this direction backs zone navigation's trail out of its
    /// last move.
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
/// returns the id of the nearest candidate strictly ahead in that direction. The selection is
/// deterministic and OS-free so it is covered by `--self-test`.
///
/// `ZoneNavigation` uses this for its cross-screen exits; moves within a screen are structural and
/// never race rectangles.
enum DirectionalRectNavigation {
    /// A candidate rectangle and its identity on the shared global plane.
    struct Item<ID> {
        let id: ID
        let frame: CGRect
    }

    /// Absorbs floating-point noise when deciding whether a candidate is "ahead".
    private static let directionEpsilon: CGFloat = 0.5
    /// Minimum perpendicular overlap for a candidate to count as edge-aligned with the source.
    private static let overlapTolerance: CGFloat = 1.0

    /// Whether `frame` lies ahead of `source` in `direction` (center comparison, shared epsilon).
    /// Exposed for policy-level ordering rules layered on the generic selector.
    static func isAhead(_ frame: CGRect, of source: CGRect, direction: ZoneNavigationDirection) -> Bool {
        switch direction {
        case .right: return frame.midX > source.midX + directionEpsilon
        case .left:  return frame.midX < source.midX - directionEpsilon
        case .down:  return frame.midY > source.midY + directionEpsilon
        case .up:    return frame.midY < source.midY - directionEpsilon
        }
    }

    /// Returns the id of the nearest item strictly ahead of `sourceFrame` in `direction`, or nil
    /// if none qualifies. Prefers a candidate that overlaps the source along the perpendicular
    /// edge (nearest by primary-axis gap, then perpendicular center distance); otherwise falls
    /// back to nearest by center distance so diagonally-placed displays stay reachable. Exact
    /// ties are broken by `tieBreak`.
    static func nearest<ID>(
        from sourceFrame: CGRect,
        direction: ZoneNavigationDirection,
        among items: [Item<ID>],
        tieBreak: (Item<ID>, Item<ID>) -> Bool
    ) -> ID? {
        let source = sourceFrame
        let isVertical = (direction == .up || direction == .down)

        func isAhead(_ frame: CGRect) -> Bool {
            Self.isAhead(frame, of: source, direction: direction)
        }

        /// Edge-to-edge travel distance along the press axis (clamped to ≥ 0 for adjacent or
        /// overlapping candidates), so "nearest in the pressed direction" prefers the closest
        /// display's zones.
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

        let ahead = items.filter { isAhead($0.frame) }
        if ahead.isEmpty {
            return nil
        }

        // Prefer candidates that overlap the source along the perpendicular edge; among those pick
        // the nearest in the pressed direction.
        let aligned = ahead.filter { perpendicularOverlap($0.frame) > overlapTolerance }
        if let best = bestItem(aligned, keyedBy: [
            { primaryGap($0.frame) },
            { perpendicularCenterDistance($0.frame) },
        ], tieBreak: tieBreak) {
            return best
        }

        // Fallback so diagonally-placed displays stay reachable: nearest ahead candidate by center.
        return bestItem(ahead, keyedBy: [
            { centerDistance($0.frame) },
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
