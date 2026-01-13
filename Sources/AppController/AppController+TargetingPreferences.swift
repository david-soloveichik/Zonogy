/// Targeting mode settings wiring and persistence.

import Foundation

extension AppController {
    internal var targetingModeInSettings: TargetingMode {
        targetingMode
    }

    internal func setTargetingModeFromSettings(_ mode: TargetingMode) {
        Logger.debug("Targeting: settings updated mode=\(mode.rawValue)")
        targetingMode = mode
        TargetingPreferencesStore.saveMode(mode)

        if mode == .followsFocus {
            retargetToFocusedWindowZoneIfPossible(reason: "targeting-mode-change")
        }
    }
}

