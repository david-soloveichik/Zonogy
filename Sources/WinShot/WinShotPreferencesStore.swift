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

    /// Returns whether automatic snapshot creation is enabled.
    /// Defaults to true when no preference has been stored.
    static func loadAutoSaveSnapshots() -> Bool {
        if UserDefaults.standard.object(forKey: UserDefaultsKeys.winShotAutoSaveSnapshots) != nil {
            return UserDefaults.standard.bool(forKey: UserDefaultsKeys.winShotAutoSaveSnapshots)
        }
        return true
    }

    static func saveAutoSaveSnapshots(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: UserDefaultsKeys.winShotAutoSaveSnapshots)
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
