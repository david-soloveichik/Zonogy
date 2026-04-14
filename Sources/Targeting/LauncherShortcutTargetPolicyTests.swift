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

        let originalTarget = currentTarget
        let activeTarget = TargetedZoneManager.TargetedDestination.tiled(
            ZoneKey(screenId: screen2, index: 1)
        )

        do {
            let firstPressTarget = LauncherShortcutTargetPolicy.resolveInitialTarget(
                currentTarget: originalTarget,
                shortcutTargetsZoneWithActiveWindow: false,
                activeWindow: .init(screenId: screen2, zoneIndex: 1, isInFloatingZone: false)
            )
            let secondPressResolution = LauncherShortcutTargetPolicy.resolveRepeatedTarget(
                currentTarget: firstPressTarget,
                existingSession: nil,
                activeWindow: .init(screenId: screen2, zoneIndex: 1, isInFloatingZone: false)
            )
            let thirdPressResolution = LauncherShortcutTargetPolicy.resolveRepeatedTarget(
                currentTarget: secondPressResolution?.nextTarget,
                existingSession: secondPressResolution.map {
                    TemporaryRetargetSession(
                        originalTarget: $0.originalTarget,
                        temporaryTarget: $0.nextTarget
                    )
                },
                activeWindow: .init(screenId: screen2, zoneIndex: 1, isInFloatingZone: false)
            )
            assert(
                firstPressTarget == originalTarget
                    && secondPressResolution?.nextTarget == activeTarget
                    && thirdPressResolution?.nextTarget == originalTarget,
                "disabled Launcher shortcut retargeting should open on the current target, then toggle to the active window and back"
            )
        }

        do {
            let result = LauncherShortcutTargetPolicy.resolveRepeatedTarget(
                currentTarget: originalTarget,
                existingSession: nil,
                activeWindow: .init(screenId: screen2, zoneIndex: 1, isInFloatingZone: false)
            )
            assert(
                result?.originalTarget == originalTarget && result?.nextTarget == activeTarget,
                "first repeated shortcut press should jump from the original target to the active window target"
            )
        }

        do {
            let result = LauncherShortcutTargetPolicy.resolveRepeatedTarget(
                currentTarget: activeTarget,
                existingSession: TemporaryRetargetSession(
                    originalTarget: originalTarget,
                    temporaryTarget: activeTarget
                ),
                activeWindow: .init(screenId: screen2, zoneIndex: 1, isInFloatingZone: false)
            )
            assert(
                result?.originalTarget == originalTarget && result?.nextTarget == originalTarget,
                "repeated shortcut press from the active window side should toggle back to the original target"
            )
        }

        do {
            let refreshedActiveTarget = TargetedZoneManager.TargetedDestination.floating(screenId: screen2)
            let result = LauncherShortcutTargetPolicy.resolveRepeatedTarget(
                currentTarget: originalTarget,
                existingSession: TemporaryRetargetSession(
                    originalTarget: originalTarget,
                    temporaryTarget: originalTarget
                ),
                activeWindow: .init(screenId: screen2, zoneIndex: nil, isInFloatingZone: true)
            )
            assert(
                result?.originalTarget == originalTarget && result?.nextTarget == refreshedActiveTarget,
                "returning to the original target should let the next press use the latest active window destination"
            )
        }

        do {
            let result = LauncherShortcutTargetPolicy.resolveRepeatedTarget(
                currentTarget: originalTarget,
                existingSession: nil,
                activeWindow: nil
            )
            assert(
                result == nil,
                "missing active managed window should make repeated shortcut presses a no-op"
            )
        }

        do {
            let result = LauncherShortcutTargetPolicy.resolveRepeatedTarget(
                currentTarget: originalTarget,
                existingSession: nil,
                activeWindow: .init(screenId: screen1, zoneIndex: 2, isInFloatingZone: false)
            )
            assert(
                result == nil,
                "repeated shortcut presses should no-op when the active window target already matches the current target"
            )
        }

        if allPassed {
            print("LauncherShortcutTargetPolicyTests: all tests passed")
        }
        return allPassed
    }
}
