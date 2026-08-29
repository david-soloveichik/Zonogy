import Foundation

/// Guardrail tests for `WindowPlacementManager.shouldRetargetAfterFloatingFill`, the gate
/// deciding whether a floating-zone placement applies the retarget-after-fill rule.
enum WindowPlacementManagerFloatingFillRetargetTests {
    @discardableResult
    static func run() -> Bool {
        var allPassed = true

        func assert(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() {
                print("WindowPlacementManagerFloatingFillRetargetTests: \(message)")
                allPassed = false
            }
        }

        assert(
            WindowPlacementManager.shouldRetargetAfterFloatingFill(
                destinationWasTargeted: true,
                forceRetargetAfterFill: false,
                wasAlreadyOccupantOfDestination: false
            ),
            "filling the targeted floating zone should retarget"
        )

        assert(
            WindowPlacementManager.shouldRetargetAfterFloatingFill(
                destinationWasTargeted: false,
                forceRetargetAfterFill: true,
                wasAlreadyOccupantOfDestination: false
            ),
            "a forced fill (e.g. a row drop) should retarget even when the floating zone was not targeted"
        )

        assert(
            !WindowPlacementManager.shouldRetargetAfterFloatingFill(
                destinationWasTargeted: false,
                forceRetargetAfterFill: false,
                wasAlreadyOccupantOfDestination: false
            ),
            "filling a non-targeted floating zone without force should not retarget"
        )

        assert(
            !WindowPlacementManager.shouldRetargetAfterFloatingFill(
                destinationWasTargeted: true,
                forceRetargetAfterFill: true,
                wasAlreadyOccupantOfDestination: true
            ),
            "re-placing the floating zone's own occupant should never retarget, even targeted or forced"
        )

        if allPassed {
            print("WindowPlacementManagerFloatingFillRetargetTests: all tests passed")
        }
        return allPassed
    }
}
