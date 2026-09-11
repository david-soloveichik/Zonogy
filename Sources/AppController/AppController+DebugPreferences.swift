/// Debug preference wiring that applies runtime debug settings immediately.
import Foundation

extension AppController {
    internal var isLogFileEnabledInSettings: Bool {
        DebugPreferencesStore.loadLogFileEnabled()
    }

    internal var isShowPlaceholderPassThroughHolesInSettings: Bool {
        DebugPreferencesStore.loadShowPlaceholderPassThroughHoles()
    }

    internal var isDisablePrePositionBeforeUnminimizeInSettings: Bool {
        DebugPreferencesStore.loadDisablePrePositionBeforeUnminimize()
    }

    internal var isNativeTabHandlingDisabledInSettings: Bool {
        DebugPreferencesStore.loadDisableNativeTabHandling()
    }

    internal var isHighlightImplicitFloatingTargetInSettings: Bool {
        DebugPreferencesStore.loadHighlightImplicitFloatingTarget()
    }

    /// Enables the file before logging the change, so the file's first line records what turned it on.
    internal func setLogFileEnabledFromSettings(_ enabled: Bool) {
        DebugPreferencesStore.saveLogFileEnabled(enabled)
        LogFile.setEnabled(enabled)
        Logger.debug("Debug: save the log to a file=\(enabled)")
    }

    internal func setShowPlaceholderPassThroughHolesFromSettings(_ enabled: Bool) {
        Logger.debug("Debug: show placeholder pass-through holes=\(enabled)")
        DebugPreferencesStore.saveShowPlaceholderPassThroughHoles(enabled)
        for placeholder in placeholderCoordinator.allActivePlaceholders() {
            placeholder.refreshPassThroughDebugFill()
        }
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

    internal func setHighlightImplicitFloatingTargetFromSettings(_ enabled: Bool) {
        Logger.debug("Debug: highlight implicitly targeted floating zone bar=\(enabled)")
        DebugPreferencesStore.saveHighlightImplicitFloatingTarget(enabled)
        refreshIndicators()
    }
}
