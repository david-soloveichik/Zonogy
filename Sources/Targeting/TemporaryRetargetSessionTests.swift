/// Guardrail tests for temporary-retarget session restoration semantics.
enum TemporaryRetargetSessionTests {
    @discardableResult
    static func run() -> Bool {
        var allPassed = true

        func assert(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() {
                print("TemporaryRetargetSessionTests: \(message)")
                allPassed = false
            }
        }

        let originalTarget = TargetedZoneManager.TargetedDestination.tiled(
            ZoneKey(screenId: 1, index: 1)
        )
        let temporaryTarget = TargetedZoneManager.TargetedDestination.tiled(
            ZoneKey(screenId: 1, index: 2)
        )
        let laterTarget = TargetedZoneManager.TargetedDestination.tiled(
            ZoneKey(screenId: 1, index: 3)
        )
        let session = TemporaryRetargetSession(
            originalTarget: originalTarget,
            temporaryTarget: temporaryTarget
        )
        let nilOriginSession = TemporaryRetargetSession(
            originalTarget: nil,
            temporaryTarget: temporaryTarget
        )
        let sameTargetSession = TemporaryRetargetSession(
            originalTarget: originalTarget,
            temporaryTarget: originalTarget
        )

        assert(
            session.shouldRestoreOriginalTarget(currentTarget: temporaryTarget),
            "restoration should proceed while the temporary target remains current"
        )
        assert(
            !session.shouldRestoreOriginalTarget(currentTarget: laterTarget),
            "restoration should refuse to overwrite a newer target"
        )
        assert(
            !session.shouldRestoreOriginalTarget(currentTarget: nil),
            "cleared current target should not restore a stale temporary session"
        )
        assert(
            nilOriginSession.shouldRestoreOriginalTarget(currentTarget: temporaryTarget),
            "restoration should still proceed when the original target was nil"
        )
        assert(
            sameTargetSession.shouldRestoreOriginalTarget(currentTarget: originalTarget),
            "restoration should still proceed when the shortcut-owned target is the original target"
        )

        if allPassed {
            print("TemporaryRetargetSessionTests: all tests passed")
        }
        return allPassed
    }
}
