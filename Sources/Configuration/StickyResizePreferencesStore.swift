/// Persists the user-facing Sticky Resize preference.

import Foundation

enum StickyResizePreferencesStore {
    private static let defaultEnabled = false

    static func loadEnabled() -> Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: UserDefaultsKeys.stickyResizeEnabled) == nil {
            return defaultEnabled
        }
        return defaults.bool(forKey: UserDefaultsKeys.stickyResizeEnabled)
    }

    static func saveEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: UserDefaultsKeys.stickyResizeEnabled)
    }
}
