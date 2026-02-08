import Foundation
import CoreGraphics

/// Pure geometry helpers for clipping/hiding zone resize handle frames.
enum ZoneResizeHandleGeometry {
    /// Shrinks a frame inward by `inset` while preserving at least 1px dimensions.
    /// Useful for ignoring tiny visual overlaps (e.g., shadows) when deciding handle avoidance.
    static func insetAvoidanceFrame(_ frame: CGRect, by inset: CGFloat) -> CGRect {
        let standardized = frame.standardized
        let insetX = min(inset, max(0, (standardized.width - 1) / 2))
        let insetY = min(inset, max(0, (standardized.height - 1) / 2))
        return standardized.insetBy(dx: insetX, dy: insetY).standardized
    }

    /// Returns a clipped separator frame that avoids `avoidFrame` by keeping the largest remaining segment,
    /// or `nil` if the separator is fully covered.
    static func clippedSeparatorFrame(
        _ separatorFrame: CGRect,
        avoiding avoidFrame: CGRect,
        orientation: ZoneLayout.SeparatorOrientation
    ) -> CGRect? {
        let original = separatorFrame.standardized
        let intersection = original.intersection(avoidFrame.standardized).standardized
        guard !intersection.isNull else {
            return original
        }

        switch orientation {
        case .vertical:
            guard intersection.height > 0 else {
                return original
            }

            let topGap = max(0, intersection.minY - original.minY)
            let bottomGap = max(0, original.maxY - intersection.maxY)
            let maxGap = max(topGap, bottomGap)

            guard maxGap > 0 else {
                return nil
            }

            if topGap >= bottomGap {
                return CGRect(
                    x: original.minX,
                    y: original.minY,
                    width: original.width,
                    height: topGap
                )
            }
            return CGRect(
                x: original.minX,
                y: intersection.maxY,
                width: original.width,
                height: bottomGap
            )

        case .horizontal:
            guard intersection.width > 0 else {
                return original
            }

            let leftGap = max(0, intersection.minX - original.minX)
            let rightGap = max(0, original.maxX - intersection.maxX)
            let maxGap = max(leftGap, rightGap)

            guard maxGap > 0 else {
                return nil
            }

            if leftGap >= rightGap {
                return CGRect(
                    x: original.minX,
                    y: original.minY,
                    width: leftGap,
                    height: original.height
                )
            }
            return CGRect(
                x: intersection.maxX,
                y: original.minY,
                width: rightGap,
                height: original.height
            )
        }
    }
}
