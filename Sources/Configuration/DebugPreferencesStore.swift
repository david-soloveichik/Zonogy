/// Persists user-facing debug preferences shown in Preferences > Debug.
import Foundation

enum DebugPreferencesStore {
    private static let defaultLogToFileEnabled = false
    private static let defaultDockMenusOverlayEnabled = false
    private static let defaultFullScreenOverlayEnabled = false
    private static let defaultDisablePrePositionBeforeUnminimize = false
    private static let defaultDisableNativeTabHandling = false

    static func loadLogToFileEnabled() -> Bool {
        loadBool(
            forKey: UserDefaultsKeys.debugLogToFile,
            defaultValue: defaultLogToFileEnabled
        )
    }

    static func saveLogToFileEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: UserDefaultsKeys.debugLogToFile)
    }

    static func loadDockMenusOverlayEnabled() -> Bool {
        loadBool(
            forKey: UserDefaultsKeys.dockMenusDebugOverlay,
            defaultValue: defaultDockMenusOverlayEnabled
        )
    }

    static func saveDockMenusOverlayEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: UserDefaultsKeys.dockMenusDebugOverlay)
    }

    static func loadFullScreenOverlayEnabled() -> Bool {
        loadBool(
            forKey: UserDefaultsKeys.fullScreenDebugOverlay,
            defaultValue: defaultFullScreenOverlayEnabled
        )
    }

    static func saveFullScreenOverlayEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: UserDefaultsKeys.fullScreenDebugOverlay)
    }

    static func loadDisablePrePositionBeforeUnminimize() -> Bool {
        loadBool(
            forKey: UserDefaultsKeys.disablePrePositionBeforeUnminimize,
            defaultValue: defaultDisablePrePositionBeforeUnminimize
        )
    }

    static func saveDisablePrePositionBeforeUnminimize(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: UserDefaultsKeys.disablePrePositionBeforeUnminimize)
    }

    static func loadDisableNativeTabHandling() -> Bool {
        loadBool(
            forKey: UserDefaultsKeys.disableNativeTabHandling,
            defaultValue: defaultDisableNativeTabHandling
        )
    }

    static func saveDisableNativeTabHandling(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: UserDefaultsKeys.disableNativeTabHandling)
    }

    private static func loadBool(forKey key: String, defaultValue: Bool) -> Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: key) == nil {
            return defaultValue
        }
        return defaults.bool(forKey: key)
    }
}
