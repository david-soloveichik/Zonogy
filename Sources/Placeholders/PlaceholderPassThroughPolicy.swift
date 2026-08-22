import CoreGraphics
import Foundation

/// Pure, deterministic policy deciding where a placeholder's click-catching background should be
/// punched out so clicks pass through to windows stuck behind it and to desktop icons under it.
///
/// Zone syncs re-raise placeholders, which can leave another application's window behind one.
/// Without a punch-out the placeholder's hit-test surface would swallow every click aimed at
/// that window. Every such window punches its overlap, so the policy only decides where the
/// placeholder yields; the window server then routes each click to whichever window is topmost
/// there. Desktop icons are handled separately: the window list excludes desktop elements, so
/// callers pass icon frames (see `DesktopIconAccessibility`) and each icon punches its overlap
/// plus an approximate filename-label band, keeping icons selectable, openable, and draggable
/// beneath placeholders.
///
/// This logic is intentionally isolated so it can be guardrail-tested without relying on the
/// window server, Accessibility, or timing.
enum PlaceholderPassThroughPolicy {
    /// A hole punched for one window behind the placeholder.
    struct WindowHole: Equatable {
        let windowNumber: Int
        let rect: CGRect
    }

    /// One placeholder's holes: those punched for windows behind it (front to back), and those
    /// punched for desktop icons (each icon's overlap, then its label band's).
    struct Holes: Equatable {
        var windows: [WindowHole] = []
        var icons: [CGRect] = []

        var isEmpty: Bool {
            windows.isEmpty && icons.isEmpty
        }

        /// Every hole rect, window holes first. Rects may overlap; callers union them.
        var rects: [CGRect] {
            windows.map(\.rect) + icons
        }
    }

    /// Desktop-icon label band metrics, measured on macOS 15 at default view settings: the
    /// filename label is centered under the icon, begins ~6px below it, wraps to at most two
    /// lines (ending ~38px below), and can extend ~27px past each icon edge. The band is
    /// slightly generous so label clicks never land on the placeholder; over-punching merely
    /// forfeits a little click-to-target area right around the label.
    static let iconLabelBandOutset: CGFloat = 32
    static let iconLabelBandHeight: CGFloat = 44

    /// Returns the holes (in the rows' own coordinate space) for the placeholder with the given
    /// window number: its overlap with every other application's window *behind* it, and with
    /// every desktop icon (plus each icon's label band). A placeholder missing from the rows
    /// (mid-transition) gets no holes.
    static func holes(
        placeholderCgWindowId: Int,
        rowsFrontToBack: [WindowServerWindowRow],
        zonogyPid: pid_t,
        desktopIconFrames: [CGRect] = [],
        avoidanceInset: CGFloat = 6,
        minIntersectionDimension: CGFloat = 1
    ) -> Holes {
        guard let placeholderIndex = rowsFrontToBack.firstIndex(where: { $0.windowNumber == placeholderCgWindowId }) else {
            return Holes()
        }
        return holes(
            placeholderFrame: rowsFrontToBack[placeholderIndex].frame,
            rowsBehind: Array(rowsFrontToBack[(placeholderIndex + 1)...]),
            zonogyPid: zonogyPid,
            desktopIconFrames: desktopIconFrames,
            avoidanceInset: avoidanceInset,
            minIntersectionDimension: minIntersectionDimension
        )
    }

    /// Returns the holes for a placeholder occupying `placeholderFrame` with `rowsBehind` behind
    /// it. Passing every window predicts the holes a placeholder will have once it is on top —
    /// for a zone that is only about to get its placeholder, or before the next sync re-raises
    /// an existing one (see the Launcher's auto-show rule).
    ///
    /// A row qualifies when it is a normal-level window (layer 0), is not invisible (alpha > 0,
    /// since the window server already passes clicks through fully transparent windows), does
    /// not belong to Zonogy, and its overlap survives the shadow-tolerance inset test (the same
    /// rule `WindowOcclusionPolicy` uses). The contributed region is the *un-inset*
    /// intersection so clicks near the window's visible edges pass through too.
    ///
    /// Desktop icons sit behind every normal window, so they punch unconditionally — no z-order
    /// or shadow-inset test (their frames are exact). If a qualifying window covers an icon, the
    /// window's own hole covers the same area and the window server routes clicks to whichever
    /// window is topmost there.
    static func holes(
        placeholderFrame: CGRect,
        rowsBehind: [WindowServerWindowRow],
        zonogyPid: pid_t,
        desktopIconFrames: [CGRect] = [],
        avoidanceInset: CGFloat = 6,
        minIntersectionDimension: CGFloat = 1
    ) -> Holes {
        let insetPlaceholderFrame = ZoneResizeHandleGeometry.insetAvoidanceFrame(placeholderFrame, by: avoidanceInset)

        var holes = Holes()
        for row in rowsBehind {
            guard row.layer == 0,
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

            holes.windows.append(WindowHole(windowNumber: row.windowNumber, rect: placeholderFrame.intersection(row.frame)))
        }

        for iconFrame in desktopIconFrames {
            // The label band punches even when the icon image itself misses the placeholder:
            // labels are wider than their icons, so a label can reach under the placeholder
            // edge while the icon does not.
            let labelBand = CGRect(
                x: iconFrame.minX - iconLabelBandOutset,
                y: iconFrame.maxY,
                width: iconFrame.width + 2 * iconLabelBandOutset,
                height: iconLabelBandHeight
            )
            for candidate in [iconFrame, labelBand] {
                let hole = placeholderFrame.intersection(candidate)
                guard !hole.isNull,
                      hole.width > minIntersectionDimension,
                      hole.height > minIntersectionDimension else {
                    continue
                }
                holes.icons.append(hole)
            }
        }

        return holes
    }
}
