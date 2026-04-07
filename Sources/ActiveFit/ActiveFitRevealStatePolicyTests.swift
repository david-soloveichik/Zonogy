import CoreGraphics
import Foundation

/// Lightweight runtime assertions for ActiveFit reveal-state reuse decisions.
enum ActiveFitRevealStatePolicyTests {
    @discardableResult
    static func run() -> Bool {
        var allPassed = true

        func assert(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() {
                print("ActiveFitRevealStatePolicyTests: \(message)")
                allPassed = false
            }
        }

        let tolerance: CGFloat = 1.0
        let revealFrame = CGRect(x: 823, y: 33, width: 1097, height: 895)
        let restFrame = CGRect(x: 1297, y: 33, width: 1097, height: 895)

        assert(
            !ActiveFitRevealStatePolicy.shouldReuseExistingRevealFrame(
                existingRevealFrame: nil,
                desiredRevealFrame: revealFrame,
                actualFrame: revealFrame,
                tolerance: tolerance
            ),
            "missing cached reveal frame should force a reveal move"
        )

        assert(
            ActiveFitRevealStatePolicy.shouldReuseExistingRevealFrame(
                existingRevealFrame: revealFrame,
                desiredRevealFrame: revealFrame,
                actualFrame: revealFrame,
                tolerance: tolerance
            ),
            "matching cached and actual reveal frames should reuse reveal state"
        )

        assert(
            !ActiveFitRevealStatePolicy.shouldReuseExistingRevealFrame(
                existingRevealFrame: revealFrame,
                desiredRevealFrame: revealFrame,
                actualFrame: restFrame,
                tolerance: tolerance
            ),
            "rest-position actual frame should force reapplying reveal geometry"
        )

        assert(
            !ActiveFitRevealStatePolicy.shouldReuseExistingRevealFrame(
                existingRevealFrame: revealFrame,
                desiredRevealFrame: CGRect(x: 700, y: 33, width: 1097, height: 895),
                actualFrame: revealFrame,
                tolerance: tolerance
            ),
            "changed desired reveal frame should not reuse stale cached state"
        )

        if allPassed {
            print("ActiveFitRevealStatePolicyTests: all tests passed")
        }
        return allPassed
    }
}
