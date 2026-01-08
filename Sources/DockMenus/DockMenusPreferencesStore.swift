/// Persists user-facing DockMenus enablement preferences using UserDefaults.

import Foundation

enum DockMenusPreferencesStore {
    static func loadEnabled() -> Bool {
        UserDefaults.standard.bool(forKey: UserDefaultsKeys.dockMenusEnabled)
    }

    static func saveEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: UserDefaultsKeys.dockMenusEnabled)
    }

    static func loadDebugOverlay() -> Bool? {
        UserDefaults.standard.object(forKey: UserDefaultsKeys.dockMenusDebugOverlay) as? Bool
    }

    static func saveDebugOverlay(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: UserDefaultsKeys.dockMenusDebugOverlay)
    }
}
