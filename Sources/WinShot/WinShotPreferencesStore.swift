/// Persists user-facing WinShot enablement preferences using UserDefaults.

import Foundation

/// How automatic WinShot snapshots are captured. Each mode is a superset of the previous one.
enum WinShotAutoSaveMode: Int, CaseIterable {
    /// Never auto-save; snapshots are created only via the manual Control-Command-/ shortcut.
    case off = 0
    /// Capture the current arrangement right before Clear/Reset Zones (and before a chooser switch).
    case onClearReset = 1
    /// Everything `onClearReset` does, plus auto-save any arrangement that persists for the
    /// settle delay (see `SecondsPreference.settleDelay`).
    case onEveryChange = 2
}

enum WinShotPreferencesStore {
    static let minSnapshotsStored = 1
    static let maxSnapshotsStored = 20
    static let defaultSnapshotsStored = 10

    /// Auto-save is opt-in; it defaults to off.
    static let defaultAutoSaveMode: WinShotAutoSaveMode = .off

    static func loadEnabled() -> Bool {
        UserDefaults.standard.bool(forKey: UserDefaultsKeys.winShotEnabled)
    }

    static func saveEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: UserDefaultsKeys.winShotEnabled)
    }

    /// Returns the automatic snapshot mode, falling back to the default when unset or invalid.
    static func loadAutoSaveMode() -> WinShotAutoSaveMode {
        guard UserDefaults.standard.object(forKey: UserDefaultsKeys.winShotAutoSaveMode) != nil else {
            return defaultAutoSaveMode
        }
        let raw = UserDefaults.standard.integer(forKey: UserDefaultsKeys.winShotAutoSaveMode)
        return WinShotAutoSaveMode(rawValue: raw) ?? defaultAutoSaveMode
    }

    static func saveAutoSaveMode(_ mode: WinShotAutoSaveMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: UserDefaultsKeys.winShotAutoSaveMode)
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
