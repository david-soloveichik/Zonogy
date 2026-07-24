import AppKit
import CoreGraphics

/// Shared sizing and window-level constants for edge-mounted indicator pills (floating targeting + add-zone).
enum EdgeIndicatorPillSizing {
    static let baseThickness: CGFloat = 6
    static let hoverThickness: CGFloat = 10
    static let dragThickness: CGFloat = 12
    /// Extra depth a pill's window and hit area extend past the screen edge, beyond the visible
    /// thickness. On screens placed above/left of the primary screen (negative global
    /// coordinates), a hard-slammed cursor pins on the screen-boundary coordinate itself, which
    /// lies outside a hit rectangle that ends flush at the edge. The overhang keeps such a cursor
    /// inside every app-side hit test (edge-pill trackers used by managed-window drags and the
    /// external-drag hover/drop rescue). It is applied only where the strip past the edge is
    /// void — where a display adjoins, the cursor travels through instead of pinning, and the
    /// overhang would wrongly reach into the neighbor's territory. Note the overhang cannot help
    /// AppKit drag-session delivery: window drag regions are clipped to the on-screen area,
    /// which is why the external-drag rescue in `ExternalZoneDropInterceptor` exists at all.
    static let edgeHitOverhang: CGFloat = 2
}
