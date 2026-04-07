import Foundation

/// Guardrail tests for Sticky Resize preference defaults and persistence.
enum StickyResizePreferencesStoreTests {
    @discardableResult
    static func run() -> Bool {
        var allPassed = true

        func assert(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() {
                print("StickyResizePreferencesStoreTests: \(message)")
                allPassed = false
            }
        }

        let defaults = UserDefaults.standard
        let key = UserDefaultsKeys.stickyResizeEnabled
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
            !StickyResizePreferencesStore.loadEnabled(),
            "Sticky Resize should default to disabled when unset"
        )

        StickyResizePreferencesStore.saveEnabled(true)
        assert(
            StickyResizePreferencesStore.loadEnabled(),
            "saved Sticky Resize preference should round-trip"
        )

        StickyResizePreferencesStore.saveEnabled(false)
        assert(
            !StickyResizePreferencesStore.loadEnabled(),
            "saved false Sticky Resize preference should round-trip"
        )

        if allPassed {
            print("StickyResizePreferencesStoreTests: all tests passed")
        }
        return allPassed
    }
}
