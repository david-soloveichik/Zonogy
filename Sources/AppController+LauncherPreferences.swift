/// Launcher settings wiring and persistence.

import Foundation

extension AppController {
    internal var isAutoShowLauncherForEmptyTilingZonesEnabledInSettings: Bool {
        autoShowLauncherForEmptyTilingZonesEnabled
    }

    internal func setAutoShowLauncherForEmptyTilingZonesEnabledFromSettings(_ enabled: Bool) {
        Logger.debug("Launcher: settings updated autoShowForEmptyTilingZones=\(enabled)")
        autoShowLauncherForEmptyTilingZonesEnabled = enabled
        LauncherBehaviorPreferencesStore.saveAutoShowLauncherForEmptyTilingZonesEnabled(enabled)
        if enabled {
            autoShowLauncherIfEmptyTargetedTiledZone()
        }
    }
}

