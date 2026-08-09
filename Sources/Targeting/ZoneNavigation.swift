import CoreGraphics

/// Pure selection policy for keyboard zone navigation.
///
/// Navigation considers every zone: each tiling zone — filled or empty — by its zone frame, plus
/// each screen's floating zone, represented by its occupant window's actual rectangle when filled
/// or by its bottom-edge bar when empty. All four directions navigate uniformly among those
/// rectangles. Because a filled floating window overlaps the tiled zones, it is usually the first
/// stop in any direction that crosses it; to keep that crossing coherent, such a selection
/// remembers the zone it was entered from. Pressing on then moves relative to the entry, so the
/// same direction continues past the floating window and the reverse of the entry direction backs
/// out to the entry zone. The empty floating bar is spatially disjoint from the tiled zones, so it
/// navigates from its own rectangle like any other zone.
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
        /// The window occupying this zone; nil for an empty zone.
        let occupantWindowId: Int?
    }

    /// Fallback starting rectangle for when neither the focused window's zone nor the targeted
    /// zone resolves to a candidate.
    struct Anchor {
        let frame: CGRect
        let screenId: CGDirectDisplayID
    }

    /// A selected zone. When the selected zone is a filled floating zone reached by a directional
    /// move, `entry` records where that move started so later presses can pass beyond the floating
    /// window or reverse out of it.
    struct Selection: Equatable {
        let id: NavigableZoneIdentifier
        let entry: Entry?
    }

    /// How a filled floating selection was entered: the source of the move that landed on it.
    struct Entry: Equatable {
        let frame: CGRect
        let screenId: CGDirectDisplayID
        /// The zone the move started from, when it was a zone (nil for a bare anchor).
        let sourceId: NavigableZoneIdentifier?
        let direction: ZoneNavigationDirection
    }

    /// Selection produced by the first (engaging) arrow press.
    ///
    /// - When a managed window is focused, the press moves off its zone to the nearest zone in the
    ///   pressed direction.
    /// - Otherwise navigation starts from the targeted zone: a filled target is selected in place
    ///   (regardless of direction, so tap-and-release focuses its window); an empty target moves
    ///   immediately.
    /// - `fallbackAnchor` covers the remaining no-focus, no-resolvable-target case.
    ///
    /// Returns nil when nothing is selectable.
    static func initialSelection(
        direction: ZoneNavigationDirection,
        focusedZoneId: NavigableZoneIdentifier?,
        targetedZoneId: NavigableZoneIdentifier?,
        fallbackAnchor: Anchor?,
        candidates: [Candidate]
    ) -> Selection? {
        if let focusedZoneId,
           let focused = candidates.first(where: { $0.id == focusedZoneId }) {
            return resolveMove(
                direction: direction,
                sourceFrame: focused.frame,
                sourceScreenId: focused.id.screenId,
                sourceId: focused.id,
                excluding: focused.id,
                candidates: candidates
            )
        }

        if let targetedZoneId,
           let target = candidates.first(where: { $0.id == targetedZoneId }) {
            if target.occupantWindowId != nil {
                return Selection(id: target.id, entry: nil)
            }
            return resolveMove(
                direction: direction,
                sourceFrame: target.frame,
                sourceScreenId: target.id.screenId,
                sourceId: target.id,
                excluding: target.id,
                candidates: candidates
            )
        }

        guard let fallbackAnchor else { return nil }
        return resolveMove(
            direction: direction,
            sourceFrame: fallbackAnchor.frame,
            sourceScreenId: fallbackAnchor.screenId,
            sourceId: nil,
            excluding: nil,
            candidates: candidates
        )
    }

    /// Selection produced by a subsequent arrow press: move from the current selection (or, when
    /// nothing is selected yet, from the fixed anchor). Stays on the current selection when no zone
    /// lies in the pressed direction.
    static func nextSelection(
        direction: ZoneNavigationDirection,
        currentSelection: Selection?,
        anchor: Anchor,
        candidates: [Candidate]
    ) -> Selection? {
        guard let currentSelection,
              let current = candidates.first(where: { $0.id == currentSelection.id }) else {
            let next = resolveMove(
                direction: direction,
                sourceFrame: anchor.frame,
                sourceScreenId: anchor.screenId,
                sourceId: nil,
                excluding: currentSelection?.id,
                candidates: candidates
            )
            return next ?? currentSelection
        }

        if let entry = currentSelection.entry {
            // Reversing the entry direction backs out to the zone the gesture came from — never
            // past it. When the entry was a bare anchor rather than a zone, there is nothing to
            // back out to, so the selection stays on the floating zone.
            if direction == entry.direction.opposite {
                guard let sourceId = entry.sourceId else { return currentSelection }
                return Selection(id: sourceId, entry: nil)
            }
            // Any other press moves relative to where the floating zone was entered, skipping the
            // floating zone itself — so the entry direction continues past it.
            let next = resolveMove(
                direction: direction,
                sourceFrame: entry.frame,
                sourceScreenId: entry.screenId,
                sourceId: entry.sourceId,
                excluding: currentSelection.id,
                candidates: candidates
            )
            return next ?? currentSelection
        }

        let next = resolveMove(
            direction: direction,
            sourceFrame: current.frame,
            sourceScreenId: current.id.screenId,
            sourceId: current.id,
            excluding: current.id,
            candidates: candidates
        )
        return next ?? currentSelection
    }

    /// Runs the geometric move and, when it lands on a filled floating zone, records the move's
    /// source as that selection's entry so later presses can pass beyond it or reverse out of it.
    /// (The empty floating bar needs no entry: it does not overlap the tiled zones.)
    private static func resolveMove(
        direction: ZoneNavigationDirection,
        sourceFrame: CGRect,
        sourceScreenId: CGDirectDisplayID,
        sourceId: NavigableZoneIdentifier?,
        excluding excludedId: NavigableZoneIdentifier?,
        candidates: [Candidate]
    ) -> Selection? {
        guard let next = nearest(
            from: sourceFrame,
            screenId: sourceScreenId,
            direction: direction,
            excluding: excludedId,
            candidates: candidates
        ) else {
            return nil
        }

        guard next.id.isFloating, next.occupantWindowId != nil else {
            return Selection(id: next.id, entry: nil)
        }
        return Selection(
            id: next.id,
            entry: Entry(
                frame: sourceFrame,
                screenId: sourceScreenId,
                sourceId: sourceId,
                direction: direction
            )
        )
    }

    private static func nearest(
        from frame: CGRect,
        screenId: CGDirectDisplayID,
        direction: ZoneNavigationDirection,
        excluding excludedId: NavigableZoneIdentifier?,
        candidates: [Candidate]
    ) -> Candidate? {
        DirectionalRectNavigation.nearest(
            from: frame,
            sourceScreenId: screenId,
            direction: direction,
            among: candidates.map {
                DirectionalRectNavigation.Item(id: $0, frame: $0.frame, screenId: $0.id.screenId)
            },
            isExcluded: { $0.id == excludedId },
            tieBreak: { tieBreakLess($0.id.id, $1.id.id) }
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
