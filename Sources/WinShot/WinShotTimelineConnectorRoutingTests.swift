import CoreGraphics
import Foundation

/// Guardrail tests for WinShot timeline connector lane routing.
enum WinShotTimelineConnectorRoutingTests {
    @discardableResult
    static func run() -> Bool {
        var allPassed = true

        func assert(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() {
                print("WinShotTimelineConnectorRoutingTests: \(message)")
                allPassed = false
            }
        }

        do {
            let lanes = WinShotTimelineConnectorRouting.laneIndexes(
                timelineXs: [10, 40, 70],
                tileCenterXs: [20, 50, 80],
                gap: 4,
                maxLanes: 4
            )
            assert(lanes == [0, 0, 0], "non-overlapping intervals should share lane 0")
        }

        do {
            let timelineXs: [CGFloat] = [10, 40]
            let tileXs: [CGFloat] = [60, 90]
            let lanes = WinShotTimelineConnectorRouting.laneIndexes(
                timelineXs: timelineXs,
                tileCenterXs: tileXs,
                gap: 4,
                maxLanes: 4
            )
            let score = WinShotTimelineConnectorRouting.score(
                timelineXs: timelineXs,
                tileCenterXs: tileXs,
                laneIndexes: lanes,
                gap: 4
            )
            assert(score?.crossings == 0, "partially overlapping intervals should route without crossings")
            assert(score?.overlaps == 0, "partially overlapping intervals should stagger into separate lanes")
        }

        do {
            let timelineXs: [CGFloat] = [10, 50]
            let tileXs: [CGFloat] = [90, 40]
            let lanes = WinShotTimelineConnectorRouting.laneIndexes(
                timelineXs: timelineXs,
                tileCenterXs: tileXs,
                gap: 4,
                maxLanes: 4
            )
            let score = WinShotTimelineConnectorRouting.score(
                timelineXs: timelineXs,
                tileCenterXs: tileXs,
                laneIndexes: lanes,
                gap: 4
            )
            assert(score?.crossings == 0, "nested opposite-direction intervals should avoid crossings")
        }

        do {
            let timelineXs: [CGFloat] = [15, 35, 65, 95]
            let tileXs: [CGFloat] = [90, 20, 75, 40]
            let maxLanes = 3
            let gap: CGFloat = 4

            let lanes = WinShotTimelineConnectorRouting.laneIndexes(
                timelineXs: timelineXs,
                tileCenterXs: tileXs,
                gap: gap,
                maxLanes: maxLanes
            )
            let producedScore = scoreWithLaneSum(
                timelineXs: timelineXs,
                tileCenterXs: tileXs,
                laneIndexes: lanes,
                gap: gap
            )

            let expectedBest = bruteForceBestScore(
                timelineXs: timelineXs,
                tileCenterXs: tileXs,
                gap: gap,
                maxLanes: maxLanes
            )

            if let producedScore, let expectedBest {
                assert(
                    producedScore.crossings == expectedBest.crossings &&
                    producedScore.overlaps == expectedBest.overlaps &&
                    producedScore.laneSum == expectedBest.laneSum,
                    "routing should match brute-force optimum"
                )
            } else {
                assert(false, "expected valid routing and brute-force scores")
            }
        }

        do {
            let lanes = WinShotTimelineConnectorRouting.laneIndexes(
                timelineXs: [0, 1],
                tileCenterXs: [2],
                gap: 0,
                maxLanes: 2
            )
            assert(lanes.isEmpty, "mismatched input sizes should return empty output")
        }

        if allPassed {
            print("WinShotTimelineConnectorRoutingTests: all tests passed")
        }
        return allPassed
    }

    private static func scoreWithLaneSum(
        timelineXs: [CGFloat],
        tileCenterXs: [CGFloat],
        laneIndexes: [Int],
        gap: CGFloat
    ) -> (crossings: Int, overlaps: Int, laneSum: Int)? {
        guard let score = WinShotTimelineConnectorRouting.score(
            timelineXs: timelineXs,
            tileCenterXs: tileCenterXs,
            laneIndexes: laneIndexes,
            gap: gap
        ) else {
            return nil
        }
        return (score.crossings, score.overlaps, laneIndexes.reduce(0, +))
    }

    private static func bruteForceBestScore(
        timelineXs: [CGFloat],
        tileCenterXs: [CGFloat],
        gap: CGFloat,
        maxLanes: Int
    ) -> (crossings: Int, overlaps: Int, laneSum: Int)? {
        guard timelineXs.count == tileCenterXs.count,
              !timelineXs.isEmpty,
              maxLanes > 0 else {
            return nil
        }

        let count = timelineXs.count
        var assignment = Array(repeating: 0, count: count)
        var best: (crossings: Int, overlaps: Int, laneSum: Int)?

        func recurse(_ index: Int) {
            if index == count {
                guard let score = scoreWithLaneSum(
                    timelineXs: timelineXs,
                    tileCenterXs: tileCenterXs,
                    laneIndexes: assignment,
                    gap: gap
                ) else {
                    return
                }

                if let bestExisting = best {
                    if score.crossings < bestExisting.crossings ||
                        (score.crossings == bestExisting.crossings && score.overlaps < bestExisting.overlaps) ||
                        (score.crossings == bestExisting.crossings && score.overlaps == bestExisting.overlaps && score.laneSum < bestExisting.laneSum) {
                        best = score
                    }
                } else {
                    best = score
                }
                return
            }

            for lane in 0..<maxLanes {
                assignment[index] = lane
                recurse(index + 1)
            }
        }

        recurse(0)
        return best
    }
}
