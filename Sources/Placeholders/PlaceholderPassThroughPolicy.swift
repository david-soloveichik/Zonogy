import CoreGraphics
import Foundation

/// Pure, deterministic policy deciding where a placeholder's click-catching background should be
/// punched out so clicks pass through to windows stuck behind it.
///
/// Zone syncs re-raise placeholders, which can leave another application's window behind one.
/// Without a punch-out the placeholder's hit-test surface would swallow every click aimed at
/// that window. Every such window punches its overlap, so the policy only decides where the
/// placeholder yields; the window server then routes each click to whichever window is topmost
/// there. The Desktop never qualifies: callers build rows from a window list that excludes
/// desktop elements, and the layer filter drops all non-normal-level windows anyway.
///
/// This logic is intentionally isolated so it can be guardrail-tested without relying on the
/// window server, Accessibility, or timing.
enum PlaceholderPassThroughPolicy {
    /// Returns the regions (in the rows' own coordinate space) where the placeholder should let
    /// clicks pass through: its overlap with every other application's window *behind* it.
    ///
    /// A row qualifies when it is a normal-level window (layer 0), is not invisible (alpha > 0,
    /// since the window server already passes clicks through fully transparent windows), does
    /// not belong to Zonogy, sits behind the placeholder in z-order, and its overlap survives
    /// the shadow-tolerance inset test (the same rule `WindowOcclusionPolicy` uses). The
    /// contributed region is the *un-inset* intersection so clicks near the window's visible
    /// edges pass through too. Regions from overlapping windows may overlap; callers union them.
    static func holeRects(
        placeholderCgWindowId: Int,
        rowsFrontToBack: [WindowServerWindowRow],
        zonogyPid: pid_t,
        avoidanceInset: CGFloat = 6,
        minIntersectionDimension: CGFloat = 1
    ) -> [CGRect] {
        var placeholderIndex: Int?
        var placeholderFrame = CGRect.zero
        for (index, row) in rowsFrontToBack.enumerated() where row.windowNumber == placeholderCgWindowId {
            placeholderIndex = index
            placeholderFrame = row.frame
            break
        }
        // Placeholder not on screen (mid-transition): nothing to punch out.
        guard let placeholderIndex else {
            return []
        }

        let insetPlaceholderFrame = ZoneResizeHandleGeometry.insetAvoidanceFrame(placeholderFrame, by: avoidanceInset)

        var holes: [CGRect] = []
        for (index, row) in rowsFrontToBack.enumerated() {
            guard index > placeholderIndex,
                  row.layer == 0,
                  row.alpha > 0,
                  row.ownerPid != zonogyPid else {
                continue
            }

            let insetCandidateFrame = ZoneResizeHandleGeometry.insetAvoidanceFrame(row.frame, by: avoidanceInset)
            let insetIntersection = insetPlaceholderFrame.intersection(insetCandidateFrame)
            guard !insetIntersection.isNull,
                  insetIntersection.width > minIntersectionDimension,
                  insetIntersection.height > minIntersectionDimension else {
                continue
            }

            holes.append(placeholderFrame.intersection(row.frame))
        }

        return holes
    }
}
