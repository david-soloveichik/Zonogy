/// AppController extension for menu bar integration
import Foundation
import AppKit

extension AppController {
    // MARK: - MenuBarManagerDelegate

    func menuBarManagerDidRequestQuit() {
        Logger.debug("Quit requested from menu bar - terminating application")
        NSApplication.shared.terminate(nil)
    }

    func menuBarManagerDidRequestReloadLauncher() {
        Logger.debug("Reload Launcher List requested from menu bar")
        if launcherController.isActive {
            launcherController.hide()
            Logger.debug("Launcher: Hidden because launcher items are reloading")
        }
        Task {
            await LauncherAppCache.shared.reload()
        }
    }

    func menuBarManagerDidRequestPreferences() {
        // Close Launcher if open to avoid overlap with Preferences window
        dismissLauncherIfActive()
        PreferencesWindowController.shared.showWindow()
    }
}
