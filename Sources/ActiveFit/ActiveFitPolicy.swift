import CoreGraphics

/// Computes whether an oversized zone occupant qualifies for ActiveFit reveal mode.
///
/// ActiveFit has two modes:
/// - **Rest mode**: Window is anchored to zone origin; may overflow off-screen (default state).
/// - **Reveal mode**: Window is shifted so entire frame fits on screen (when window is active).
///
/// This policy determines the reveal frame for windows that would overflow in rest mode.
enum ActiveFitPolicy {
    /// Whether a zone's occupant could ever be helped by a reveal shift. Windows anchor at the
    /// zone's top-left and overflow rightward/downward, so reveal shifts move left/up. A zone
    /// already sitting at the screen's top-left corner has nowhere to shift toward and is exempt
    /// (this is the full-screen single zone, and the big left zone of the right-bar layout).
    static func zoneCanReveal(zoneFrame: CGRect, screenBounds: CGRect, tolerance: CGFloat = 1.0) -> Bool {
        let zone = zoneFrame.standardized
        let bounds = screenBounds.standardized
        let anchoredAtLeftEdge = abs(zone.minX - bounds.minX) <= tolerance
        let anchoredAtTopEdge = abs(zone.minY - bounds.minY) <= tolerance
        return !(anchoredAtLeftEdge && anchoredAtTopEdge)
    }

    /// Computes the reveal mode frame for a window, or `nil` if no translation is needed.
    ///
    /// When a window whose zone can reveal would overflow the screen bounds in rest mode
    /// (anchored at zone origin), this method calculates the shifted position that keeps it
    /// fully visible.
    ///
    /// - Returns: The reveal frame if the window qualifies for reveal mode, or `nil` if the
    ///   window fits on screen in rest mode and no translation is required.
    static func revealFrameIfNeeded(
        zoneFrame: CGRect,
        zoneOrigin: CGPoint,
        windowSize: CGSize,
        screenBounds: CGRect,
        tolerance: CGFloat
    ) -> CGRect? {
        guard zoneCanReveal(zoneFrame: zoneFrame, screenBounds: screenBounds) else {
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
