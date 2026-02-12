/// Debug preference wiring that applies runtime debug settings immediately.
import Foundation

extension AppController {
    internal var isDebugLogToFileEnabledInSettings: Bool {
        DebugPreferencesStore.loadLogToFileEnabled()
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
}
