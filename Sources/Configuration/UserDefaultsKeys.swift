import Foundation

/// Centralized UserDefaults keys for Zonogy preferences.
/// Using a structured enum prevents key typos and provides discoverability.
enum UserDefaultsKeys {
    // MARK: - Dock Menus
    static let dockMenusEnabled = "Zonogy.dockMenus.enabled"
    static let dockMenusTargetsZoneWithActiveWindow = "Zonogy.dockMenus.targetsZoneWithActiveWindow"

    // MARK: - CmdTab
    static let cmdTabTargetsZoneWithActiveWindow = "Zonogy.cmdTab.targetsZoneWithActiveWindow"

    // MARK: - General
    static let stickyResizeEnabled = "Zonogy.general.stickyResize.enabled"

    // MARK: - Debug
    static let debugLogToFile = "Zonogy.debug.logToFile"
    static let dockMenusDebugOverlay = "Zonogy.dockMenus.debugOverlay"
    static let fullScreenDebugOverlay = "Zonogy.fullScreen.debugOverlay"

    // MARK: - Launcher
    static let launcherAutoShowForEmptyZones = "Zonogy.launcher.autoShowForEmptyZones"

    // MARK: - WinShot
    static let winShotEnabled = "Zonogy.winShot.enabled"
    static let winShotAutoSaveSnapshots = "Zonogy.winShot.autoSaveSnapshots"
    static let winShotMaxSnapshotsStored = "Zonogy.winShot.maxSnapshotsStored"
}
