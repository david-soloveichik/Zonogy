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

        let boolPreferences: [(name: String, key: String, load: () -> Bool, save: (Bool) -> Void)] = [
            (
                "disable native tab handling",
                UserDefaultsKeys.disableNativeTabHandling,
                DebugPreferencesStore.loadDisableNativeTabHandling,
                DebugPreferencesStore.saveDisableNativeTabHandling
            ),
            (
                "show placeholder pass-through holes",
                UserDefaultsKeys.showPlaceholderPassThroughHoles,
                DebugPreferencesStore.loadShowPlaceholderPassThroughHoles,
                DebugPreferencesStore.saveShowPlaceholderPassThroughHoles
            )
        ]

        let defaults = UserDefaults.standard
        for preference in boolPreferences {
            let previousValue = defaults.object(forKey: preference.key)
            defer {
                if let previousValue {
                    defaults.set(previousValue, forKey: preference.key)
                } else {
                    defaults.removeObject(forKey: preference.key)
                }
            }

            defaults.removeObject(forKey: preference.key)
            assert(
                !preference.load(),
                "\(preference.name) should default to off when unset"
            )

            preference.save(true)
            assert(
                preference.load(),
                "saved \(preference.name) preference should round-trip true"
            )

            preference.save(false)
            assert(
                !preference.load(),
                "saved \(preference.name) preference should round-trip false"
            )
        }

        if allPassed {
            print("DebugPreferencesStoreTests: all tests passed")
        }
        return allPassed
    }
}
