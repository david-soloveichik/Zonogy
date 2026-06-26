import Foundation

/// Guardrail tests for Debug preference defaults and persistence.
enum DebugPreferencesStoreTests {
    @discardableResult
    static func run() -> Bool {
        var allPassed = true

        func assert(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() {
                print("DebugPreferencesStoreTests: \(message)")
                allPassed = false
            }
        }

        let defaults = UserDefaults.standard
        let key = UserDefaultsKeys.disableNativeTabHandling
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
            !DebugPreferencesStore.loadDisableNativeTabHandling(),
            "native tab handling should default to enabled when unset"
        )

        DebugPreferencesStore.saveDisableNativeTabHandling(true)
        assert(
            DebugPreferencesStore.loadDisableNativeTabHandling(),
            "saved native tab handling disable preference should round-trip true"
        )

        DebugPreferencesStore.saveDisableNativeTabHandling(false)
        assert(
            !DebugPreferencesStore.loadDisableNativeTabHandling(),
            "saved native tab handling disable preference should round-trip false"
        )

        if allPassed {
            print("DebugPreferencesStoreTests: all tests passed")
        }
        return allPassed
    }
}
