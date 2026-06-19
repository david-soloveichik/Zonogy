import Foundation

/// Guardrail tests for WinShot preferences (auto-save mode, settle delay, snapshot-limit clamping).
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
        let delayKey = UserDefaultsKeys.winShotOccupancySettleDelaySeconds
        let previousMode = defaults.object(forKey: modeKey)
        let previousDelay = defaults.object(forKey: delayKey)
        defer {
            if let previousMode {
                defaults.set(previousMode, forKey: modeKey)
            } else {
                defaults.removeObject(forKey: modeKey)
            }
            if let previousDelay {
                defaults.set(previousDelay, forKey: delayKey)
            } else {
                defaults.removeObject(forKey: delayKey)
            }
        }

        // MARK: Auto-save mode
        defaults.removeObject(forKey: modeKey)
        assert(
            WinShotPreferencesStore.loadAutoSaveMode() == .off,
            "auto-save mode should default to off when unset"
        )

        WinShotPreferencesStore.saveAutoSaveMode(.onEveryOccupancyChange)
        assert(
            WinShotPreferencesStore.loadAutoSaveMode() == .onEveryOccupancyChange,
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

        // MARK: Settle delay
        defaults.removeObject(forKey: delayKey)
        assert(
            WinShotPreferencesStore.loadOccupancySettleDelaySeconds()
                == WinShotPreferencesStore.defaultOccupancySettleDelaySeconds,
            "settle delay should default when unset"
        )

        assert(
            WinShotPreferencesStore.normalizedOccupancySettleDelaySeconds(0)
                == WinShotPreferencesStore.minOccupancySettleDelaySeconds,
            "settle delay below minimum should clamp to min"
        )
        assert(
            WinShotPreferencesStore.normalizedOccupancySettleDelaySeconds(9999)
                == WinShotPreferencesStore.maxOccupancySettleDelaySeconds,
            "settle delay above maximum should clamp to max"
        )
        assert(
            WinShotPreferencesStore.normalizedOccupancySettleDelaySeconds(7) == 7,
            "in-range settle delay should be preserved"
        )

        WinShotPreferencesStore.saveOccupancySettleDelaySeconds(9999)
        assert(
            WinShotPreferencesStore.loadOccupancySettleDelaySeconds()
                == WinShotPreferencesStore.maxOccupancySettleDelaySeconds,
            "saved settle delay should be normalized on read-back"
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
