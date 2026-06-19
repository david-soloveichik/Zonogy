/// Pure geometry helper mapping WinShot snapshot time gaps to inter-thumbnail spacing.
///
/// The scale is *adaptive*: the intervals between the snapshots currently shown are
/// log-transformed and then stretched across the visual range so the shortest interval is
/// drawn tight and the longest wide. This keeps the gaps legibly distinct whether the set
/// spans seconds or days. A minimum log-span floor damps sets whose intervals are all
/// near-equal, so they stay near minGap rather than being stretched to the full range.
import CoreGraphics
import Foundation

enum WinShotGapLayout {
    /// Tunable parameters controlling how the set of time intervals maps to pixel gaps.
    struct Config {
        /// Spacing (points) drawn for the shortest interval in the set.
        var minGap: CGFloat
        /// Upper bound on spacing (points); the longest interval reaches it only when the
        /// set's log-spread is at least minSpanDecades (otherwise the longest stays below it).
        var maxGap: CGFloat
        /// Seconds added inside the logarithm so a zero interval is well-defined.
        var referenceInterval: TimeInterval
        /// Minimum log10 spread (in decades) of the set's intervals before the full
        /// [minGap, maxGap] range is used. When the actual spread is smaller, the visual
        /// spread scales down proportionally, so a set of near-equal intervals is not
        /// exaggerated (and a lone interval collapses to minGap).
        var minSpanDecades: CGFloat

        static let `default` = Config(
            minGap: 16,
            maxGap: 150,
            referenceInterval: 1,
            minSpanDecades: 0.3
        )
    }

    /// Leading gap (points) before each thumbnail, given snapshot timestamps in display
    /// order (newest-first, left-to-right). The first thumbnail has no leading gap (0).
    ///
    /// Each remaining gap encodes the elapsed time between that snapshot and the previous
    /// one, normalized across the whole set: the shortest interval maps to minGap and the
    /// longest toward maxGap, logarithmically in between. When the intervals are all
    /// near-equal (log-spread below minSpanDecades) the gaps stay near minGap instead of
    /// filling the range. The interval magnitude is used, so the spacing is identical
    /// regardless of sort direction (a gap means "time between these two adjacent snapshots").
    static func leadingGaps(createdAt: [Date], config: Config = .default) -> [CGFloat] {
        guard !createdAt.isEmpty else { return [] }
        guard createdAt.count > 1 else { return [0] }

        let reference = max(config.referenceInterval, .leastNonzeroMagnitude)
        let transformed: [CGFloat] = (1..<createdAt.count).map { index in
            let delta = abs(createdAt[index - 1].timeIntervalSince(createdAt[index]))
            return CGFloat(log10(1 + max(0, delta) / reference))
        }

        let minTransformed = transformed.min() ?? 0
        let maxTransformed = transformed.max() ?? 0
        let spread = max(maxTransformed - minTransformed, config.minSpanDecades)
        let denominator = spread > 0 ? spread : 1
        let visualSpan = config.maxGap - config.minGap

        var gaps: [CGFloat] = [0]
        gaps.reserveCapacity(createdAt.count)
        for value in transformed {
            let normalized = min(max((value - minTransformed) / denominator, 0), 1)
            gaps.append(config.minGap + normalized * visualSpan)
        }
        return gaps
    }

    /// Total content width to lay out `leadingGaps.count` thumbnails of `tileWidth`
    /// separated by the supplied leading gaps.
    static func contentWidth(tileWidth: CGFloat, leadingGaps: [CGFloat]) -> CGFloat {
        guard !leadingGaps.isEmpty else { return 0 }
        let tiles = CGFloat(leadingGaps.count) * tileWidth
        return tiles + leadingGaps.reduce(0, +)
    }
}
