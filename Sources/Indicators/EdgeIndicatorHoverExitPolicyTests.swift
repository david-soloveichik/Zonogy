import Foundation
import CoreGraphics

/// Lightweight assertions for edge-indicator hover exit behavior.
enum EdgeIndicatorHoverExitPolicyTests {
    @discardableResult
    static func run() -> Bool {
        var allPassed = true

        func assertEqual(
            _ actual: EdgeIndicatorHoverExitPolicy.Action,
            _ expected: EdgeIndicatorHoverExitPolicy.Action,
            label: String
        ) {
            guard actual == expected else {
                print("EdgeIndicatorHoverExitPolicyTests: \(label) failed\n  expected: \(expected)\n  actual:   \(actual)")
                allPassed = false
                return
            }
        }

        let bounds = CGRect(x: 0, y: 0, width: 10, height: 100)
        let hysteresisPadding: CGFloat = 2

        do {
            let point = CGPoint(x: 5, y: 50)
            let action = EdgeIndicatorHoverExitPolicy.action(
                localPoint: point,
                bounds: bounds,
                hysteresisPadding: hysteresisPadding
            )
            assertEqual(action, .keepHover, label: "point inside pill keeps hover")
        }

        do {
            let point = CGPoint(x: -1, y: 50)
            let action = EdgeIndicatorHoverExitPolicy.action(
                localPoint: point,
                bounds: bounds,
                hysteresisPadding: hysteresisPadding
            )
            assertEqual(action, .recheckAfterDelay, label: "point in hysteresis band rechecks")
        }

        do {
            let point = CGPoint(x: -3, y: 50)
            let action = EdgeIndicatorHoverExitPolicy.action(
                localPoint: point,
                bounds: bounds,
                hysteresisPadding: hysteresisPadding
            )
            assertEqual(action, .clearHover, label: "point outside hysteresis clears hover")
        }

        if allPassed {
            print("EdgeIndicatorHoverExitPolicyTests: all tests passed")
        }
        return allPassed
    }
}
