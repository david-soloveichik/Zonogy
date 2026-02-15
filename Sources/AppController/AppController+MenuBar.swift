/// AppController extension for menu bar integration
import Foundation
import AppKit

extension AppController {
    internal func reloadLauncherItems() {
        Task {
            await LauncherAppCache.shared.reload()
        }
    }

    // MARK: - MenuBarManagerDelegate

    func menuBarManagerDidRequestQuit() {
        Logger.debug("Quit requested from menu bar - terminating application")
        NSApplication.shared.terminate(nil)
    }

    func menuBarManagerDidRequestReloadConfiguration() {
        reloadConfiguration()
    }

    func menuBarManagerDidRequestPreferences() {
        // Close Launcher if open to avoid overlap with Preferences window
        dismissLauncherIfActive()
        PreferencesWindowController.shared.showWindow()
    }
}
