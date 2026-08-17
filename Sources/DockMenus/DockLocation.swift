/// Pure geometry locating the Dock among the connected displays from its accessibility frames.

import CoreGraphics

/// Dock orientation as reported by the Dock's `AXList` (`AXOrientation`).
enum DockOrientation: Equatable {
    /// Dock along the bottom edge.
    case horizontal
    /// Dock along the left or right edge.
    case vertical
}

/// Where the Dock is: its display, the display edge it sits on, and its fully revealed frame.
///
/// An auto-hiding Dock lives on whichever display the pointer last pushed against, and its `AXList`
/// frame slides across that display's edge without changing size (fully off-screen when hidden,
/// where it can overlap a neighbouring display). Resolving from the sampled frame and the display
/// layout, rather than caching a settled frame, stays correct mid-slide (hovers can arrive then,
/// and the Dock posts no move/resize notifications for the slide) and follows the Dock between
/// displays. Frames are in accessibility coordinates.
struct DockLocation: Equatable {
    struct Display: Equatable {
        /// Full bounds; the Dock hugs one of its edges.
        let frame: CGRect
        /// Bounds available to DockMenus (excludes the menu bar).
        let visibleFrame: CGRect
    }

    enum Edge: Equatable {
        case bottom
        case left
        case right
    }

    let display: Display
    let edge: Edge
    /// The Dock frame when fully revealed: the `AXList` frame snapped flush against the display
    /// edge, thickened to cover the icons (which overhang the list toward the edge).
    let revealedFrame: CGRect

    /// Icon overhang beyond the `AXList` toward the display edge, used when the Dock reports none.
    static let defaultItemOverhang: CGFloat = 5

    /// Rounding tolerance for containment along the edge.
    private static let tolerance: CGFloat = 2

    /// - Parameters:
    ///   - listFrame: The Dock `AXList` frame, at any point of the auto-hide slide.
    ///   - itemFrame: A Dock item's frame from the same moment, used to measure the icon overhang.
    ///   - orientation: The `AXList` orientation.
    ///   - displays: All connected displays.
    /// - Returns: nil when the frame hugs no display edge (e.g. mid display reconfiguration).
    static func resolve(
        listFrame: CGRect,
        itemFrame: CGRect?,
        orientation: DockOrientation,
        displays: [Display]
    ) -> DockLocation? {
        let edges: [Edge] = orientation == .horizontal ? [.bottom] : [.left, .right]
        let candidates: [(display: Display, edge: Edge)] = displays.flatMap { display in
            edges.compactMap { edge in
                hugs(listFrame, edge, of: display.frame) ? (display, edge) : nil
            }
        }
        // Usually one candidate. Where two displays share a boundary line, a frame sliding across
        // it hugs both facing edges; rank by the edge the icons lean toward (they overhang the
        // list toward the Dock's edge), then by centering along the edge.
        func rank(_ candidate: (display: Display, edge: Edge)) -> (Int, CGFloat) {
            let leansToward = (measuredOverhang(listFrame, itemFrame, candidate.edge) ?? 0) > 0
            return (leansToward ? 0 : 1, offCenter(candidate, listFrame))
        }
        guard let match = candidates.min(by: { rank($0) < rank($1) }) else { return nil }

        let displayFrame = match.display.frame
        let measured = measuredOverhang(listFrame, itemFrame, match.edge) ?? 0
        let overhang = measured > 0 ? measured : defaultItemOverhang
        let revealedFrame: CGRect
        switch match.edge {
        case .bottom:
            let thickness = listFrame.height + overhang
            revealedFrame = CGRect(x: listFrame.minX, y: displayFrame.maxY - thickness, width: listFrame.width, height: thickness)
        case .left:
            let thickness = listFrame.width + overhang
            revealedFrame = CGRect(x: displayFrame.minX, y: listFrame.minY, width: thickness, height: listFrame.height)
        case .right:
            let thickness = listFrame.width + overhang
            revealedFrame = CGRect(x: displayFrame.maxX - thickness, y: listFrame.minY, width: thickness, height: listFrame.height)
        }
        return DockLocation(display: match.display, edge: match.edge, revealedFrame: revealedFrame)
    }

    /// True when the frame sits on the given edge of the display: within the display along the edge,
    /// and within one Dock thickness of the edge line across it — which covers the whole slide, from
    /// fully off-screen to fully revealed (a revealed list stops a few points short of the edge).
    private static func hugs(_ frame: CGRect, _ edge: Edge, of display: CGRect) -> Bool {
        switch edge {
        case .bottom:
            return frame.minX >= display.minX - tolerance
                && frame.maxX <= display.maxX + tolerance
                && abs(display.maxY - frame.midY) <= 1.5 * frame.height
        case .left:
            return frame.minY >= display.minY - tolerance
                && frame.maxY <= display.maxY + tolerance
                && abs(display.minX - frame.midX) <= 1.5 * frame.width
        case .right:
            return frame.minY >= display.minY - tolerance
                && frame.maxY <= display.maxY + tolerance
                && abs(display.maxX - frame.midX) <= 1.5 * frame.width
        }
    }

    /// How far the frame's midpoint along the edge sits from the display's.
    private static func offCenter(_ candidate: (display: Display, edge: Edge), _ frame: CGRect) -> CGFloat {
        switch candidate.edge {
        case .bottom:
            return abs(frame.midX - candidate.display.frame.midX)
        case .left, .right:
            return abs(frame.midY - candidate.display.frame.midY)
        }
    }

    /// How far the item extends past the list toward the given edge (negative: away from it).
    /// Rounded to whole points, since the two frames are read one after the other and can be a
    /// fraction of a point apart mid-slide.
    private static func measuredOverhang(_ list: CGRect, _ item: CGRect?, _ edge: Edge) -> CGFloat? {
        guard let item else { return nil }
        switch edge {
        case .bottom:
            return (item.maxY - list.maxY).rounded()
        case .left:
            return (list.minX - item.minX).rounded()
        case .right:
            return (item.maxX - list.maxX).rounded()
        }
    }
}
