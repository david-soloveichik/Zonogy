import CoreGraphics

/// Pure selection policy for keyboard zone navigation.
///
/// Navigation considers every zone: each tiling zone — filled or empty — plus each screen's
/// floating zone at its bottom-edge bar, occupied or not.
///
/// Moves on a screen are structural, read from the zone model: each tiling zone sits in a column
/// (its side) at a row (`StackRow`), with the bar as the screen's bottom-most stop below both
/// columns. Up and down walk a column's stack and the bar; left and right cross between the
/// columns, landing in the matching row (bottom to bottom; top and full-height to the top).
/// Keeping the floating zone at its bar rather than at its occupant window also keeps selection
/// independent of where that window sits.
///
/// A press with no stop left on the screen crosses to another screen. Geometry picks the screen:
/// each other screen lies in exactly one direction from the current one (`screenDirection`), and
/// the press takes the nearest one lying in the pressed direction (center distance along that
/// axis, then across it, then display id). The entry is structural again — from below, the bar;
/// from above, the top row; from the side, the near column at the matching row.
///
/// Every selection carries the trail of moves that produced it: pressing the exact opposite of
/// the move that arrived somewhere backs out to that move's source, step by step, all the way to
/// the gesture's start. Moves are lossy (a full-height column reached from a stack's bottom
/// re-enters the stack at its top), so reversal is remembered, not recomputed.
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

    /// A navigable screen by its full frame on the shared global plane — the input to the
    /// cross-screen direction classification.
    struct Screen: Equatable {
        let id: CGDirectDisplayID
        let frame: CGRect
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
        candidates: [Candidate],
        screens: [Screen]
    ) -> Selection? {
        if let focusedZoneId,
           let focused = candidates.first(where: { $0.id == focusedZoneId }) {
            return move(from: focused, direction: direction, candidates: candidates, screens: screens)
        }

        if let targetedZoneId,
           let target = candidates.first(where: { $0.id == targetedZoneId }) {
            if target.isOccupied {
                return Selection(id: target.id, trail: [])
            }
            return move(from: target, direction: direction, candidates: candidates, screens: screens)
        }

        guard let fallbackZoneId,
              let fallback = candidates.first(where: { $0.id == fallbackZoneId }) else {
            return nil
        }
        return move(from: fallback, direction: direction, candidates: candidates, screens: screens)
    }

    /// Selection produced by a subsequent arrow press. Pressing the opposite of the move that
    /// arrived at the current selection pops back to that move's source; any other press moves
    /// from the current selection. Stays on the current selection when no zone lies in the
    /// pressed direction.
    static func nextSelection(
        direction: ZoneNavigationDirection,
        currentSelection: Selection,
        candidates: [Candidate],
        screens: [Screen]
    ) -> Selection {
        guard let current = candidates.first(where: { $0.id == currentSelection.id }) else {
            return currentSelection
        }

        if let last = currentSelection.trail.last, direction == last.direction.opposite {
            return Selection(id: last.source, trail: Array(currentSelection.trail.dropLast()))
        }

        guard let next = destination(
            from: current,
            direction: direction,
            candidates: candidates,
            screens: screens
        ) else {
            return currentSelection
        }
        return Selection(
            id: next,
            trail: currentSelection.trail + [Move(source: current.id, direction: direction)]
        )
    }

    /// The one direction `other` lies in from `source` (full screen frames on the global plane).
    /// Arranged screens never intersect, so at most one axis has interval overlap: overlapping
    /// x-ranges make a vertical neighbor, overlapping y-ranges a horizontal one — the axis their
    /// shared edge spans, which is also how the mouse pointer crosses. A pair overlapping on
    /// neither axis (corner or apart arrangements) takes the larger axis of the center offset,
    /// ties breaking horizontal.
    static func screenDirection(from source: CGRect, to other: CGRect) -> ZoneNavigationDirection {
        let dx = other.midX - source.midX
        let dy = other.midY - source.midY
        let xOverlap = min(source.maxX, other.maxX) - max(source.minX, other.minX) > overlapTolerance
        let yOverlap = min(source.maxY, other.maxY) - max(source.minY, other.minY) > overlapTolerance
        if xOverlap && !yOverlap { return dy < 0 ? .up : .down }
        if yOverlap && !xOverlap { return dx < 0 ? .left : .right }
        if abs(dy) > abs(dx) { return dy < 0 ? .up : .down }
        return dx < 0 ? .left : .right
    }

    /// Minimum interval overlap for two screens to count as edge-sharing neighbors.
    private static let overlapTolerance: CGFloat = 1.0

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
    /// removed zone's screen's tiling zone that takes over most of the removed frame (ties prefer
    /// the lower zone index). Nil when that screen retains no tiling zone — a state a valid
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
            if area > bestArea || (area == bestArea && best.map({ candidate.id.indexKey < $0.id.indexKey }) == true) {
                best = candidate
                bestArea = area
            }
        }
        return best?.id
    }

    // MARK: - Move resolution

    /// Structural view of one screen's candidates: its tiling zones by column and row, and its
    /// bar.
    private struct ScreenModel {
        let tiling: [Candidate]
        let barId: NavigableZoneIdentifier?
        /// Every multi-zone screen occupies both sides (a ZoneController invariant); only a lone
        /// full-screen zone leaves a side empty, and it spans the full width — no column to
        /// cross to horizontally.
        let hasBothColumns: Bool

        init(of screenId: CGDirectDisplayID, in candidates: [Candidate]) {
            let screen = candidates.filter { $0.id.screenId == screenId }
            tiling = screen.filter { $0.place != nil }
            barId = screen.first { $0.id.isFloating }?.id
            hasBothColumns = ZoneSide.allCases.allSatisfy { side in
                screen.contains { $0.place?.side == side }
            }
        }

        func zone(_ side: ZoneSide, _ row: StackRow) -> NavigableZoneIdentifier? {
            tiling.first { $0.place == ColumnPlace(side: side, row: row) }?.id
        }

        /// The lowest-index zone among the rows `included` selects — the bottom row for climbs
        /// off a bar, the top row for downward entries.
        func lowestIndex(where included: (StackRow) -> Bool) -> NavigableZoneIdentifier? {
            tiling
                .filter { $0.place.map { included($0.row) } == true }
                .min { $0.id.indexKey < $1.id.indexKey }?
                .id
        }

        /// Row-matched landing in `side`: bottom stays bottom, top and full-height enter at the
        /// top, a bar (nil row) enters at the column's bottom-most zone, and a full-height
        /// column takes every row.
        func landing(in side: ZoneSide, fromRow row: StackRow?) -> NavigableZoneIdentifier? {
            if let full = zone(side, .full) {
                return full
            }
            guard let row else {
                return zone(side, .bottom)
            }
            return zone(side, row == .bottom ? .bottom : .top)
        }
    }

    /// Move off `source`, recording it as the selection's trail — or `source` itself selected in
    /// place when no zone lies in the pressed direction.
    private static func move(
        from source: Candidate,
        direction: ZoneNavigationDirection,
        candidates: [Candidate],
        screens: [Screen]
    ) -> Selection {
        guard let next = destination(
            from: source,
            direction: direction,
            candidates: candidates,
            screens: screens
        ) else {
            return Selection(id: source.id, trail: [])
        }
        return Selection(id: next, trail: [Move(source: source.id, direction: direction)])
    }

    /// The zone a press moves to from `source`, or nil when nothing lies that way: the screen's
    /// structural stop in the pressed direction when it still has one, otherwise the crossing
    /// onto the screen lying in that direction.
    private static func destination(
        from source: Candidate,
        direction: ZoneNavigationDirection,
        candidates: [Candidate],
        screens: [Screen]
    ) -> NavigableZoneIdentifier? {
        withinScreenDestination(from: source, direction: direction, candidates: candidates)
            ?? exitDestination(from: source, direction: direction, candidates: candidates, screens: screens)
    }

    /// The structural within-screen move (see the header), or nil when the press leaves the
    /// screen: up from the top of the layout, down from the bar, or a horizontal press with no
    /// column that way.
    private static func withinScreenDestination(
        from source: Candidate,
        direction: ZoneNavigationDirection,
        candidates: [Candidate]
    ) -> NavigableZoneIdentifier? {
        let model = ScreenModel(of: source.id.screenId, in: candidates)

        guard let place = source.place else {
            // The bar: up climbs into the bottom row (the lower zone index wins between two
            // bottom zones), left/right go to that column's bottom-most zone, down exits.
            switch direction {
            case .up:
                return model.lowestIndex { $0 != .top }
            case .down:
                return nil
            case .left:
                return model.hasBothColumns ? model.landing(in: .left, fromRow: nil) : nil
            case .right:
                return model.hasBothColumns ? model.landing(in: .right, fromRow: nil) : nil
            }
        }

        switch direction {
        case .up:
            return place.row == .bottom ? model.zone(place.side, .top) : nil
        case .down:
            if place.row == .top {
                return model.zone(place.side, .bottom)
            }
            return model.barId
        case .left, .right:
            let target: ZoneSide = direction == .left ? .left : .right
            guard model.hasBothColumns, place.side != target else { return nil }
            return model.landing(in: target, fromRow: place.row)
        }
    }

    /// Crossing off the screen: the nearest screen lying in the pressed direction, entered
    /// through its near side. Nil when no screen lies that way.
    private static func exitDestination(
        from source: Candidate,
        direction: ZoneNavigationDirection,
        candidates: [Candidate],
        screens: [Screen]
    ) -> NavigableZoneIdentifier? {
        guard let sourceScreen = screens.first(where: { $0.id == source.id.screenId }) else {
            return nil
        }
        let vertical = direction == .up || direction == .down

        func axisDistance(_ screen: Screen) -> CGFloat {
            vertical
                ? abs(screen.frame.midY - sourceScreen.frame.midY)
                : abs(screen.frame.midX - sourceScreen.frame.midX)
        }
        func perpendicularDistance(_ screen: Screen) -> CGFloat {
            vertical
                ? abs(screen.frame.midX - sourceScreen.frame.midX)
                : abs(screen.frame.midY - sourceScreen.frame.midY)
        }

        let target = screens
            .filter {
                $0.id != sourceScreen.id
                    && screenDirection(from: sourceScreen.frame, to: $0.frame) == direction
            }
            .min { lhs, rhs in
                if axisDistance(lhs) != axisDistance(rhs) {
                    return axisDistance(lhs) < axisDistance(rhs)
                }
                if perpendicularDistance(lhs) != perpendicularDistance(rhs) {
                    return perpendicularDistance(lhs) < perpendicularDistance(rhs)
                }
                return lhs.id < rhs.id
            }
        guard let target else { return nil }
        return entry(into: target.id, direction: direction, from: source, candidates: candidates)
    }

    /// Where a crossing lands on the entered screen: from below, its bar (a barless screen — a
    /// defensive state — enters its bottom row); from above, its top row (the lower zone index
    /// between columns); from the side, its near column at the row matching the source.
    private static func entry(
        into screenId: CGDirectDisplayID,
        direction: ZoneNavigationDirection,
        from source: Candidate,
        candidates: [Candidate]
    ) -> NavigableZoneIdentifier? {
        let model = ScreenModel(of: screenId, in: candidates)
        switch direction {
        case .up:
            return model.barId ?? model.lowestIndex { $0 != .top }
        case .down:
            return model.lowestIndex { $0 != .bottom }
        case .left, .right:
            guard model.hasBothColumns else {
                return model.lowestIndex { _ in true }
            }
            let nearSide: ZoneSide = direction == .left ? .right : .left
            return model.landing(in: nearSide, fromRow: source.place?.row)
        }
    }
}
