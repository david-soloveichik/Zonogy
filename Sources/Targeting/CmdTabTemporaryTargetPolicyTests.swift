/// Guardrail tests for CmdTab temporary-target restoration decisions.
enum CmdTabTemporaryTargetPolicyTests {
    @discardableResult
    static func run() -> Bool {
        var allPassed = true

        func assert(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() {
                print("CmdTabTemporaryTargetPolicyTests: \(message)")
                allPassed = false
            }
        }

        assert(
            CmdTabTemporaryTargetPolicy.shouldRestoreOriginalTarget(after: .cancelled),
            "cancelled CmdTab sessions should restore the original target"
        )
        assert(
            CmdTabTemporaryTargetPolicy.shouldRestoreOriginalTarget(after: .activatedExistingWindow),
            "activating an already-open window should restore the original target"
        )
        assert(
            !CmdTabTemporaryTargetPolicy.shouldRestoreOriginalTarget(after: .placedOrOpenedWindow),
            "placing or opening a window should keep the temporary target"
        )
        assert(
            !CmdTabTemporaryTargetPolicy.shouldRestoreOriginalTarget(after: .interrupted),
            "external interruptions should not restore over a newer target"
        )
        assert(
            CmdTabTemporaryTargetPolicy.shouldRestoreOriginalTarget(after: .selectedVanishedWindow),
            "selecting a vanished window places nothing, so the original target should be restored"
        )

        // Selection classification: placed/unplaced crossed with managed/vanished.
        func outcome(placed: Bool, managed: Bool) -> CmdTabTemporaryTargetPolicy.Outcome {
            CmdTabTemporaryTargetPolicy.outcomeForSelection(isPlacedInZone: placed, windowStillManaged: managed)
        }
        assert(outcome(placed: true, managed: true) == .activatedExistingWindow, "a placed managed window is merely activated")
        assert(outcome(placed: false, managed: true) == .placedOrOpenedWindow, "an unplaced managed window unminimizes into the target")
        assert(outcome(placed: false, managed: false) == .selectedVanishedWindow, "a vanished window is classified as vanished")
        assert(outcome(placed: true, managed: false) == .selectedVanishedWindow, "a stale placed flag cannot outrank a vanished window")

        if allPassed {
            print("CmdTabTemporaryTargetPolicyTests: all tests passed")
        }
        return allPassed
    }
}
