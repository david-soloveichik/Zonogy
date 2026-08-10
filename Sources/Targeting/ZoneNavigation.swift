import CoreGraphics

/// Pure selection policy for keyboard zone navigation.
///
/// Navigation considers every zone: each tiling zone — filled or empty — plus each screen's
/// floating zone at its bottom-edge bar, occupied or not.
///
/// Moves on a screen are structural, read from the zone model rather than from frames — dragged
/// split ratios never change where a press lands. Each tiling zone sits in a column (its side) at
/// a row (`StackRow`), with the bar as the screen's bottom-most stop below both columns: up and
/// down walk a column's stack and the bar, while left and right cross between the columns,
/// landing in the matching row (bottom to bottom; top and full-height to the top). Keeping the
/// floating zone at its bar rather than at its occupant window also keeps selection independent
/// of where that window sits.
///
/// A move with no stop left on the screen exits it, and only exits are geometric:
/// `DirectionalRectNavigation` races the other screens' zones and bars for the nearest rectangle
/// in the pressed direction. Two bar rules are imposed on that race: bars never join horizontal
/// races (a bar can overlap the zone frames and would steal left/right crossings), and an upward
/// exit stops at the entered screen's bar before its zones. Downward needs no rule — the only
/// structural move off a screen's bottom is from the bar itself.
///
/// Every selection carries the trail of moves that produced it: pressing the exact opposite of the
/// move that arrived somewhere backs out to that move's source, step by step, all the way to the
/// gesture's start. Moves are lossy (a full-height column reached from a stack's bottom re-enters
/// the stack at its top), so reversal is remembered, not recomputed.
///
/// Alongside the moves, this file also holds the pure policy for the gesture's Add Zone and
/// Remove Zone keys: the side a mid-gesture add stacks into, and where the circle lands after the
/// selected zone is removed.
///
/// Deterministic and OS-free so it is covered by `--self-test`. The live gesture, the blue-circle
/// overlay, and the commit actions are wired up in `AppController+ZoneNavigationGesture`, driven by
/// `ZoneNavigationInterceptor`.

/// Identifies a navigable zone without depending on live AppController state.
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

    var isFloating: Bool {
        if case .floating = self { return true }
        return false
    }

    /// The zone index of a tiling zone; past every real index for the floating zone, so
    /// lowest-index preferences never pick a bar.
    fileprivate var indexKey: Int {
        if case let .tiling(_, index) = self { return index }
        return Int.max
    }

    /// Stable ordering used only to break exact geometric ties in cross-screen exits: prefer a
    /// tiling zone over the floating zone, then a lower index, then a lower display id.
    fileprivate var tieBreakKey: (Int, Int, CGDirectDisplayID) {
        switch self {
        case let .tiling(screenId, index): return (0, index, screenId)
        case let .floating(screenId): return (1, Int.max, screenId)
        }
    }
}

enum ZoneNavigation {
    /// A tiling zone's row within its column: the full column height, or the top or bottom of a
    /// two-zone stack.
    enum StackRow: Equatable {
        case full
        case top
        case bottom
    }

    /// Structural position of a tiling zone on its screen: the column it tiles on and its row
    /// within that column's stack.
    struct ColumnPlace: Equatable {
        let side: ZoneSide
        let row: StackRow
    }

    /// A navigable zone: its rectangle on the shared global (accessibility-coordinate) plane,
    /// and — for a tiling zone — its structural position (nil exactly for a floating zone's bar).
    struct Candidate: Equatable {
        let id: NavigableZoneIdentifier
        let frame: CGRect
        /// Whether a window occupies this zone (gesture-time snapshot; commits re-read live
        /// occupancy).
        let isOccupied: Bool
        let place: ColumnPlace?
    }

    /// One recorded move: the zone it started from and the pressed direction.
    struct Move: Equatable {
        let source: NavigableZoneIdentifier
        let direction: ZoneNavigationDirection
    }

    /// A selected zone plus the trail of moves that led to it. Pressing the opposite of the
    /// trail's last move backs out to that move's source instead of resolving a fresh move.
    struct Selection: Equatable {
        let id: NavigableZoneIdentifier
        let trail: [Move]
    }

    /// Selection produced by the first (engaging) arrow press.
    ///
    /// - When a managed window is focused, the press moves off its zone to the next zone in the
    ///   pressed direction. (While the Launcher is open the caller passes no focused zone, so
    ///   the gesture starts from the Launcher's zone — the targeted zone below.)
    /// - Otherwise navigation starts from the targeted zone: a filled target is selected in place
    ///   (regardless of direction, so tap-and-release focuses its window); an empty target moves
    ///   immediately.
    /// - `fallbackZoneId` covers the remaining no-focus, no-resolvable-target case.
    ///
    /// A press with no zone in the pressed direction selects the start zone in place — the circle
    /// appears where the gesture starts rather than nothing happening. Returns nil only when no
    /// start resolves (no candidates).
    static func initialSelection(
        direction: ZoneNavigationDirection,
        focusedZoneId: NavigableZoneIdentifier?,
        targetedZoneId: NavigableZoneIdentifier?,
        fallbackZoneId: NavigableZoneIdentifier?,
        candidates: [Candidate]
    ) -> Selection? {
        if let focusedZoneId,
           let focused = candidates.first(where: { $0.id == focusedZoneId }) {
            return move(from: focused, direction: direction, candidates: candidates)
        }

        if let targetedZoneId,
           let target = candidates.first(where: { $0.id == targetedZoneId }) {
            if target.isOccupied {
                return Selection(id: target.id, trail: [])
            }
            return move(from: target, direction: direction, candidates: candidates)
        }

        guard let fallbackZoneId,
              let fallback = candidates.first(where: { $0.id == fallbackZoneId }) else {
            return nil
        }
        return move(from: fallback, direction: direction, candidates: candidates)
    }

    /// Selection produced by a subsequent arrow press. Pressing the opposite of the move that
    /// arrived at the current selection pops back to that move's source; any other press moves
    /// from the current selection. Stays on the current selection when no zone lies in the
    /// pressed direction.
    static func nextSelection(
        direction: ZoneNavigationDirection,
        currentSelection: Selection,
        candidates: [Candidate]
    ) -> Selection {
        guard let current = candidates.first(where: { $0.id == currentSelection.id }) else {
            return currentSelection
        }

        if let last = currentSelection.trail.last, direction == last.direction.opposite {
            return Selection(id: last.source, trail: Array(currentSelection.trail.dropLast()))
        }

        guard let next = destination(from: current, direction: direction, candidates: candidates) else {
            return currentSelection
        }
        return Selection(
            id: next,
            trail: currentSelection.trail + [Move(source: current.id, direction: direction)]
        )
    }

    // MARK: - Add Zone / Remove Zone keys (mid-gesture topology changes)

    /// Side preference for the gesture's Add Zone key: when the selected tiling zone is alone in
    /// its column — and that column can take another zone — the new zone stacks into the selected
    /// zone's column. Otherwise nil defers to the layout style's normal fill order: a lone
    /// full-screen zone has no columns, a stacked column already pairs the selected zone, and a
    /// full side cannot take the zone. The screen's total zone maximum is enforced by the add
    /// itself.
    static func stackedAddSide(
        selectedZoneSide: ZoneSide,
        zonesOnScreen: Int,
        zonesOnSelectedSide: Int,
        selectedSideCapacity: Int
    ) -> ZoneSide? {
        guard zonesOnScreen > 1,
              zonesOnSelectedSide == 1,
              zonesOnSelectedSide < selectedSideCapacity else {
            return nil
        }
        return selectedZoneSide
    }

    /// Where the circle lands after the gesture's Remove Zone key removes the selected zone: the
    /// removed zone's screen's tiling zone that takes over most of the removed frame (ties break
    /// in the stable zone order). Nil when that screen retains no tiling zone — a state a valid
    /// removal cannot produce — so the caller ends the gesture rather than jumping screens.
    static func selectionAfterRemoval(
        removedFrame: CGRect,
        screenId: CGDirectDisplayID,
        candidates: [Candidate]
    ) -> NavigableZoneIdentifier? {
        var best: Candidate?
        var bestArea = -CGFloat.greatestFiniteMagnitude
        for candidate in candidates where !candidate.id.isFloating && candidate.id.screenId == screenId {
            let overlap = candidate.frame.intersection(removedFrame)
            let area = overlap.isNull ? 0 : overlap.width * overlap.height
            if area > bestArea || (area == bestArea && best.map({ tieBreakLess(candidate.id, $0.id) }) == true) {
                best = candidate
                bestArea = area
            }
        }
        return best?.id
    }

    // MARK: - Move resolution

    /// Move off `source`, recording it as the selection's trail — or `source` itself selected in
    /// place when no zone lies in the pressed direction.
    private static func move(
        from source: Candidate,
        direction: ZoneNavigationDirection,
        candidates: [Candidate]
    ) -> Selection {
        guard let next = destination(from: source, direction: direction, candidates: candidates) else {
            return Selection(id: source.id, trail: [])
        }
        return Selection(id: next, trail: [Move(source: source.id, direction: direction)])
    }

    /// The zone a press moves to from `source`, or nil when nothing lies that way: the screen's
    /// structural stop in the pressed direction when it still has one, otherwise the geometric
    /// exit onto another screen.
    private static func destination(
        from source: Candidate,
        direction: ZoneNavigationDirection,
        candidates: [Candidate]
    ) -> NavigableZoneIdentifier? {
        withinScreenDestination(from: source, direction: direction, candidates: candidates)
            ?? exitDestination(from: source, direction: direction, candidates: candidates)
    }

    /// The structural within-screen move (see the header), or nil when the press leaves the
    /// screen: up from the top of the layout, down from the bar, or a horizontal press with no
    /// column that way.
    private static func withinScreenDestination(
        from source: Candidate,
        direction: ZoneNavigationDirection,
        candidates: [Candidate]
    ) -> NavigableZoneIdentifier? {
        let screen = candidates.filter { $0.id.screenId == source.id.screenId }
        let tiling = screen.filter { $0.place != nil }
        // Every multi-zone screen occupies both sides (a ZoneController invariant); only a lone
        // full-screen zone leaves a side empty, and it spans the full width — no column to
        // cross to horizontally.
        let hasBothColumns = ZoneSide.allCases.allSatisfy { side in
            tiling.contains { $0.place?.side == side }
        }

        func zone(_ side: ZoneSide, _ row: StackRow) -> NavigableZoneIdentifier? {
            tiling.first { $0.place == ColumnPlace(side: side, row: row) }?.id
        }
        /// The bottom-most zone of a column: the stack's bottom, or its lone full-height zone.
        func bottomMost(_ side: ZoneSide) -> NavigableZoneIdentifier? {
            zone(side, .bottom) ?? zone(side, .full)
        }

        guard let place = source.place else {
            // The bar: up climbs into the bottom row (the lower zone index wins between two
            // bottom zones), left/right go to that column's bottom-most zone, down exits.
            switch direction {
            case .up:
                return tiling
                    .filter { $0.place?.row != .top }
                    .min { $0.id.indexKey < $1.id.indexKey }?.id
            case .down:
                return nil
            case .left:
                return hasBothColumns ? bottomMost(.left) : nil
            case .right:
                return hasBothColumns ? bottomMost(.right) : nil
            }
        }

        switch direction {
        case .up:
            return place.row == .bottom ? zone(place.side, .top) : nil
        case .down:
            if place.row == .top {
                return zone(place.side, .bottom)
            }
            return screen.first { $0.id.isFloating }?.id
        case .left, .right:
            let target: ZoneSide = direction == .left ? .left : .right
            guard hasBothColumns, place.side != target else { return nil }
            // Row-matched landing: bottom stays bottom; top and full-height enter at the top.
            if let full = zone(target, .full) {
                return full
            }
            return zone(target, place.row == .bottom ? .bottom : .top)
        }
    }

    /// Geometric exit onto another screen: the nearest other-screen zone in the pressed
    /// direction. Bars never join horizontal races, and an upward exit stops at the entered
    /// screen's bar before its zones.
    private static func exitDestination(
        from source: Candidate,
        direction: ZoneNavigationDirection,
        candidates: [Candidate]
    ) -> NavigableZoneIdentifier? {
        let others = candidates.filter { $0.id.screenId != source.id.screenId }
        let vertical = direction == .up || direction == .down
        let eligible = vertical ? others : others.filter { !$0.id.isFloating }
        let winner = DirectionalRectNavigation.nearest(
            from: source.frame,
            direction: direction,
            among: eligible.map { DirectionalRectNavigation.Item(id: $0.id, frame: $0.frame) },
            tieBreak: { tieBreakLess($0.id, $1.id) }
        )
        guard let winner, direction == .up else { return winner }
        return entryBar(before: winner, from: source, candidates: candidates) ?? winner
    }

    /// Entering a screen from below stops at its bar first: an upward exit whose winner is a
    /// tiling zone is redirected to that zone's screen's bar — when the bar exists and actually
    /// lies ahead (a diagonal screen's bar can sit below the source and is not forced).
    private static func entryBar(
        before winner: NavigableZoneIdentifier,
        from source: Candidate,
        candidates: [Candidate]
    ) -> NavigableZoneIdentifier? {
        guard !winner.isFloating else { return nil }
        let barId = NavigableZoneIdentifier.floating(screenId: winner.screenId)
        guard let bar = candidates.first(where: { $0.id == barId }),
              DirectionalRectNavigation.isAhead(bar.frame, of: source.frame, direction: .up) else {
            return nil
        }
        return barId
    }

    private static func tieBreakLess(_ lhs: NavigableZoneIdentifier, _ rhs: NavigableZoneIdentifier) -> Bool {
        let lhsKey = lhs.tieBreakKey
        let rhsKey = rhs.tieBreakKey
        if lhsKey.0 != rhsKey.0 { return lhsKey.0 < rhsKey.0 }
        if lhsKey.1 != rhsKey.1 { return lhsKey.1 < rhsKey.1 }
        return lhsKey.2 < rhsKey.2
    }
}
