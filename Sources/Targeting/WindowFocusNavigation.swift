import CoreGraphics

/// Pure selection policy for Control-Command + arrow-key window-focus navigation.
///
/// Navigation considers only the windows occupying filled zones — every tiling-zone occupant plus
/// each screen's floating-zone occupant — addressed by each window's *actual* on-screen rectangle.
/// All four directions navigate uniformly among those rectangles. Because the floating window
/// overlaps the tiled ones, it is usually the first stop in any direction that crosses it; to keep
/// that crossing coherent, a floating selection remembers where it was entered from. Pressing on
/// then moves relative to the entry, so the same direction continues past the floating window
/// (lower-left → floating → upper-left), and the reverse of the entry direction goes back to the
/// entry window.
///
/// Deterministic and OS-free so it is covered by `--self-test`. The live gesture, the blue-dot
/// overlay, and the actual focusing are wired up in `AppController+WindowFocusNavigation` driven by
/// `WindowFocusNavigationInterceptor`.
enum WindowFocusNavigation {
    /// A focusable window and its actual rectangle on the shared global (accessibility-coordinate)
    /// plane.
    struct Candidate: Equatable {
        let windowId: Int
        let frame: CGRect
        let screenId: CGDirectDisplayID
        let isFloating: Bool
        /// Tiling zone index; nil for the floating occupant. Used only to break exact geometric
        /// ties the same way target navigation does (tiled first, then lower index).
        let zoneIndex: Int?
    }

    /// Where navigation starts when no candidate supplies the source: the focused window's
    /// rectangle, or the targeted zone's rectangle.
    struct Anchor {
        let frame: CGRect
        let screenId: CGDirectDisplayID
    }

    /// A marked window. When the marked window is a floating occupant reached by a directional
    /// move, `entry` records where that move started so later presses can pass beyond the floating
    /// window or reverse out of it.
    struct Selection: Equatable {
        let windowId: Int
        let entry: Entry?
    }

    /// How a floating selection was entered: the source of the move that landed on it (a window's
    /// actual rectangle, or the targeted zone's rectangle when nothing was selected yet).
    struct Entry: Equatable {
        let frame: CGRect
        let screenId: CGDirectDisplayID
        /// The window the move started from, when it was a window.
        let windowId: Int?
        let direction: ZoneNavigationDirection
    }

    /// Selection produced by the first (engaging) arrow press.
    ///
    /// - When a managed window is focused, the press moves to the nearest filled window in the
    ///   pressed direction (you move *off* the focused window).
    /// - Otherwise navigation starts from the targeted zone: when that zone holds a window the first
    ///   press marks that window (regardless of direction); when it is empty the press moves to the
    ///   nearest filled window in the pressed direction from the zone's rectangle.
    ///
    /// Returns nil when nothing is selectable.
    static func initialSelection(
        direction: ZoneNavigationDirection,
        focusedWindowId: Int?,
        anchor: Anchor,
        targetOccupantWindowId: Int?,
        candidates: [Candidate]
    ) -> Selection? {
        if let focusedWindowId,
           let focused = candidates.first(where: { $0.windowId == focusedWindowId }) {
            return resolveMove(
                direction: direction,
                sourceFrame: focused.frame,
                sourceScreenId: focused.screenId,
                sourceWindowId: focusedWindowId,
                excluding: focusedWindowId,
                candidates: candidates
            )
        }

        if let targetOccupantWindowId, candidates.contains(where: { $0.windowId == targetOccupantWindowId }) {
            return Selection(windowId: targetOccupantWindowId, entry: nil)
        }

        return resolveMove(
            direction: direction,
            sourceFrame: anchor.frame,
            sourceScreenId: anchor.screenId,
            sourceWindowId: nil,
            excluding: nil,
            candidates: candidates
        )
    }

    /// Selection produced by a subsequent arrow press: move from the current selection (or, when
    /// nothing is selected yet, from the fixed anchor). Stays on the current selection when no
    /// window lies in the pressed direction.
    static func nextSelection(
        direction: ZoneNavigationDirection,
        currentSelection: Selection?,
        anchor: Anchor,
        candidates: [Candidate]
    ) -> Selection? {
        guard let currentSelection,
              let current = candidates.first(where: { $0.windowId == currentSelection.windowId }) else {
            let next = resolveMove(
                direction: direction,
                sourceFrame: anchor.frame,
                sourceScreenId: anchor.screenId,
                sourceWindowId: nil,
                excluding: currentSelection?.windowId,
                candidates: candidates
            )
            return next ?? currentSelection
        }

        if current.isFloating, let entry = currentSelection.entry {
            // Reversing the entry direction backs out to the window the gesture came from — never
            // past it. When the entry was an empty targeted zone's rectangle rather than a window,
            // there is nothing to back out to, so the selection stays on the floating window.
            if direction == entry.direction.opposite {
                guard let entryWindowId = entry.windowId else { return currentSelection }
                return Selection(windowId: entryWindowId, entry: nil)
            }
            // Any other press moves relative to where the floating window was entered, skipping
            // the floating window itself — so the entry direction continues past it.
            let next = resolveMove(
                direction: direction,
                sourceFrame: entry.frame,
                sourceScreenId: entry.screenId,
                sourceWindowId: entry.windowId,
                excluding: currentSelection.windowId,
                candidates: candidates
            )
            return next ?? currentSelection
        }

        let next = resolveMove(
            direction: direction,
            sourceFrame: current.frame,
            sourceScreenId: current.screenId,
            sourceWindowId: current.windowId,
            excluding: current.windowId,
            candidates: candidates
        )
        return next ?? currentSelection
    }

    /// Runs the geometric move and, when it lands on a floating window, records the move's source
    /// as that selection's entry so later presses can pass beyond it or reverse out of it.
    private static func resolveMove(
        direction: ZoneNavigationDirection,
        sourceFrame: CGRect,
        sourceScreenId: CGDirectDisplayID,
        sourceWindowId: Int?,
        excluding excludedWindowId: Int?,
        candidates: [Candidate]
    ) -> Selection? {
        guard let next = nearest(
            from: sourceFrame,
            screenId: sourceScreenId,
            direction: direction,
            excluding: excludedWindowId,
            candidates: candidates
        ) else {
            return nil
        }

        guard next.isFloating else {
            return Selection(windowId: next.windowId, entry: nil)
        }
        return Selection(
            windowId: next.windowId,
            entry: Entry(
                frame: sourceFrame,
                screenId: sourceScreenId,
                windowId: sourceWindowId,
                direction: direction
            )
        )
    }

    private static func nearest(
        from frame: CGRect,
        screenId: CGDirectDisplayID,
        direction: ZoneNavigationDirection,
        excluding excludedWindowId: Int?,
        candidates: [Candidate]
    ) -> Candidate? {
        DirectionalRectNavigation.nearest(
            from: frame,
            sourceScreenId: screenId,
            direction: direction,
            among: candidates.map {
                DirectionalRectNavigation.Item(id: $0, frame: $0.frame, screenId: $0.screenId)
            },
            isExcluded: { $0.windowId == excludedWindowId },
            tieBreak: { tieBreakLess($0.id, $1.id) }
        )
    }

    /// Exact geometric ties resolve like target navigation: tiled before floating, then lower zone
    /// index, then lower window id.
    private static func tieBreakLess(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
        if lhs.isFloating != rhs.isFloating { return !lhs.isFloating }
        let lhsZone = lhs.zoneIndex ?? Int.max
        let rhsZone = rhs.zoneIndex ?? Int.max
        if lhsZone != rhsZone { return lhsZone < rhsZone }
        return lhs.windowId < rhs.windowId
    }
}
