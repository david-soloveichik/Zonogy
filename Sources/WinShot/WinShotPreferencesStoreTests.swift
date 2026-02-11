import Foundation

/// Guardrail tests for WinShot preferences normalization logic.
enum WinShotPreferencesStoreTests {
    @discardableResult
    static func run() -> Bool {
        var allPassed = true

        func assert(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() {
                print("WinShotPreferencesStoreTests: \(message)")
                allPassed = false
            }
        }

        assert(
            WinShotPreferencesStore.normalizedMaxSnapshotsStored(
                WinShotPreferencesStore.minSnapshotsStored - 5
            ) == WinShotPreferencesStore.minSnapshotsStored,
            "values below minimum should clamp to min"
        )

        assert(
            WinShotPreferencesStore.normalizedMaxSnapshotsStored(
                WinShotPreferencesStore.maxSnapshotsStored + 5
            ) == WinShotPreferencesStore.maxSnapshotsStored,
            "values above maximum should clamp to max"
        )

        assert(
            WinShotPreferencesStore.normalizedMaxSnapshotsStored(7) == 7,
            "values in range should be preserved"
        )

        if allPassed {
            print("WinShotPreferencesStoreTests: all tests passed")
        }
        return allPassed
    }
}
