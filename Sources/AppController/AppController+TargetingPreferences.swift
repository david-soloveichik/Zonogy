/// Feature-specific targeting preference wiring and persistence.

import Foundation

extension AppController {
    internal var isDockMenusTargetsZoneWithActiveWindowEnabledInSettings: Bool {
        dockMenusTargetsZoneWithActiveWindowEnabled
    }

    internal var isCmdTabTargetsZoneWithActiveWindowEnabledInSettings: Bool {
        cmdTabTargetsZoneWithActiveWindowEnabled
    }

    internal func setDockMenusTargetsZoneWithActiveWindowEnabledFromSettings(_ enabled: Bool) {
        Logger.debug("DockMenus: settings updated targetsZoneWithActiveWindow=\(enabled)")
        dockMenusTargetsZoneWithActiveWindowEnabled = enabled
        DockMenusBehaviorPreferencesStore.saveTargetsZoneWithActiveWindow(enabled)
    }

    internal func setCmdTabTargetsZoneWithActiveWindowEnabledFromSettings(_ enabled: Bool) {
        Logger.debug("CmdTab: settings updated targetsZoneWithActiveWindow=\(enabled)")
        cmdTabTargetsZoneWithActiveWindowEnabled = enabled
        CmdTabBehaviorPreferencesStore.saveTargetsZoneWithActiveWindow(enabled)
    }
}
