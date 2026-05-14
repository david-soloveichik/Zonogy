import CoreGraphics

/// Pure decisions for ActiveFit reveal-state reuse and rest-transition bookkeeping.
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

    static func restTransitionZoneKey(
        cachedZoneKey: ZoneKey,
        currentScreenId: CGDirectDisplayID?,
        currentZoneIndex: Int?
    ) -> ZoneKey {
        guard let currentScreenId,
              let currentZoneIndex else {
            return cachedZoneKey
        }

        return ZoneKey(screenId: currentScreenId, index: currentZoneIndex)
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
