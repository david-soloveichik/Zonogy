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

        // No focused managed window, targeted zone occupied -> advance off the target.
        assert(
            FocusedWindowToggleTargetPolicy.resolve(focusedWindowDestination: nil, currentTarget: zone1, currentTargetIsOccupied: true) == .advance(from: zone1),
            "nil focused window with occupied tiled target should resolve to .advance"
        )
        assert(
            FocusedWindowToggleTargetPolicy.resolve(focusedWindowDestination: nil, currentTarget: floating1, currentTargetIsOccupied: true) == .advance(from: floating1),
            "nil focused window with occupied floating target should resolve to .advance"
        )

        // No focused managed window, targeted zone empty -> no-op.
        assert(
            FocusedWindowToggleTargetPolicy.resolve(focusedWindowDestination: nil, currentTarget: zone1, currentTargetIsOccupied: false) == .none,
            "nil focused window with empty tiled target should resolve to .none"
        )
        assert(
            FocusedWindowToggleTargetPolicy.resolve(focusedWindowDestination: nil, currentTarget: nil, currentTargetIsOccupied: false) == .none,
            "nil focused window with nil target should resolve to .none"
        )

        // A filled tiling target always advances off itself, regardless of focus.
        assert(
            FocusedWindowToggleTargetPolicy.resolve(focusedWindowDestination: zone2, currentTarget: zone1, currentTargetIsOccupied: true) == .advance(from: zone1),
            "occupied tiled target with a different focused tiled zone should resolve to .advance"
        )
        assert(
            FocusedWindowToggleTargetPolicy.resolve(focusedWindowDestination: floating1, currentTarget: zone1, currentTargetIsOccupied: true) == .advance(from: zone1),
            "occupied tiled target with a focused floating zone should resolve to .advance"
        )
        assert(
            FocusedWindowToggleTargetPolicy.resolve(focusedWindowDestination: zone2, currentTarget: zone2, currentTargetIsOccupied: true) == .advance(from: zone2),
            "focused tiled zone equal to (occupied) target should resolve to .advance"
        )

        // Focus-follow applies only when the target is not a filled tiling zone: an empty tiling target,
        // a floating target, or no target each let the focused window's zone become the target.
        assert(
            FocusedWindowToggleTargetPolicy.resolve(focusedWindowDestination: zone1, currentTarget: nil, currentTargetIsOccupied: false) == .target(zone1),
            "focused tiled zone with no current target should resolve to .target"
        )
        assert(
            FocusedWindowToggleTargetPolicy.resolve(focusedWindowDestination: floating1, currentTarget: zone1, currentTargetIsOccupied: false) == .target(floating1),
            "focused floating zone with an empty tiled target should resolve to .target"
        )
        // The advance-regardless rule is tiling-only: an occupied floating target still follows focus.
        assert(
            FocusedWindowToggleTargetPolicy.resolve(focusedWindowDestination: zone1, currentTarget: floating1, currentTargetIsOccupied: true) == .target(zone1),
            "focused tiled zone with an occupied floating target should resolve to .target"
        )
        // Same screen but different zone index is not "already targeted" (empty target so no advance).
        assert(
            FocusedWindowToggleTargetPolicy.resolve(focusedWindowDestination: zone1, currentTarget: zone2, currentTargetIsOccupied: false) == .target(zone1),
            "different zone index on same screen (empty target) should resolve to .target"
        )

        // Focused window's zone already targeted (so occupied) -> advance off it (floating case).
        assert(
            FocusedWindowToggleTargetPolicy.resolve(focusedWindowDestination: floating1, currentTarget: floating1, currentTargetIsOccupied: true) == .advance(from: floating1),
            "focused floating zone equal to target should resolve to .advance"
        )
        // Floating zones on different screens are distinct destinations.
        assert(
            FocusedWindowToggleTargetPolicy.resolve(focusedWindowDestination: floating1, currentTarget: floating2, currentTargetIsOccupied: true) == .target(floating1),
            "floating zones on different screens should resolve to .target"
        )

        if allPassed {
            print("FocusedWindowToggleTargetPolicyTests: all tests passed")
        }
        return allPassed
    }
}
