import CoreGraphics

/// Pure selection policy for Control-Command + arrow-key window-focus navigation.
///
/// Navigation considers only the windows occupying filled zones — every tiling-zone occupant plus
/// each screen's floating-zone occupant — addressed by each window's *actual* on-screen rectangle
/// (not the zone frame). All four directions navigate uniformly among those rectangles; there is no
/// tiling/floating layer restriction (the floating window is just another rectangle).
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
    }

    /// Selection produced by the first (engaging) arrow press.
    ///
    /// - When a managed window is focused, the press moves to the nearest filled window in the
    ///   pressed direction (you move *off* the focused window).
    /// - Otherwise navigation starts from the targeted zone: when that zone holds a window the first
    ///   press marks that window (regardless of direction); when it is empty the press moves to the
    ///   nearest filled window in the pressed direction from the zone's rectangle.
    ///
    /// `anchorFrame`/`anchorScreenId` is the focused window's rectangle (focused case) or the
    /// targeted zone's rectangle (otherwise). Returns nil when nothing is selectable.
    static func initialSelection(
        direction: ZoneNavigationDirection,
        focusedWindowId: Int?,
        anchorFrame: CGRect,
        anchorScreenId: CGDirectDisplayID,
        targetOccupantWindowId: Int?,
        candidates: [Candidate]
    ) -> Int? {
        if let focusedWindowId, candidates.contains(where: { $0.windowId == focusedWindowId }) {
            return nearest(
                from: anchorFrame,
                screenId: anchorScreenId,
                direction: direction,
                excluding: focusedWindowId,
                candidates: candidates
            )
        }

        if let targetOccupantWindowId, candidates.contains(where: { $0.windowId == targetOccupantWindowId }) {
            return targetOccupantWindowId
        }

        return nearest(
            from: anchorFrame,
            screenId: anchorScreenId,
            direction: direction,
            excluding: nil,
            candidates: candidates
        )
    }

    /// Selection produced by a subsequent arrow press: move from the current selection (or, when
    /// nothing is selected yet, from the fixed anchor). Stays on the current selection when no
    /// window lies in the pressed direction.
    static func nextSelection(
        direction: ZoneNavigationDirection,
        currentSelection: Int?,
        anchorFrame: CGRect,
        anchorScreenId: CGDirectDisplayID,
        candidates: [Candidate]
    ) -> Int? {
        let source = currentSelection.flatMap { id in candidates.first(where: { $0.windowId == id }) }
        let sourceFrame = source?.frame ?? anchorFrame
        let sourceScreenId = source?.screenId ?? anchorScreenId

        let next = nearest(
            from: sourceFrame,
            screenId: sourceScreenId,
            direction: direction,
            excluding: currentSelection,
            candidates: candidates
        )
        return next ?? currentSelection
    }

    private static func nearest(
        from frame: CGRect,
        screenId: CGDirectDisplayID,
        direction: ZoneNavigationDirection,
        excluding excludedWindowId: Int?,
        candidates: [Candidate]
    ) -> Int? {
        DirectionalRectNavigation.nearest(
            from: frame,
            sourceScreenId: screenId,
            direction: direction,
            among: candidates.map {
                DirectionalRectNavigation.Item(id: $0.windowId, frame: $0.frame, screenId: $0.screenId)
            },
            isExcluded: { excludedWindowId != nil && $0 == excludedWindowId },
            tieBreak: { $0.id < $1.id }
        )
    }
}
