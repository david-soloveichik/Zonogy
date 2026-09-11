/// Persists user-facing debug preferences shown in Preferences > Debug.
import Foundation

enum DebugPreferencesStore {
    private static let defaultLogFileEnabled = false
    private static let defaultDockMenusOverlayEnabled = false
    private static let defaultFullScreenOverlayEnabled = false
    private static let defaultShowPlaceholderPassThroughHoles = false
    private static let defaultDisablePrePositionBeforeUnminimize = false
    private static let defaultDisableNativeTabHandling = false
    private static let defaultHighlightImplicitFloatingTarget = false

    static func loadLogFileEnabled() -> Bool {
        loadBool(forKey: UserDefaultsKeys.logFileEnabled, defaultValue: defaultLogFileEnabled)
    }

    static func saveLogFileEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: UserDefaultsKeys.logFileEnabled)
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

    static func loadShowPlaceholderPassThroughHoles() -> Bool {
        loadBool(
            forKey: UserDefaultsKeys.showPlaceholderPassThroughHoles,
            defaultValue: defaultShowPlaceholderPassThroughHoles
        )
    }

    static func saveShowPlaceholderPassThroughHoles(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: UserDefaultsKeys.showPlaceholderPassThroughHoles)
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

    static func loadHighlightImplicitFloatingTarget() -> Bool {
        loadBool(
            forKey: UserDefaultsKeys.highlightImplicitFloatingTarget,
            defaultValue: defaultHighlightImplicitFloatingTarget
        )
    }

    static func saveHighlightImplicitFloatingTarget(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: UserDefaultsKeys.highlightImplicitFloatingTarget)
    }

    private static func loadBool(forKey key: String, defaultValue: Bool) -> Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: key) == nil {
            return defaultValue
        }
        return defaults.bool(forKey: key)
    }
}
