import CoreGraphics

/// Shared hover-exit policy for edge-mounted indicator pills.
enum EdgeIndicatorHoverExitPolicy {
    enum Action: Equatable {
        case keepHover
        case recheckAfterDelay
        case clearHover
    }

    /// Determines whether a delayed hover-exit check should keep hover, retry, or clear.
    static func action(localPoint: CGPoint, bounds: CGRect, hysteresisPadding: CGFloat) -> Action {
        if bounds.contains(localPoint) {
            return .keepHover
        }

        let paddedBounds = bounds.insetBy(dx: -hysteresisPadding, dy: -hysteresisPadding)
        if paddedBounds.contains(localPoint) {
            return .recheckAfterDelay
        }

        return .clearHover
    }
}
