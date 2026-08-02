import CoreGraphics
import Foundation

/// Pure, deterministic policy deciding where a placeholder's click-catching background should be
/// punched out so clicks pass through to unmanaged windows stuck behind it.
///
/// An unmanaged window (one Zonogy does not tile: a dialog, a rule-violating window, or a window
/// of an ignored or accessory app) can end up behind a placeholder because zone syncs re-front
/// placeholders. Without a punch-out the placeholder's hit-test surface would swallow every click
/// aimed at that window. The Desktop never qualifies: callers build rows from a window list that
/// excludes desktop elements, and the layer filter drops all non-normal-level windows anyway.
///
/// This logic is intentionally isolated so it can be guardrail-tested without relying on the
/// window server, Accessibility, or timing.
enum PlaceholderPassThroughPolicy {
    /// Returns the regions (in the rows' own coordinate space) where the placeholder should let
    /// clicks pass through: the overlap with every unmanaged window that sits *behind* it,
    /// minus any click-catching window in between.
    ///
    /// A row qualifies as an unmanaged candidate when it is a normal-level window (layer 0),
    /// is not invisible (alpha > 0, since the window server already passes clicks through
    /// fully transparent windows), does not belong to Zonogy, and is not a managed window.
    /// A candidate contributes its overlap with the placeholder when it is behind the
    /// placeholder in z-order and the overlap survives the shadow-tolerance inset test
    /// (the same rule `WindowOcclusionPolicy` uses). The contributed region is the *un-inset*
    /// intersection so clicks near the window's visible edges pass through too.
    ///
    /// Windows behind the placeholder that catch clicks themselves — managed windows (e.g. a
    /// floating occupant overlapping the empty zone) and Zonogy's own — block the region: a
    /// hole there would route clicks to the blocker instead of the unmanaged window, so those
    /// parts stay click-catching placeholder surface. Each candidate likewise blocks deeper
    /// candidates, keeping the regions disjoint.
    static func holeRects(
        placeholderCgWindowId: Int,
        rowsFrontToBack: [WindowServerWindowRow],
        zonogyPid: pid_t,
        managedCgWindowIds: Set<Int>,
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

        var blockedFrames: [CGRect] = []
        var holes: [CGRect] = []
        for (index, row) in rowsFrontToBack.enumerated() {
            guard index > placeholderIndex,
                  row.layer == 0,
                  row.alpha > 0 else {
                continue
            }
            // Every click-catching row occludes what lies deeper, whether or not it
            // contributes a hole itself (e.g. a sliver that fails the overlap test).
            defer { blockedFrames.append(row.frame) }

            guard row.ownerPid != zonogyPid,
                  !managedCgWindowIds.contains(row.windowNumber) else {
                continue
            }

            let insetCandidateFrame = ZoneResizeHandleGeometry.insetAvoidanceFrame(row.frame, by: avoidanceInset)
            let insetIntersection = insetPlaceholderFrame.intersection(insetCandidateFrame)
            guard !insetIntersection.isNull,
                  insetIntersection.width > minIntersectionDimension,
                  insetIntersection.height > minIntersectionDimension else {
                continue
            }

            let overlap = placeholderFrame.intersection(row.frame)
            holes.append(contentsOf: subtracting(blockedFrames, from: overlap))
        }

        return holes
    }

    /// Returns `rect` minus every rect in `blockers`, as disjoint rects. Each blocker splits a
    /// piece into up to four remainders, appended in top, bottom, left, right order.
    static func subtracting(_ blockers: [CGRect], from rect: CGRect) -> [CGRect] {
        var pieces = [rect]
        for blocker in blockers {
            var remaining: [CGRect] = []
            for piece in pieces {
                let overlap = piece.intersection(blocker)
                guard !overlap.isNull, overlap.width > 0, overlap.height > 0 else {
                    remaining.append(piece)
                    continue
                }
                if overlap.minY > piece.minY {
                    remaining.append(CGRect(x: piece.minX, y: piece.minY, width: piece.width, height: overlap.minY - piece.minY))
                }
                if overlap.maxY < piece.maxY {
                    remaining.append(CGRect(x: piece.minX, y: overlap.maxY, width: piece.width, height: piece.maxY - overlap.maxY))
                }
                if overlap.minX > piece.minX {
                    remaining.append(CGRect(x: piece.minX, y: overlap.minY, width: overlap.minX - piece.minX, height: overlap.height))
                }
                if overlap.maxX < piece.maxX {
                    remaining.append(CGRect(x: overlap.maxX, y: overlap.minY, width: piece.maxX - overlap.maxX, height: overlap.height))
                }
            }
            pieces = remaining
        }
        return pieces
    }
}
