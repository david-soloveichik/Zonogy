/// Persists the software update check preferences (automatic checking and the skipped version).

import Foundation

enum UpdateCheckPreferencesStore {
    private static let defaultAutomaticCheckEnabled = true

    static func loadAutomaticCheckEnabled() -> Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: UserDefaultsKeys.updateAutomaticCheckEnabled) == nil {
            return defaultAutomaticCheckEnabled
        }
        return defaults.bool(forKey: UserDefaultsKeys.updateAutomaticCheckEnabled)
    }

    static func saveAutomaticCheckEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: UserDefaultsKeys.updateAutomaticCheckEnabled)
    }

    /// The version the user chose to sit out via "Skip This Version" (nil when none).
    static func loadSkippedVersion() -> String? {
        UserDefaults.standard.string(forKey: UserDefaultsKeys.updateSkippedVersion)
    }

    static func saveSkippedVersion(_ version: String?) {
        let defaults = UserDefaults.standard
        if let version {
            defaults.set(version, forKey: UserDefaultsKeys.updateSkippedVersion)
        } else {
            defaults.removeObject(forKey: UserDefaultsKeys.updateSkippedVersion)
        }
    }
}
