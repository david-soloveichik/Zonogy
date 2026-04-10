import CoreGraphics

/// Guardrail tests for mapping the active managed window to a targeted destination.
enum ActiveWindowTargetResolverTests {
    @discardableResult
    static func run() -> Bool {
        var allPassed = true

        func assert(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() {
                print("ActiveWindowTargetResolverTests: \(message)")
                allPassed = false
            }
        }

        let screen1: CGDirectDisplayID = 1
        let screen2: CGDirectDisplayID = 2
        let currentTarget = TargetedZoneManager.TargetedDestination.tiled(
            ZoneKey(screenId: screen1, index: 2)
        )

        do {
            let result = ActiveWindowTargetResolver.resolveTarget(
                currentTarget: currentTarget,
                activeWindow: .init(screenId: screen2, zoneIndex: 1, isInFloatingZone: false)
            )
            assert(
                result == .tiled(ZoneKey(screenId: screen2, index: 1)),
                "active tiled window should resolve to its zone"
            )
        }

        do {
            let result = ActiveWindowTargetResolver.resolveTarget(
                currentTarget: currentTarget,
                activeWindow: .init(screenId: screen2, zoneIndex: nil, isInFloatingZone: true)
            )
            assert(
                result == .floating(screenId: screen2),
                "active floating window should resolve to the floating zone"
            )
        }

        do {
            let result = ActiveWindowTargetResolver.resolveTarget(
                currentTarget: currentTarget,
                activeWindow: nil
            )
            assert(
                result == currentTarget,
                "missing active managed window should preserve the current target"
            )
        }

        if allPassed {
            print("ActiveWindowTargetResolverTests: all tests passed")
        }
        return allPassed
    }
}
