import Foundation
import CoreGraphics

/// Simple assertions for FloatingZoneOverlapPolicy behavior.
enum FloatingZoneOverlapPolicyTests {
    @discardableResult
    static func run() -> Bool {
        var allPassed = true

        func assertEqual(_ actual: Bool, _ expected: Bool, label: String) {
            guard actual == expected else {
                print("FloatingZoneOverlapPolicyTests: \(label) failed\n  expected: \(expected)\n  actual:   \(actual)")
                allPassed = false
                return
            }
        }

        // A window overlapping the zone frame should count.
        do {
            let overlaps = FloatingZoneOverlapPolicy.overlapsZoneFrame(
                floatingFrame: CGRect(x: 40, y: 40, width: 80, height: 80),
                zoneFrame: CGRect(x: 0, y: 0, width: 100, height: 100)
            )
            assertEqual(overlaps, true, label: "overlap-zone-frame")
        }

        // Tiny edge contact should be ignored.
        do {
            let overlaps = FloatingZoneOverlapPolicy.overlapsZoneFrame(
                floatingFrame: CGRect(x: 99, y: 0, width: 50, height: 100),
                zoneFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
                minIntersectionDimension: 1
            )
            assertEqual(overlaps, false, label: "tiny-overlap-ignored")
        }

        // Guardrail: overlap is determined by the zone frame, not a wider revealed window frame.
        do {
            let floatingFrame = CGRect(x: 120, y: 0, width: 80, height: 100)
            let zoneFrame = CGRect(x: 0, y: 0, width: 100, height: 100)
            let overlaps = FloatingZoneOverlapPolicy.overlapsZoneFrame(
                floatingFrame: floatingFrame,
                zoneFrame: zoneFrame
            )
            assertEqual(overlaps, false, label: "zone-frame-not-revealed-window-frame")
        }

        if allPassed {
            print("FloatingZoneOverlapPolicyTests: all tests passed")
        }
        return allPassed
    }
}
