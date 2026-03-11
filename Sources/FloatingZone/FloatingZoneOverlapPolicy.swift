import CoreGraphics

/// Pure, deterministic overlap policy for floating-zone interactions with tiling zones.
enum FloatingZoneOverlapPolicy {
    /// Returns true when the floating window meaningfully overlaps the tiling zone's frame.
    static func overlapsZoneFrame(
        floatingFrame: CGRect,
        zoneFrame: CGRect,
        minIntersectionDimension: CGFloat = 1
    ) -> Bool {
        let intersection = floatingFrame.standardized.intersection(zoneFrame.standardized)
        return !intersection.isNull &&
            intersection.width > minIntersectionDimension &&
            intersection.height > minIntersectionDimension
    }
}
