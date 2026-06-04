import Foundation

/// Lightweight runtime assertions for FrameRetryPolicy's settle decision.
enum FrameRetryPolicyTests {
    @discardableResult
    static func run() -> Bool {
        var allPassed = true

        func assert(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() {
                print("FrameRetryPolicyTests: \(message)")
                allPassed = false
            }
        }

        // Settled only when positioned and the app accepted the write. A min/max-constrained
        // window takes the write (accepted) but stays a different size — still settled.
        assert(
            FrameRetryPolicy.hasSettled(originAtTarget: true, writeAccepted: true),
            "settled when origin is at target and the write was accepted"
        )

        // Rejected write at a correct origin (the NordVPN-at-creation case): not settled.
        assert(
            !FrameRetryPolicy.hasSettled(originAtTarget: true, writeAccepted: false),
            "not settled when the write was rejected, even at a correct origin"
        )

        // Origin not yet at target though the write was accepted (drift / mid-move): not settled.
        assert(
            !FrameRetryPolicy.hasSettled(originAtTarget: false, writeAccepted: true),
            "not settled while the origin has not reached the target"
        )

        // Neither done: not settled.
        assert(
            !FrameRetryPolicy.hasSettled(originAtTarget: false, writeAccepted: false),
            "not settled when neither origin nor write is done"
        )

        if allPassed {
            print("FrameRetryPolicyTests: all tests passed")
        }
        return allPassed
    }
}
