/// Persists opt-in features shown in Preferences > Experimental; all default to off.
import Foundation

enum ExperimentalPreferencesStore {
    static func loadInstantMinimizeEnabled() -> Bool {
        UserDefaults.standard.bool(forKey: UserDefaultsKeys.instantMinimizeEnabled)
    }

    static func saveInstantMinimizeEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: UserDefaultsKeys.instantMinimizeEnabled)
    }

    static func loadInstantMinimizeKeepAfterQuit() -> Bool {
        UserDefaults.standard.bool(forKey: UserDefaultsKeys.instantMinimizeKeepAfterQuit)
    }

    static func saveInstantMinimizeKeepAfterQuit(_ keep: Bool) {
        UserDefaults.standard.set(keep, forKey: UserDefaultsKeys.instantMinimizeKeepAfterQuit)
    }
}
