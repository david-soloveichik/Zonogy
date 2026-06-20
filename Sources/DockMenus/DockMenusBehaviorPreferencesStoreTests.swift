import Foundation

/// Guardrail tests for DockMenus targeting preference defaults and persistence.
enum DockMenusBehaviorPreferencesStoreTests {
    @discardableResult
    static func run() -> Bool {
        var allPassed = true

        func assert(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() {
                print("DockMenusBehaviorPreferencesStoreTests: \(message)")
                allPassed = false
            }
        }

        let defaults = UserDefaults.standard
        let key = UserDefaultsKeys.dockMenusTargetsZoneWithActiveWindow
        let previousValue = defaults.object(forKey: key)
        defer {
            if let previousValue {
                defaults.set(previousValue, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        defaults.removeObject(forKey: key)
        assert(
            !DockMenusBehaviorPreferencesStore.loadTargetsZoneWithActiveWindow(),
            "DockMenus targeting should default to disabled when unset"
        )

        DockMenusBehaviorPreferencesStore.saveTargetsZoneWithActiveWindow(true)
        assert(
            DockMenusBehaviorPreferencesStore.loadTargetsZoneWithActiveWindow(),
            "saved DockMenus targeting preference should round-trip true"
        )

        DockMenusBehaviorPreferencesStore.saveTargetsZoneWithActiveWindow(false)
        assert(
            !DockMenusBehaviorPreferencesStore.loadTargetsZoneWithActiveWindow(),
            "saved DockMenus targeting preference should round-trip false"
        )

        if allPassed {
            print("DockMenusBehaviorPreferencesStoreTests: all tests passed")
        }
        return allPassed
    }
}
