import CoreGraphics

/// Guardrail tests for feature-specific active-window targeting resolution.
enum ActiveWindowTriggeredTargetPolicyTests {
    @discardableResult
    static func run() -> Bool {
        var allPassed = true

        func assert(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() {
                print("ActiveWindowTriggeredTargetPolicyTests: \(message)")
                allPassed = false
            }
        }

        let screen1: CGDirectDisplayID = 1
        let screen2: CGDirectDisplayID = 2
        let currentTarget = TargetedZoneManager.TargetedDestination.tiled(
            ZoneKey(screenId: screen1, index: 2)
        )

        do {
            let result = ActiveWindowTriggeredTargetPolicy.resolveTarget(
                currentTarget: currentTarget,
                launcherOccupiesCurrentTarget: true,
                activeWindow: .init(screenId: screen2, zoneIndex: 1, isInFloatingZone: false)
            )
            assert(
                result == currentTarget,
                "Launcher is always shown on the current target, so that target should remain unchanged"
            )
        }

        do {
            let result = ActiveWindowTriggeredTargetPolicy.resolveTarget(
                currentTarget: currentTarget,
                launcherOccupiesCurrentTarget: false,
                activeWindow: .init(screenId: screen2, zoneIndex: 1, isInFloatingZone: false)
            )
            assert(
                result == .tiled(ZoneKey(screenId: screen2, index: 1)),
                "active tiled window should retarget to its zone"
            )
        }

        do {
            let result = ActiveWindowTriggeredTargetPolicy.resolveTarget(
                currentTarget: currentTarget,
                launcherOccupiesCurrentTarget: false,
                activeWindow: .init(screenId: screen2, zoneIndex: nil, isInFloatingZone: true)
            )
            assert(
                result == .floating(screenId: screen2),
                "active floating window should retarget to the floating zone"
            )
        }

        do {
            let result = ActiveWindowTriggeredTargetPolicy.resolveTarget(
                currentTarget: currentTarget,
                launcherOccupiesCurrentTarget: false,
                activeWindow: nil
            )
            assert(result == currentTarget, "missing active managed window should preserve the current target")
        }

        if allPassed {
            print("ActiveWindowTriggeredTargetPolicyTests: all tests passed")
        }
        return allPassed
    }
}
