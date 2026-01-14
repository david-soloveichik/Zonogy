/// Persists user-facing WinShot enablement preferences using UserDefaults.

import Foundation

enum WinShotPreferencesStore {
    static func loadEnabled() -> Bool {
        UserDefaults.standard.bool(forKey: UserDefaultsKeys.winShotEnabled)
    }

    static func saveEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: UserDefaultsKeys.winShotEnabled)
    }

    /// Returns whether auto-save on Clear Zones is enabled.
    /// Defaults to true when key is not set (so enabling WinShot automatically enables auto-save).
    static func loadAutoSaveOnClearZones() -> Bool {
        if UserDefaults.standard.object(forKey: UserDefaultsKeys.winShotAutoSaveOnClearZones) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: UserDefaultsKeys.winShotAutoSaveOnClearZones)
    }

    static func saveAutoSaveOnClearZones(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: UserDefaultsKeys.winShotAutoSaveOnClearZones)
    }
}
