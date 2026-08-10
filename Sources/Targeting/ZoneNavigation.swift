import CoreGraphics

/// Pure selection policy for keyboard zone navigation.
///
/// Navigation considers every zone: each tiling zone — filled or empty — by its zone frame, plus
/// each screen's floating zone at its bottom-edge bar, occupied or not. The bar is its screen's
/// bottom-most stop on the vertical axis: down reaches it from that screen's zones (and crossing
/// to a screen below stops at it first), and up reaches it when entering the screen from a screen
/// below — enforced as an explicit boundary-bar priority, since generic nearest-rectangle racing
/// can skip a bar. Horizontal geometric moves skip bars — a bar grazes the zone frames when the
/// visible area reaches the true screen bottom (hidden or side Dock), and the overlap would
/// otherwise let it steal left/right moves from real zone neighbors — though a selection can
/// still land on a bar without a vertical press: a reverse press pops back onto it, and a gesture
/// that starts on the floating zone selects it in place when it is occupied and targeted (any
/// direction) or when nothing lies in the pressed direction. Keeping the floating
/// zone at the bar rather than at its occupant window also keeps selection independent of where
/// that window sits (concentric with a tiling zone, neither would be reachable from the other —
/// no direction strictly leads between coincident centers).
///
/// Every selection carries the trail of moves that produced it: pressing the exact opposite of the
/// move that arrived somewhere backs out to that move's source, step by step, all the way to the
/// gesture's start. Nearest-ahead geometry is lossy (left then right can land on a third zone), so
/// reversal is remembered, not recomputed.
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

    /// Stable ordering used only to break exact geometric ties: prefer a tiling zone over the
    /// floating zone, then a lower index, then a lower display id.
    fileprivate var tieBreakKey: (Int, Int, CGDirectDisplayID) {
        switch self {
        case let .tiling(screenId, index): return (0, index, screenId)
        case let .floating(screenId): return (1, Int.max, screenId)
        }
    }
}

enum ZoneNavigation {
    /// A navigable zone and its rectangle on the shared global (accessibility-coordinate) plane.
    struct Candidate: Equatable {
        let id: NavigableZoneIdentifier
        let frame: CGRect
        /// Whether a window occupies this zone (geometry-time snapshot; commits re-read live
        /// occupancy).
        let isOccupied: Bool
    }

    /// One recorded move: the zone it started from and the pressed direction.
    struct Move: Equatable {
        let source: NavigableZoneIdentifier
        let direction: ZoneNavigationDirection
    }

    /// A selected zone plus the trail of moves that led to it. Pressing the opposite of the
    /// trail's last move backs out to that move's source instead of running the geometry.
    struct Selection: Equatable {
        let id: NavigableZoneIdentifier
        let trail: [Move]
    }

    /// Selection produced by the first (engaging) arrow press.
    ///
    /// - When a managed window is focused, the press moves off its zone to the nearest zone in
    ///   the pressed direction. (While the Launcher is open the caller passes no focused zone, so
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
    /// geometrically from the current selection. Stays on the current selection when no zone lies
    /// in the pressed direction.
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

        guard let next = nearest(
            from: current.frame,
            screenId: current.id.screenId,
            direction: direction,
            excluding: current.id,
            candidates: candidates
        ) else {
            return currentSelection
        }
        return Selection(
            id: next,
            trail: currentSelection.trail + [Move(source: current.id, direction: direction)]
        )
    }

    /// Geometric move off `source`, recording it as the selection's trail — or `source` itself
    /// selected in place when no zone lies in the pressed direction.
    private static func move(
        from source: Candidate,
        direction: ZoneNavigationDirection,
        candidates: [Candidate]
    ) -> Selection {
        guard let next = nearest(
            from: source.frame,
            screenId: source.id.screenId,
            direction: direction,
            excluding: source.id,
            candidates: candidates
        ) else {
            return Selection(id: source.id, trail: [])
        }
        return Selection(id: next, trail: [Move(source: source.id, direction: direction)])
    }

    private static func nearest(
        from frame: CGRect,
        screenId: CGDirectDisplayID,
        direction: ZoneNavigationDirection,
        excluding excludedId: NavigableZoneIdentifier?,
        candidates: [Candidate]
    ) -> NavigableZoneIdentifier? {
        // Bars join only vertical geometric races (see the header).
        let vertical = direction == .up || direction == .down
        let eligible = vertical ? candidates : candidates.filter { !$0.id.isFloating }
        let winner = DirectionalRectNavigation.nearest(
            from: frame,
            sourceScreenId: screenId,
            direction: direction,
            among: eligible.map {
                DirectionalRectNavigation.Item(id: $0.id, frame: $0.frame, screenId: $0.id.screenId)
            },
            isExcluded: { $0 == excludedId },
            tieBreak: { tieBreakLess($0.id, $1.id) }
        )
        guard let winner, vertical else { return winner }
        return boundaryBar(
            from: frame,
            sourceScreenId: screenId,
            pastBy: winner,
            direction: direction,
            excluding: excludedId,
            candidates: candidates
        ) ?? winner
    }

    /// A screen's bar sits on that screen's bottom boundary: moving down out of a screen crosses
    /// its own bar first, and moving up into a screen arrives at that screen's bar first. The
    /// generic selector can skip that boundary bar — a grazing bar ties with a flush neighbor
    /// screen's zone and loses the tiling-first tie-break, and a source too narrow to overlap the
    /// centered bar loses it to any row-aligned zone — so a cross-screen vertical winner is
    /// redirected to the boundary bar it passed.
    private static func boundaryBar(
        from sourceFrame: CGRect,
        sourceScreenId: CGDirectDisplayID,
        pastBy winner: NavigableZoneIdentifier,
        direction: ZoneNavigationDirection,
        excluding excludedId: NavigableZoneIdentifier?,
        candidates: [Candidate]
    ) -> NavigableZoneIdentifier? {
        guard !winner.isFloating, winner.screenId != sourceScreenId else { return nil }
        let barId = NavigableZoneIdentifier.floating(
            screenId: direction == .down ? sourceScreenId : winner.screenId
        )
        guard barId != excludedId,
              let bar = candidates.first(where: { $0.id == barId }),
              DirectionalRectNavigation.isAhead(bar.frame, of: sourceFrame, direction: direction) else {
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
