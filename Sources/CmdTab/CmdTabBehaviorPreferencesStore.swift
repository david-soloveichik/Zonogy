/// Persists CmdTab behavior preferences using UserDefaults.

import Foundation

enum CmdTabBehaviorPreferencesStore {
    private static let defaultTargetsZoneWithActiveWindow = true

    static func loadTargetsZoneWithActiveWindow() -> Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: UserDefaultsKeys.cmdTabTargetsZoneWithActiveWindow) == nil {
            return defaultTargetsZoneWithActiveWindow
        }
        return defaults.bool(forKey: UserDefaultsKeys.cmdTabTargetsZoneWithActiveWindow)
    }

    static func saveTargetsZoneWithActiveWindow(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: UserDefaultsKeys.cmdTabTargetsZoneWithActiveWindow)
    }
}
