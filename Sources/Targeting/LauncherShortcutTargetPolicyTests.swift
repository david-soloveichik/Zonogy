import CoreGraphics

/// Guardrail tests for Launcher shortcut active-window targeting policy.
enum LauncherShortcutTargetPolicyTests {
    @discardableResult
    static func run() -> Bool {
        var allPassed = true

        func assert(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() {
                print("LauncherShortcutTargetPolicyTests: \(message)")
                allPassed = false
            }
        }

        let screen1: CGDirectDisplayID = 1
        let screen2: CGDirectDisplayID = 2
        let currentTarget = TargetedZoneManager.TargetedDestination.tiled(
            ZoneKey(screenId: screen1, index: 2)
        )

        do {
            let result = LauncherShortcutTargetPolicy.resolveInitialTarget(
                currentTarget: currentTarget,
                shortcutTargetsZoneWithActiveWindow: false,
                activeWindow: .init(screenId: screen2, zoneIndex: 1, isInFloatingZone: false)
            )
            assert(
                result == currentTarget,
                "disabled Launcher shortcut retargeting should preserve the current target"
            )
        }

        do {
            let result = LauncherShortcutTargetPolicy.resolveInitialTarget(
                currentTarget: currentTarget,
                shortcutTargetsZoneWithActiveWindow: true,
                activeWindow: .init(screenId: screen2, zoneIndex: 1, isInFloatingZone: false)
            )
            assert(
                result == .tiled(ZoneKey(screenId: screen2, index: 1)),
                "enabled Launcher shortcut retargeting should use the active tiled window"
            )
        }

        do {
            let result = LauncherShortcutTargetPolicy.resolveInitialTarget(
                currentTarget: currentTarget,
                shortcutTargetsZoneWithActiveWindow: true,
                activeWindow: .init(screenId: screen2, zoneIndex: nil, isInFloatingZone: true)
            )
            assert(
                result == .floating(screenId: screen2),
                "enabled Launcher shortcut retargeting should use the active floating window"
            )
        }

        do {
            let result = LauncherShortcutTargetPolicy.resolveInitialTarget(
                currentTarget: currentTarget,
                shortcutTargetsZoneWithActiveWindow: true,
                activeWindow: nil
            )
            assert(
                result == currentTarget,
                "missing active managed window should preserve the current target"
            )
        }

        if allPassed {
            print("LauncherShortcutTargetPolicyTests: all tests passed")
        }
        return allPassed
    }
}
