/// Persists user-facing Launcher behavior preferences using UserDefaults.

import Foundation

enum LauncherBehaviorPreferencesStore {
    private static let defaultAutoShowForEmptyZones = true
    private static let defaultShortcutTargetsZoneWithActiveWindow = true

    static func loadAutoShowForEmptyZones() -> Bool {
        let defaults = UserDefaults.standard
        // If the key hasn't been set, return the default value
        if defaults.object(forKey: UserDefaultsKeys.launcherAutoShowForEmptyZones) == nil {
            return defaultAutoShowForEmptyZones
        }
        return defaults.bool(forKey: UserDefaultsKeys.launcherAutoShowForEmptyZones)
    }

    static func saveAutoShowForEmptyZones(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: UserDefaultsKeys.launcherAutoShowForEmptyZones)
    }

    static func loadShortcutTargetsZoneWithActiveWindow() -> Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: UserDefaultsKeys.launcherShortcutTargetsZoneWithActiveWindow) == nil {
            return defaultShortcutTargetsZoneWithActiveWindow
        }
        return defaults.bool(forKey: UserDefaultsKeys.launcherShortcutTargetsZoneWithActiveWindow)
    }

    static func saveShortcutTargetsZoneWithActiveWindow(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: UserDefaultsKeys.launcherShortcutTargetsZoneWithActiveWindow)
    }
}
