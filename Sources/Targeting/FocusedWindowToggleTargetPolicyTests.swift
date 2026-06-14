import CoreGraphics

/// Guardrail tests for the "Toggle Target Zone w/ Focused Window" decision logic.
enum FocusedWindowToggleTargetPolicyTests {
    @discardableResult
    static func run() -> Bool {
        var allPassed = true

        func assert(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() {
                print("FocusedWindowToggleTargetPolicyTests: \(message)")
                allPassed = false
            }
        }

        let screen1: CGDirectDisplayID = 1
        let screen2: CGDirectDisplayID = 2
        let zone1 = TargetedZoneManager.TargetedDestination.tiled(ZoneKey(screenId: screen1, index: 1))
        let zone2 = TargetedZoneManager.TargetedDestination.tiled(ZoneKey(screenId: screen1, index: 2))
        let floating1 = TargetedZoneManager.TargetedDestination.floating(screenId: screen1)
        let floating2 = TargetedZoneManager.TargetedDestination.floating(screenId: screen2)

        // No focused managed window -> no-op (regardless of current target).
        assert(
            FocusedWindowToggleTargetPolicy.resolve(focusedWindowDestination: nil, currentTarget: zone1) == .none,
            "nil focused window should resolve to .none"
        )
        assert(
            FocusedWindowToggleTargetPolicy.resolve(focusedWindowDestination: nil, currentTarget: nil) == .none,
            "nil focused window with nil target should resolve to .none"
        )

        // Focused window's zone not currently targeted -> target it.
        assert(
            FocusedWindowToggleTargetPolicy.resolve(focusedWindowDestination: zone2, currentTarget: zone1) == .target(zone2),
            "focused tiled zone different from target should resolve to .target"
        )
        assert(
            FocusedWindowToggleTargetPolicy.resolve(focusedWindowDestination: zone1, currentTarget: nil) == .target(zone1),
            "focused tiled zone with no current target should resolve to .target"
        )
        assert(
            FocusedWindowToggleTargetPolicy.resolve(focusedWindowDestination: floating1, currentTarget: zone1) == .target(floating1),
            "focused floating zone different from target should resolve to .target"
        )

        // Focused window's zone already targeted -> advance off it.
        assert(
            FocusedWindowToggleTargetPolicy.resolve(focusedWindowDestination: zone2, currentTarget: zone2) == .advance(from: zone2),
            "focused tiled zone equal to target should resolve to .advance"
        )
        assert(
            FocusedWindowToggleTargetPolicy.resolve(focusedWindowDestination: floating1, currentTarget: floating1) == .advance(from: floating1),
            "focused floating zone equal to target should resolve to .advance"
        )

        // Same screen but different zone index is not "already targeted".
        assert(
            FocusedWindowToggleTargetPolicy.resolve(focusedWindowDestination: zone1, currentTarget: zone2) == .target(zone1),
            "different zone index on same screen should resolve to .target"
        )
        // Floating zones on different screens are distinct destinations.
        assert(
            FocusedWindowToggleTargetPolicy.resolve(focusedWindowDestination: floating1, currentTarget: floating2) == .target(floating1),
            "floating zones on different screens should resolve to .target"
        )

        if allPassed {
            print("FocusedWindowToggleTargetPolicyTests: all tests passed")
        }
        return allPassed
    }
}
