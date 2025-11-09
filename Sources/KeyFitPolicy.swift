import CoreGraphics

/// Computes whether an oversized zone occupant should be translated so its full frame fits on screen.
enum KeyFitPolicy {
    /// Returns a frame that keeps the window wholly inside the screen, or `nil` if no translation is required.
    static func revealFrameIfNeeded(
        zoneIndex: Int,
        zoneOrigin: CGPoint,
        windowSize: CGSize,
        screenBounds: CGRect,
        tolerance: CGFloat
    ) -> CGRect? {
        guard zoneIndex >= 2 else {
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
