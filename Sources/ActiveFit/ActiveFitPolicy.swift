import CoreGraphics

/// Computes whether an oversized zone occupant qualifies for ActiveFit reveal mode.
///
/// ActiveFit has two modes:
/// - **Rest mode**: Window is anchored to zone origin; may overflow off-screen (default state).
/// - **Reveal mode**: Window is shifted so entire frame fits on screen (when window is active).
///
/// This policy determines the reveal frame for windows that would overflow in rest mode.
/// Attached sheets travel with the window and can extend past its frame, so the reveal
/// math treats the window plus its sheet overhang as one unit.
enum ActiveFitPolicy {
    /// How far a window's attached sheets extend beyond its own frame on each edge.
    /// All values are non-negative; `.none` means the window has no overhanging sheet.
    struct AttachmentOverhang: Equatable {
        var left: CGFloat = 0
        var right: CGFloat = 0
        var top: CGFloat = 0
        var bottom: CGFloat = 0

        static let none = AttachmentOverhang()
    }

    /// Measures how far the given attached frames (sheets) stick out past the window's frame.
    static func attachmentOverhang(windowFrame: CGRect, attachedFrames: [CGRect]) -> AttachmentOverhang {
        guard windowFrame.width > 0, windowFrame.height > 0 else {
            return .none
        }
        var overhang = AttachmentOverhang.none
        for frame in attachedFrames where frame.width > 0 && frame.height > 0 {
            overhang.left = max(overhang.left, windowFrame.minX - frame.minX)
            overhang.right = max(overhang.right, frame.maxX - windowFrame.maxX)
            overhang.top = max(overhang.top, windowFrame.minY - frame.minY)
            overhang.bottom = max(overhang.bottom, frame.maxY - windowFrame.maxY)
        }
        return overhang
    }

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
    /// fully visible. The overhang of any attached sheets counts toward the overflow, and the
    /// shifted position keeps the sheets on screen too. When the combined window-plus-overhang
    /// footprint cannot fit on screen, the shift is best effort: it clamps so the left/top
    /// edges stay visible (matching how an oversized window itself is revealed).
    ///
    /// - Returns: The reveal frame if the window qualifies for reveal mode, or `nil` if the
    ///   window (including sheet overhang) fits on screen in rest mode and no translation is
    ///   required.
    static func revealFrameIfNeeded(
        zoneFrame: CGRect,
        zoneOrigin: CGPoint,
        windowSize: CGSize,
        overhang: AttachmentOverhang = .none,
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

        let rightOverflow = (adjustedOrigin.x + windowSize.width + overhang.right) - screenBounds.maxX
        if rightOverflow > tolerance {
            adjustedOrigin.x -= rightOverflow
            requiresTranslation = true
        }

        let bottomOverflow = (adjustedOrigin.y + windowSize.height + overhang.bottom) - screenBounds.maxY
        if bottomOverflow > tolerance {
            adjustedOrigin.y -= bottomOverflow
            requiresTranslation = true
        }

        let minOriginX = screenBounds.minX + overhang.left
        if adjustedOrigin.x < minOriginX {
            if minOriginX - adjustedOrigin.x > tolerance {
                requiresTranslation = true
            }
            adjustedOrigin.x = minOriginX
        }

        let minOriginY = screenBounds.minY + overhang.top
        if adjustedOrigin.y < minOriginY {
            if minOriginY - adjustedOrigin.y > tolerance {
                requiresTranslation = true
            }
            adjustedOrigin.y = minOriginY
        }

        guard requiresTranslation else {
            return nil
        }

        return CGRect(origin: adjustedOrigin, size: windowSize)
    }
}
