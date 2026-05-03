import Foundation

/// Guardrail tests for `MinimizeLoopGuard`.
enum MinimizeLoopGuardTests {
    @discardableResult
    static func run() -> Bool {
        var allPassed = true

        func assert(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() {
                print("MinimizeLoopGuardTests: \(message)")
                allPassed = false
            }
        }

        // A bare external deminiaturize (no preceding programmatic minimize) does not
        // count toward the loop threshold.
        do {
            let guardInstance = MinimizeLoopGuard()
            let activated = guardInstance.recordExternalDeminiaturize(windowId: 1)
            assert(!activated, "deminiaturize without a recent programmatic minimize should not activate the guard")
            assert(!guardInstance.isLoopActive, "guard should remain inactive after a bare external deminiaturize")
        }

        // A single programmatic-minimize-then-rapid-deminiaturize is suspicious but below
        // threshold; the guard does not activate yet.
        do {
            let guardInstance = MinimizeLoopGuard()
            guardInstance.recordProgrammaticMinimize(windowId: 1)
            let activated = guardInstance.recordExternalDeminiaturize(windowId: 1)
            assert(!activated, "single rapid re-unminimize should not yet activate the guard")
            assert(!guardInstance.isLoopActive, "guard should not be active after a single rapid re-unminimize")
        }

        // Two rapid re-unminimizes (across different windows, simulating the ping-pong)
        // cross the threshold and activate the guard.
        do {
            let guardInstance = MinimizeLoopGuard()
            guardInstance.recordProgrammaticMinimize(windowId: 1)
            _ = guardInstance.recordExternalDeminiaturize(windowId: 1)
            guardInstance.recordProgrammaticMinimize(windowId: 2)
            let activated = guardInstance.recordExternalDeminiaturize(windowId: 2)
            assert(activated, "second rapid re-unminimize should activate the guard")
            assert(guardInstance.isLoopActive, "guard should report active after threshold is crossed")
        }

        // A second activation while already active does not return true (it just extends
        // the active window).
        do {
            let guardInstance = MinimizeLoopGuard()
            guardInstance.recordProgrammaticMinimize(windowId: 1)
            _ = guardInstance.recordExternalDeminiaturize(windowId: 1)
            guardInstance.recordProgrammaticMinimize(windowId: 2)
            _ = guardInstance.recordExternalDeminiaturize(windowId: 2)
            // Third event while already active.
            guardInstance.recordProgrammaticMinimize(windowId: 3)
            let activated = guardInstance.recordExternalDeminiaturize(windowId: 3)
            assert(!activated, "subsequent rapid re-unminimizes while already active should not re-trigger activation")
            assert(guardInstance.isLoopActive, "guard should remain active")
        }

        if allPassed {
            print("MinimizeLoopGuardTests: all tests passed")
        }
        return allPassed
    }
}
