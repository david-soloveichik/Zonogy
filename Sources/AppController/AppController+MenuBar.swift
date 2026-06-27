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

    func menuBarManagerDidRequestPreferences() {
        // Opening Preferences picks up any out-of-band edits to config.json /
        // launcher-config.json so the running app reflects the current on-disk
        // configuration (exceptions, ignored bundles, launcher items/aliases).
        reloadConfiguration()
        // Close Launcher if open to avoid overlap with Preferences window
        dismissLauncherIfActive()
        PreferencesWindowController.shared.showWindow()
    }
}
