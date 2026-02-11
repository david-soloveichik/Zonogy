/// Persists user-facing WinShot enablement preferences using UserDefaults.

import Foundation

enum WinShotPreferencesStore {
    static let minSnapshotsStored = 1
    static let maxSnapshotsStored = 20
    static let defaultSnapshotsStored = 10

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

    static func loadMaxSnapshotsStored() -> Int {
        guard UserDefaults.standard.object(forKey: UserDefaultsKeys.winShotMaxSnapshotsStored) != nil else {
            return defaultSnapshotsStored
        }

        let stored = UserDefaults.standard.integer(forKey: UserDefaultsKeys.winShotMaxSnapshotsStored)
        return normalizedMaxSnapshotsStored(stored)
    }

    static func saveMaxSnapshotsStored(_ maxSnapshotsStored: Int) {
        UserDefaults.standard.set(
            normalizedMaxSnapshotsStored(maxSnapshotsStored),
            forKey: UserDefaultsKeys.winShotMaxSnapshotsStored
        )
    }

    static func normalizedMaxSnapshotsStored(_ value: Int) -> Int {
        min(max(value, minSnapshotsStored), maxSnapshotsStored)
    }
}
