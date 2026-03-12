import Foundation
import CoreGraphics

/// Pure geometry helpers for clipping/hiding zone resize handle frames.
enum ZoneResizeHandleGeometry {
    private static func clippedAxisRange(
        originalRange: ClosedRange<CGFloat>,
        intersectionRange: ClosedRange<CGFloat>,
        requiredRange: ClosedRange<CGFloat>?
    ) -> ClosedRange<CGFloat>? {
        if let requiredRange {
            if requiredRange.upperBound <= intersectionRange.lowerBound {
                return originalRange.lowerBound...intersectionRange.lowerBound
            }
            if requiredRange.lowerBound >= intersectionRange.upperBound {
                return intersectionRange.upperBound...originalRange.upperBound
            }
            return requiredRange
        }

        let leadingGap = max(0, intersectionRange.lowerBound - originalRange.lowerBound)
        let trailingGap = max(0, originalRange.upperBound - intersectionRange.upperBound)
        let maxGap = max(leadingGap, trailingGap)

        guard maxGap > 0 else {
            return nil
        }

        if leadingGap >= trailingGap {
            return originalRange.lowerBound...intersectionRange.lowerBound
        }
        return intersectionRange.upperBound...originalRange.upperBound
    }

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
        orientation: ZoneLayout.SeparatorOrientation,
        minimumVisibleFrame: CGRect? = nil
    ) -> CGRect? {
        let original = separatorFrame.standardized
        let intersection = original.intersection(avoidFrame.standardized).standardized
        guard !intersection.isNull else {
            return original
        }

        let requiredFrame = minimumVisibleFrame?.standardized.intersection(original).standardized

        switch orientation {
        case .vertical:
            guard intersection.height > 0 else {
                return original
            }

            let requiredRange: ClosedRange<CGFloat>? = {
                guard let requiredFrame,
                      !requiredFrame.isNull,
                      requiredFrame.height > 0 else {
                    return nil
                }
                return requiredFrame.minY...requiredFrame.maxY
            }()
            guard let clippedRange = clippedAxisRange(
                originalRange: original.minY...original.maxY,
                intersectionRange: intersection.minY...intersection.maxY,
                requiredRange: requiredRange
            ) else {
                return nil
            }
            return CGRect(
                x: original.minX,
                y: clippedRange.lowerBound,
                width: original.width,
                height: clippedRange.upperBound - clippedRange.lowerBound
            )

        case .horizontal:
            guard intersection.width > 0 else {
                return original
            }

            let requiredRange: ClosedRange<CGFloat>? = {
                guard let requiredFrame,
                      !requiredFrame.isNull,
                      requiredFrame.width > 0 else {
                    return nil
                }
                return requiredFrame.minX...requiredFrame.maxX
            }()
            guard let clippedRange = clippedAxisRange(
                originalRange: original.minX...original.maxX,
                intersectionRange: intersection.minX...intersection.maxX,
                requiredRange: requiredRange
            ) else {
                return nil
            }
            return CGRect(
                x: clippedRange.lowerBound,
                y: original.minY,
                width: clippedRange.upperBound - clippedRange.lowerBound,
                height: original.height
            )
        }
    }
}
