import Foundation

/// Guardrail tests for Launcher preference defaults and persistence.
enum LauncherBehaviorPreferencesStoreTests {
    @discardableResult
    static func run() -> Bool {
        var allPassed = true

        func assert(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() {
                print("LauncherBehaviorPreferencesStoreTests: \(message)")
                allPassed = false
            }
        }

        let defaults = UserDefaults.standard
        let autoShowKey = UserDefaultsKeys.launcherAutoShowForEmptyZones
        let shortcutTargetingKey = UserDefaultsKeys.launcherShortcutTargetsZoneWithActiveWindow
        let previousAutoShowValue = defaults.object(forKey: autoShowKey)
        let previousShortcutTargetingValue = defaults.object(forKey: shortcutTargetingKey)
        defer {
            if let previousAutoShowValue {
                defaults.set(previousAutoShowValue, forKey: autoShowKey)
            } else {
                defaults.removeObject(forKey: autoShowKey)
            }

            if let previousShortcutTargetingValue {
                defaults.set(previousShortcutTargetingValue, forKey: shortcutTargetingKey)
            } else {
                defaults.removeObject(forKey: shortcutTargetingKey)
            }
        }

        defaults.removeObject(forKey: autoShowKey)
        assert(
            LauncherBehaviorPreferencesStore.loadAutoShowForEmptyZones(),
            "Launcher auto-show should default to enabled when unset"
        )

        LauncherBehaviorPreferencesStore.saveAutoShowForEmptyZones(false)
        assert(
            !LauncherBehaviorPreferencesStore.loadAutoShowForEmptyZones(),
            "saved Launcher auto-show preference should round-trip"
        )

        defaults.removeObject(forKey: shortcutTargetingKey)
        assert(
            LauncherBehaviorPreferencesStore.loadShortcutTargetsZoneWithActiveWindow(),
            "Launcher shortcut targeting should default to enabled when unset"
        )

        LauncherBehaviorPreferencesStore.saveShortcutTargetsZoneWithActiveWindow(true)
        assert(
            LauncherBehaviorPreferencesStore.loadShortcutTargetsZoneWithActiveWindow(),
            "saved Launcher shortcut targeting preference should round-trip"
        )

        LauncherBehaviorPreferencesStore.saveShortcutTargetsZoneWithActiveWindow(false)
        assert(
            !LauncherBehaviorPreferencesStore.loadShortcutTargetsZoneWithActiveWindow(),
            "saved false Launcher shortcut targeting preference should round-trip"
        )

        if allPassed {
            print("LauncherBehaviorPreferencesStoreTests: all tests passed")
        }
        return allPassed
    }
}
