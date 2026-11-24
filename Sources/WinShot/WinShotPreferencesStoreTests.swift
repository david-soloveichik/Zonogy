import Foundation

/// Guardrail tests for WinShot preferences (auto-save mode, snapshot-limit clamping).
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
        let modeKey = UserDefaultsKeys.winShotAutoSaveMode
        let previousMode = defaults.object(forKey: modeKey)
        defer {
            if let previousMode {
                defaults.set(previousMode, forKey: modeKey)
            } else {
                defaults.removeObject(forKey: modeKey)
            }
        }

        // MARK: Auto-save mode
        defaults.removeObject(forKey: modeKey)
        assert(
            WinShotPreferencesStore.loadAutoSaveMode() == .off,
            "auto-save mode should default to off when unset"
        )

        WinShotPreferencesStore.saveAutoSaveMode(.onEveryChange)
        assert(
            WinShotPreferencesStore.loadAutoSaveMode() == .onEveryChange,
            "saved auto-save mode should be read back"
        )

        WinShotPreferencesStore.saveAutoSaveMode(.off)
        assert(
            WinShotPreferencesStore.loadAutoSaveMode() == .off,
            "off mode should be read back"
        )

        defaults.set(999, forKey: modeKey)
        assert(
            WinShotPreferencesStore.loadAutoSaveMode() == .off,
            "unrecognized raw mode should fall back to the default"
        )

        // MARK: Max snapshots clamping
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
