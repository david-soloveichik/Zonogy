import Foundation

/// Guardrail tests for CmdTab targeting preference defaults and persistence.
enum CmdTabBehaviorPreferencesStoreTests {
    @discardableResult
    static func run() -> Bool {
        var allPassed = true

        func assert(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() {
                print("CmdTabBehaviorPreferencesStoreTests: \(message)")
                allPassed = false
            }
        }

        let defaults = UserDefaults.standard
        let key = UserDefaultsKeys.cmdTabTargetsZoneWithActiveWindow
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
            !CmdTabBehaviorPreferencesStore.loadTargetsZoneWithActiveWindow(),
            "CmdTab targeting should default to disabled when unset"
        )

        CmdTabBehaviorPreferencesStore.saveTargetsZoneWithActiveWindow(false)
        assert(
            !CmdTabBehaviorPreferencesStore.loadTargetsZoneWithActiveWindow(),
            "saved CmdTab targeting preference should round-trip false"
        )

        CmdTabBehaviorPreferencesStore.saveTargetsZoneWithActiveWindow(true)
        assert(
            CmdTabBehaviorPreferencesStore.loadTargetsZoneWithActiveWindow(),
            "saved CmdTab targeting preference should round-trip true"
        )

        if allPassed {
            print("CmdTabBehaviorPreferencesStoreTests: all tests passed")
        }
        return allPassed
    }
}
