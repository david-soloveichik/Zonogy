import CoreGraphics

/// Pure, deterministic overlap policy for temporary-zone interactions with tiling zones.
enum TemporaryZoneOverlapPolicy {
    /// Returns true when the temporary window meaningfully overlaps the tiling zone's frame.
    static func overlapsZoneFrame(
        temporaryFrame: CGRect,
        zoneFrame: CGRect,
        minIntersectionDimension: CGFloat = 1
    ) -> Bool {
        let intersection = temporaryFrame.standardized.intersection(zoneFrame.standardized)
        return !intersection.isNull &&
            intersection.width > minIntersectionDimension &&
            intersection.height > minIntersectionDimension
    }
}
