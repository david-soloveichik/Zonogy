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

        let defaults = UserDefaults.standard
        let autoSaveKey = UserDefaultsKeys.winShotAutoSaveSnapshots
        let legacyAutoSaveKey = "Zonogy.winShot.autoSaveOnZoneOccupancyChange"
        let previousAutoSaveValue = defaults.object(forKey: autoSaveKey)
        let previousLegacyAutoSaveValue = defaults.object(forKey: legacyAutoSaveKey)
        defer {
            if let previousAutoSaveValue {
                defaults.set(previousAutoSaveValue, forKey: autoSaveKey)
            } else {
                defaults.removeObject(forKey: autoSaveKey)
            }
            if let previousLegacyAutoSaveValue {
                defaults.set(previousLegacyAutoSaveValue, forKey: legacyAutoSaveKey)
            } else {
                defaults.removeObject(forKey: legacyAutoSaveKey)
            }
        }

        defaults.removeObject(forKey: autoSaveKey)
        defaults.removeObject(forKey: legacyAutoSaveKey)
        assert(
            WinShotPreferencesStore.loadAutoSaveSnapshots(),
            "auto-save snapshots should default to enabled when unset"
        )

        WinShotPreferencesStore.saveAutoSaveSnapshots(false)
        assert(
            !WinShotPreferencesStore.loadAutoSaveSnapshots(),
            "saved auto-save snapshots setting should be read back"
        )

        defaults.removeObject(forKey: autoSaveKey)
        defaults.set(false, forKey: legacyAutoSaveKey)
        assert(
            WinShotPreferencesStore.loadAutoSaveSnapshots(),
            "legacy auto-save keys should be ignored"
        )

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
