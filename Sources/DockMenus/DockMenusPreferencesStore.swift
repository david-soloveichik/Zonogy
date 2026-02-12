/// Persists user-facing DockMenus enablement preferences using UserDefaults.

import Foundation

enum DockMenusPreferencesStore {
    private static let defaultEnabled = true

    static func loadEnabled() -> Bool {
        let defaults = UserDefaults.standard
        // If the key hasn't been set, return the default value
        if defaults.object(forKey: UserDefaultsKeys.dockMenusEnabled) == nil {
            return defaultEnabled
        }
        return defaults.bool(forKey: UserDefaultsKeys.dockMenusEnabled)
    }

    static func saveEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: UserDefaultsKeys.dockMenusEnabled)
    }
}
