import CoreGraphics

/// Decides when cached ActiveFit reveal state can be reused without reapplying geometry.
enum ActiveFitRevealStatePolicy {
    static func shouldReuseExistingRevealFrame(
        existingRevealFrame: CGRect?,
        desiredRevealFrame: CGRect,
        actualFrame: CGRect,
        tolerance: CGFloat
    ) -> Bool {
        guard let existingRevealFrame else {
            return false
        }

        return framesClose(existingRevealFrame, desiredRevealFrame, tolerance: tolerance) &&
            framesClose(actualFrame, desiredRevealFrame, tolerance: tolerance)
    }

    private static func framesClose(
        _ lhs: CGRect,
        _ rhs: CGRect,
        tolerance: CGFloat
    ) -> Bool {
        abs(lhs.minX - rhs.minX) <= tolerance &&
            abs(lhs.minY - rhs.minY) <= tolerance &&
            abs(lhs.width - rhs.width) <= tolerance &&
            abs(lhs.height - rhs.height) <= tolerance
    }
}
