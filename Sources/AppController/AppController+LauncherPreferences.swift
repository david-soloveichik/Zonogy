/// Launcher settings wiring and persistence.

import Foundation

extension AppController {
    internal var isAutoShowLauncherForEmptyZonesEnabledInSettings: Bool {
        autoShowLauncherForEmptyZonesEnabled
    }

    internal func setAutoShowLauncherForEmptyZonesEnabledFromSettings(_ enabled: Bool) {
        Logger.debug("Launcher: settings updated autoShowForEmptyZones=\(enabled)")
        autoShowLauncherForEmptyZonesEnabled = enabled
        LauncherBehaviorPreferencesStore.saveAutoShowForEmptyZones(enabled)
        if enabled {
            autoShowLauncherIfEmptyTargetedTiledZone()
        }
    }
}

