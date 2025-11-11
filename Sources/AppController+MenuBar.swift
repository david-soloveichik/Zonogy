/// AppController extension for menu bar integration
import Foundation
import AppKit

extension AppController {
    // MARK: - MenuBarManagerDelegate

    func menuBarManagerDidRequestQuit() {
        Logger.debug("Quit requested from menu bar - terminating application")
        NSApplication.shared.terminate(nil)
    }
}
