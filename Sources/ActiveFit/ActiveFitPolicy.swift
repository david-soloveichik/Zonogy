import CoreGraphics

/// Computes whether an oversized zone occupant qualifies for ActiveFit reveal mode.
///
/// ActiveFit has two modes:
/// - **Rest mode**: Window is anchored to its rest origin; may overflow off-screen (default state).
/// - **Reveal mode**: Window is shifted so entire frame fits on screen (when window is active).
///
/// This policy determines the reveal frame for windows that would overflow in rest mode.
enum ActiveFitPolicy {
    /// Computes the rest-mode origin for zone 1 when its occupant cannot shrink to fit.
    ///
    /// When a window in zone 1 is wider than the zone's content frame, keeping it anchored at the
    /// zone origin would cause it to overlap the right column. In rest mode we instead shift the
    /// window left so its right edge aligns with the zone's right edge, pushing the overflow off
    /// the left side of the screen.
    static func restOriginForZoneOne(zoneFrame: CGRect, windowSize: CGSize, tolerance: CGFloat) -> CGPoint {
        let standardizedZone = zoneFrame.standardized
        guard windowSize.width > 0 else {
            return standardizedZone.origin
        }

        let overflow = windowSize.width - standardizedZone.width
        guard overflow > tolerance else {
            return standardizedZone.origin
        }

        return CGPoint(x: standardizedZone.maxX - windowSize.width, y: standardizedZone.origin.y)
    }

    /// Computes the reveal mode frame for a window, or `nil` if no translation is needed.
    ///
    /// When a window in a zone would overflow the screen bounds in rest mode (anchored at the
    /// provided origin), this method calculates the shifted position that keeps it fully visible.
    ///
    /// - Returns: The reveal frame if the window qualifies for reveal mode, or `nil` if the
    ///   window fits on screen in rest mode and no translation is required.
    static func revealFrameIfNeeded(
        zoneIndex: Int,
        zoneOrigin: CGPoint,
        windowSize: CGSize,
        screenBounds: CGRect,
        tolerance: CGFloat
    ) -> CGRect? {
        guard zoneIndex >= 1 else {
            return nil
        }
        guard windowSize.width > 0, windowSize.height > 0 else {
            return nil
        }

        var adjustedOrigin = zoneOrigin
        var requiresTranslation = false

        let rightOverflow = (adjustedOrigin.x + windowSize.width) - screenBounds.maxX
        if rightOverflow > tolerance {
            adjustedOrigin.x -= rightOverflow
            requiresTranslation = true
        }

        let bottomOverflow = (adjustedOrigin.y + windowSize.height) - screenBounds.maxY
        if bottomOverflow > tolerance {
            adjustedOrigin.y -= bottomOverflow
            requiresTranslation = true
        }

        if adjustedOrigin.x < screenBounds.minX {
            if screenBounds.minX - adjustedOrigin.x > tolerance {
                requiresTranslation = true
            }
            adjustedOrigin.x = screenBounds.minX
        }

        if adjustedOrigin.y < screenBounds.minY {
            if screenBounds.minY - adjustedOrigin.y > tolerance {
                requiresTranslation = true
            }
            adjustedOrigin.y = screenBounds.minY
        }

        guard requiresTranslation else {
            return nil
        }

        return CGRect(origin: adjustedOrigin, size: windowSize)
    }
}
