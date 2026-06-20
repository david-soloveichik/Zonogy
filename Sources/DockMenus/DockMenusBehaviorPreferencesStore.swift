/// Persists DockMenus behavior preferences using UserDefaults.

import Foundation

enum DockMenusBehaviorPreferencesStore {
    private static let defaultTargetsZoneWithActiveWindow = false

    static func loadTargetsZoneWithActiveWindow() -> Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: UserDefaultsKeys.dockMenusTargetsZoneWithActiveWindow) == nil {
            return defaultTargetsZoneWithActiveWindow
        }
        return defaults.bool(forKey: UserDefaultsKeys.dockMenusTargetsZoneWithActiveWindow)
    }

    static func saveTargetsZoneWithActiveWindow(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: UserDefaultsKeys.dockMenusTargetsZoneWithActiveWindow)
    }
}
