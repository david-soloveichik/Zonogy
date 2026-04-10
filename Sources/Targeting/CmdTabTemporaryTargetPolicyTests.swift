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

        if allPassed {
            print("CmdTabTemporaryTargetPolicyTests: all tests passed")
        }
        return allPassed
    }
}
