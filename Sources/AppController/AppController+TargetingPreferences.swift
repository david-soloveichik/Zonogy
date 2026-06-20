/// Feature-specific targeting preference wiring and persistence.

import Foundation

extension AppController {
    internal var isLauncherShortcutTargetsZoneWithActiveWindowEnabledInSettings: Bool {
        launcherShortcutTargetsZoneWithActiveWindowEnabled
    }

    internal var isDockMenusTargetsZoneWithActiveWindowEnabledInSettings: Bool {
        dockMenusTargetsZoneWithActiveWindowEnabled
    }

    internal var cmdTabActiveWindowTargetingModeInSettings: CmdTabActiveWindowTargetingMode {
        cmdTabActiveWindowTargetingMode
    }

    internal func setDockMenusTargetsZoneWithActiveWindowEnabledFromSettings(_ enabled: Bool) {
        Logger.debug("DockMenus: settings updated targetsZoneWithActiveWindow=\(enabled)")
        dockMenusTargetsZoneWithActiveWindowEnabled = enabled
        DockMenusBehaviorPreferencesStore.saveTargetsZoneWithActiveWindow(enabled)
    }

    internal func setLauncherShortcutTargetsZoneWithActiveWindowEnabledFromSettings(_ enabled: Bool) {
        Logger.debug("Launcher: settings updated shortcutTargetsZoneWithActiveWindow=\(enabled)")
        launcherShortcutTargetsZoneWithActiveWindowEnabled = enabled
        LauncherBehaviorPreferencesStore.saveShortcutTargetsZoneWithActiveWindow(enabled)
    }

    internal func setCmdTabActiveWindowTargetingModeFromSettings(_ mode: CmdTabActiveWindowTargetingMode) {
        Logger.debug("CmdTab: settings updated activeWindowTargetingMode=\(mode.rawValue)")
        cmdTabActiveWindowTargetingMode = mode
        CmdTabBehaviorPreferencesStore.saveTargetingMode(mode)
    }
}
