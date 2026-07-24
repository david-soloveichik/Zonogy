import CoreGraphics

/// Decides whether a released external drag qualifies for the app-side edge-pill drop rescue.
///
/// AppKit drag-session delivery misses only in a narrow band at a screen boundary: the cursor
/// pins ~1/64pt inside the edge, and the session's hit test quantizes that toward zero — off the
/// pill's on-screen region when the edge lies at a non-positive coordinate. Limiting the rescue
/// to this band means drops that AppKit can deliver normally are never second-guessed (for
/// example after the drag session was cancelled by its source, or when another destination
/// overlaps the pill's strip).
enum EdgePillDropRescuePolicy {
    /// How far inside the screen edge the dead band reaches. The pin sits within 1pt of the
    /// edge; a little slack covers quantization variants.
    static let deadBandInset: CGFloat = 1.5

    /// Where the snap-in nudge places a dead-band cursor: far enough inside the edge that drag
    /// hit-testing (which truncates toward zero) lands on an on-screen row, and strictly deeper
    /// than `deadBandInset` so the nudged position never re-triggers the nudge from our own
    /// event monitor. Must stay under the pill's visible thickness.
    static let snapInInset: CGFloat = 2

    /// The coordinate a dead-band cursor is nudged to along the axis perpendicular to the edge.
    static func snapInCoordinate(edge: CGFloat, interiorIsBelowEdge: Bool) -> CGFloat {
        interiorIsBelowEdge ? edge - snapInInset : edge + snapInInset
    }

    /// Whether the release coordinate (along the axis perpendicular to the pill's edge) sits in
    /// the boundary dead band: at/past the screen edge, or within `inset` inside it.
    /// `interiorIsBelowEdge` says the screen interior has smaller coordinates than the edge
    /// (true for bottom and right edges in top-left-origin coordinates; false for left edges).
    static func isInDeadBand(
        cursor: CGFloat,
        edge: CGFloat,
        interiorIsBelowEdge: Bool,
        inset: CGFloat = deadBandInset
    ) -> Bool {
        interiorIsBelowEdge ? cursor >= edge - inset : cursor <= edge + inset
    }
}
