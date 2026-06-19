import CoreGraphics
import Foundation

/// Guardrail tests for WinShot adaptive (set-normalized) log gap mapping.
enum WinShotGapLayoutTests {
    @discardableResult
    static func run() -> Bool {
        var allPassed = true

        func assert(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() {
                print("WinShotGapLayoutTests: \(message)")
                allPassed = false
            }
        }

        func near(_ a: CGFloat, _ b: CGFloat, _ tol: CGFloat = 0.5) -> Bool { abs(a - b) <= tol }

        let config = WinShotGapLayout.Config.default
        let minGap = config.minGap
        let maxGap = config.maxGap
        let base = Date(timeIntervalSinceReferenceDate: 1_000_000)

        // Build newest-first timestamps from consecutive deltas (seconds).
        func timestamps(fromDeltas deltas: [TimeInterval]) -> [Date] {
            var dates = [base]
            var elapsed: TimeInterval = 0
            for delta in deltas {
                elapsed += delta
                dates.append(base.addingTimeInterval(-elapsed))
            }
            return dates
        }

        // Degenerate inputs.
        assert(WinShotGapLayout.leadingGaps(createdAt: [], config: config).isEmpty,
               "empty input yields empty gaps")
        assert(WinShotGapLayout.leadingGaps(createdAt: [base], config: config) == [0],
               "single snapshot yields a single zero gap")

        // Two snapshots: a lone interval has no spread, so it collapses to minGap.
        let two = WinShotGapLayout.leadingGaps(createdAt: timestamps(fromDeltas: [3_600]), config: config)
        assert(two.count == 2 && two[0] == 0 && near(two[1], minGap),
               "two snapshots yield [0, minGap]")

        // Increasing intervals: first thumbnail 0, shortest -> minGap, longest -> maxGap,
        // middle strictly between, strictly monotonic.
        let inc = WinShotGapLayout.leadingGaps(createdAt: timestamps(fromDeltas: [10, 100, 1_000]), config: config)
        assert(inc.count == 4 && inc[0] == 0, "one leading gap per snapshot, first is zero")
        assert(near(inc[1], minGap), "shortest interval maps to minGap")
        assert(near(inc[3], maxGap), "longest interval maps to maxGap")
        assert(inc[2] > minGap && inc[2] < maxGap, "middle interval lands strictly between")
        assert(inc[1] < inc[2] && inc[2] < inc[3], "gaps increase with interval length")

        // Adaptivity: a tightly-clustered set (all within ~1 decade) still spans the full
        // visual range — this is the whole point of normalizing per set.
        let clustered = WinShotGapLayout.leadingGaps(
            createdAt: timestamps(fromDeltas: [20, 35, 50, 80, 150]), config: config
        )
        let clusteredGaps = Array(clustered.dropFirst())
        assert(near(clusteredGaps.min() ?? 0, minGap), "clustered set's shortest gap reaches minGap")
        assert(near(clusteredGaps.max() ?? 0, maxGap), "clustered set's longest gap reaches maxGap")

        // The same shape regardless of absolute magnitude: scale every delta by 100x and the
        // spread still fills the range (depends on ratios, not absolute seconds).
        let clusteredScaled = WinShotGapLayout.leadingGaps(
            createdAt: timestamps(fromDeltas: [2_000, 3_500, 5_000, 8_000, 15_000]), config: config
        )
        let scaledGaps = Array(clusteredScaled.dropFirst())
        assert(near(scaledGaps.min() ?? 0, minGap) && near(scaledGaps.max() ?? 0, maxGap),
               "scaling all intervals preserves full-range spread")

        // Near-equal intervals are damped (the min-span floor), not exaggerated to maxGap.
        let nearEqual = WinShotGapLayout.leadingGaps(
            createdAt: timestamps(fromDeltas: [40, 42, 44, 41, 43]), config: config
        )
        let nearEqualGaps = Array(nearEqual.dropFirst())
        assert((nearEqualGaps.max() ?? maxGap) < minGap + 0.5 * (maxGap - minGap),
               "near-equal intervals should not be stretched to the full range")
        assert((nearEqualGaps.min() ?? 0) >= minGap - 0.5, "all gaps stay at or above minGap")

        // Order-agnostic: reversing display order produces the same set of nonzero gaps.
        let forward = WinShotGapLayout.leadingGaps(createdAt: timestamps(fromDeltas: [10, 100, 1_000]), config: config)
        let reversed = WinShotGapLayout.leadingGaps(
            createdAt: Array(timestamps(fromDeltas: [10, 100, 1_000]).reversed()), config: config
        )
        assert(Array(forward.dropFirst()).sorted() == Array(reversed.dropFirst()).sorted(),
               "sort direction does not change the multiset of gaps")

        // contentWidth sums tiles and gaps.
        assert(WinShotGapLayout.contentWidth(tileWidth: 100, leadingGaps: [0, 20, 30]) == 350,
               "contentWidth should be tiles*width + sum(gaps)")
        assert(WinShotGapLayout.contentWidth(tileWidth: 100, leadingGaps: []) == 0,
               "no thumbnails yields zero content width")

        if allPassed {
            print("WinShotGapLayoutTests: all tests passed")
        }
        return allPassed
    }
}
