/// Debug preference wiring that applies runtime debug settings immediately.
import Foundation

extension AppController {
    internal var isDebugLogToFileEnabledInSettings: Bool {
        DebugPreferencesStore.loadLogToFileEnabled()
    }

    internal var isDisablePrePositionBeforeUnminimizeInSettings: Bool {
        DebugPreferencesStore.loadDisablePrePositionBeforeUnminimize()
    }

    internal var isNativeTabHandlingDisabledInSettings: Bool {
        DebugPreferencesStore.loadDisableNativeTabHandling()
    }

    internal func setDebugLogToFileEnabledFromSettings(_ enabled: Bool) {
        let wasEnabled = Logger.logToFile
        DebugPreferencesStore.saveLogToFileEnabled(enabled)

        if enabled {
            if !wasEnabled {
                Logger.clearLogFile()
            }
            Logger.logToFile = true
            Logger.debug("Debug file logging enabled (cleared: \(Logger.logPath))")
            return
        }

        if wasEnabled {
            Logger.debug("Debug file logging disabled")
        }
        Logger.logToFile = false
    }

    internal func setDisablePrePositionBeforeUnminimizeFromSettings(_ enabled: Bool) {
        Logger.debug("Debug: disable pre-position before unminimize=\(enabled)")
        DebugPreferencesStore.saveDisablePrePositionBeforeUnminimize(enabled)
    }

    internal func setNativeTabHandlingDisabledFromSettings(_ disabled: Bool) {
        Logger.debug("Debug: disable native macOS tab handling=\(disabled)")
        DebugPreferencesStore.saveDisableNativeTabHandling(disabled)
        windowController.nativeTabHandlingDisabled = disabled
    }
}
