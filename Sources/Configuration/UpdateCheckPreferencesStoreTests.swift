import Foundation

/// Guardrail tests for update check preference defaults and persistence.
enum UpdateCheckPreferencesStoreTests {
    @discardableResult
    static func run() -> Bool {
        var allPassed = true

        func assert(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() {
                print("UpdateCheckPreferencesStoreTests: \(message)")
                allPassed = false
            }
        }

        let defaults = UserDefaults.standard
        let automaticKey = UserDefaultsKeys.updateAutomaticCheckEnabled
        let skippedKey = UserDefaultsKeys.updateSkippedVersion
        let previousAutomatic = defaults.object(forKey: automaticKey)
        let previousSkipped = defaults.object(forKey: skippedKey)
        defer {
            if let previousAutomatic {
                defaults.set(previousAutomatic, forKey: automaticKey)
            } else {
                defaults.removeObject(forKey: automaticKey)
            }
            if let previousSkipped {
                defaults.set(previousSkipped, forKey: skippedKey)
            } else {
                defaults.removeObject(forKey: skippedKey)
            }
        }

        defaults.removeObject(forKey: automaticKey)
        assert(
            UpdateCheckPreferencesStore.loadAutomaticCheckEnabled(),
            "automatic checking should default to enabled when unset"
        )

        UpdateCheckPreferencesStore.saveAutomaticCheckEnabled(false)
        assert(
            !UpdateCheckPreferencesStore.loadAutomaticCheckEnabled(),
            "saved automatic-check preference should round-trip"
        )

        defaults.removeObject(forKey: skippedKey)
        assert(
            UpdateCheckPreferencesStore.loadSkippedVersion() == nil,
            "skipped version should default to nil when unset"
        )

        UpdateCheckPreferencesStore.saveSkippedVersion("1.2")
        assert(
            UpdateCheckPreferencesStore.loadSkippedVersion() == "1.2",
            "saved skipped version should round-trip"
        )

        UpdateCheckPreferencesStore.saveSkippedVersion(nil)
        assert(
            UpdateCheckPreferencesStore.loadSkippedVersion() == nil,
            "clearing the skipped version should remove it"
        )

        if allPassed {
            print("UpdateCheckPreferencesStoreTests: all tests passed")
        }
        return allPassed
    }
}
