import Foundation

/// Centralized UserDefaults keys for Zonogy preferences.
/// Using a structured enum prevents key typos and provides discoverability.
enum UserDefaultsKeys {
    // MARK: - Dock Menus
    static let dockMenusEnabled = "Zonogy.dockMenus.enabled"
    static let dockMenusDebugOverlay = "Zonogy.dockMenus.debugOverlay"

    // MARK: - Launcher
    static let launcherAutoShowForEmptyZones = "Zonogy.launcher.autoShowForEmptyZones"

    // MARK: - Targeting
    static let targetingMode = "Zonogy.targeting.mode"

    // MARK: - WinShot
    static let winShotEnabled = "Zonogy.winShot.enabled"
    static let winShotAutoSaveSnapshots = "Zonogy.winShot.autoSaveSnapshots"
    static let winShotMaxSnapshotsStored = "Zonogy.winShot.maxSnapshotsStored"
}
