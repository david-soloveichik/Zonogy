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

        // Selection classification mirrors the performed action one-to-one.
        func outcome(_ action: CmdTabTemporaryTargetPolicy.SelectionAction) -> CmdTabTemporaryTargetPolicy.Outcome {
            CmdTabTemporaryTargetPolicy.outcomeForSelection(action: action)
        }
        assert(outcome(.activatedInPlace) == .activatedExistingWindow, "an in-place activation restores the original target")
        assert(outcome(.placed) == .placedOrOpenedWindow, "a placement (unminimize, or a window parked behind full screen) keeps the temporary target")
        assert(outcome(.selectionUntracked) == .selectedVanishedWindow, "an untracked selection places nothing, so the original target is restored")
        assert(outcome(.ignored) == .selectedVanishedWindow, "an ignored selection places nothing, so the original target is restored")

        if allPassed {
            print("CmdTabTemporaryTargetPolicyTests: all tests passed")
        }
        return allPassed
    }
}
