/// Persists user-facing WinShot enablement preferences using UserDefaults.

import Foundation

enum WinShotPreferencesStore {
    static func loadEnabled() -> Bool {
        UserDefaults.standard.bool(forKey: UserDefaultsKeys.winShotEnabled)
    }

    static func saveEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: UserDefaultsKeys.winShotEnabled)
    }

    /// Returns whether auto-save on occupancy changes is enabled.
    /// Defaults to true when no preference has been stored.
    static func loadAutoSaveOnZoneOccupancyChange() -> Bool {
        if UserDefaults.standard.object(forKey: UserDefaultsKeys.winShotAutoSaveOnZoneOccupancyChange) != nil {
            return UserDefaults.standard.bool(forKey: UserDefaultsKeys.winShotAutoSaveOnZoneOccupancyChange)
        }

        if UserDefaults.standard.object(forKey: UserDefaultsKeys.winShotAutoSaveOnClearZonesLegacy) != nil {
            return UserDefaults.standard.bool(forKey: UserDefaultsKeys.winShotAutoSaveOnClearZonesLegacy)
        }

        return true
    }

    static func saveAutoSaveOnZoneOccupancyChange(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: UserDefaultsKeys.winShotAutoSaveOnZoneOccupancyChange)
    }
}
