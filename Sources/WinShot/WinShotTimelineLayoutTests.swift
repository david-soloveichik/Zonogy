import CoreGraphics
import Foundation

/// Guardrail tests for WinShot timeline timestamp-to-X layout mapping.
enum WinShotTimelineLayoutTests {
    @discardableResult
    static func run() -> Bool {
        var allPassed = true

        func assertNear(_ actual: CGFloat, _ expected: CGFloat, _ tolerance: CGFloat, _ message: String) {
            if abs(actual - expected) > tolerance {
                print("WinShotTimelineLayoutTests: \(message) (actual: \(actual), expected: \(expected))")
                allPassed = false
            }
        }

        func assert(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() {
                print("WinShotTimelineLayoutTests: \(message)")
                allPassed = false
            }
        }

        do {
            let now = Date(timeIntervalSinceReferenceDate: 500)
            let createdAt = [now, now.addingTimeInterval(-60), now.addingTimeInterval(-180)]
            let tileCenterXs: [CGFloat] = [20, 60, 100]
            let xs = WinShotTimelineLayout.timelineXs(
                createdAt: createdAt,
                tileCenterXs: tileCenterXs,
                railStartX: 20,
                railEndX: 100
            )
            assert(xs.count == 3, "should return one x value per snapshot")
            assertNear(xs[0], 20, 0.0001, "newest snapshot should map to left edge")
            assertNear(xs[1], 46.6667, 0.001, "mid timestamp should map proportionally")
            assertNear(xs[2], 100, 0.0001, "oldest snapshot should map to right edge")
        }

        do {
            let same = Date(timeIntervalSinceReferenceDate: 1_000)
            let createdAt = [same, same, same]
            let tileCenterXs: [CGFloat] = [12, 44, 90]
            let xs = WinShotTimelineLayout.timelineXs(
                createdAt: createdAt,
                tileCenterXs: tileCenterXs,
                railStartX: 12,
                railEndX: 90
            )
            assert(xs == tileCenterXs, "equal timestamps should fall back to tile centers")
        }

        do {
            let createdAt = [Date(timeIntervalSinceReferenceDate: 1_200)]
            let tileCenterXs: [CGFloat] = [33]
            let xs = WinShotTimelineLayout.timelineXs(
                createdAt: createdAt,
                tileCenterXs: tileCenterXs,
                railStartX: 10,
                railEndX: 70
            )
            assert(xs == [33], "single snapshot should stay above its tile center")
        }

        do {
            let createdAt = [Date(), Date()]
            let tileCenterXs: [CGFloat] = [10]
            let xs = WinShotTimelineLayout.timelineXs(
                createdAt: createdAt,
                tileCenterXs: tileCenterXs,
                railStartX: 10,
                railEndX: 20
            )
            assert(xs.isEmpty, "mismatched input lengths should return empty output")
        }

        if allPassed {
            print("WinShotTimelineLayoutTests: all tests passed")
        }
        return allPassed
    }
}
