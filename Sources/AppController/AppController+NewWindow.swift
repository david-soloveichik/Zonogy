/// Opens a new window of an application by posting Cmd-N to a running app or launching it.

import AppKit
import Foundation

extension AppController {
    /// Virtual keycode for the "N" key (US layout).
    private static let virtualKeyN: CGKeyCode = 45

    /// Opens a new window of the application at `appURL`.
    ///
    /// - If the app is running: activates it (so the new window becomes key) and posts a Cmd-N
    ///   keystroke to its process. The app's standard "new window" handler creates the window,
    ///   which Zonogy then captures and places into the currently targeted zone.
    /// - If the app is not running: launches it via `NSWorkspace`. The launch typically opens a
    ///   window of its own, which Zonogy captures and places.
    internal func openNewWindow(forAppURL appURL: URL, reason: String) {
        if let bundleId = ApplicationIdentity.bundleIdentifier(forApplicationURL: appURL),
           let runningApp = ApplicationIdentity.runningApplication(bundleIdentifier: bundleId) {
            Logger.debug("NewWindow: posting Cmd-N to running \(bundleId) pid=\(runningApp.processIdentifier) (\(reason))")
            // `activate(options:)` returns immediately but activation is async — many apps
            // only handle Cmd-N as a key-equivalent after their menu state catches up.
            // Activate first, then either dispatch on the activation notification or fall
            // back to a short delay so the keystroke lands after the app is ready.
            let pid = runningApp.processIdentifier
            let wasAlreadyActive = runningApp.isActive
            runningApp.activate(options: [.activateIgnoringOtherApps])
            if wasAlreadyActive {
                postCmdN(toPid: pid)
            } else {
                postCmdNAfterActivation(pid: pid)
            }
            return
        }

        Logger.debug("NewWindow: launching \(appURL.lastPathComponent) (\(reason))")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { app, error in
            if let error = error {
                Logger.debug("NewWindow: Failed to launch app at \(appURL.path): \(error.localizedDescription)")
            } else if let app = app {
                Logger.debug("NewWindow: Launched \(app.localizedName ?? appURL.lastPathComponent)")
            }
        }
    }

    /// Posts Cmd-N to `pid` once the system reports the app has finished activating, or after
    /// a short fallback delay if the activation notification doesn't arrive promptly.
    private func postCmdNAfterActivation(pid: pid_t) {
        let center = NSWorkspace.shared.notificationCenter
        var observer: NSObjectProtocol?
        var didFire = false

        let post: () -> Void = { [weak self] in
            if didFire { return }
            didFire = true
            if let observer {
                center.removeObserver(observer)
            }
            self?.postCmdN(toPid: pid)
        }

        observer = center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { notification in
            guard let activatedApp = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  activatedApp.processIdentifier == pid else {
                return
            }
            post()
        }

        // Fallback: post anyway after a short window in case activation was a no-op
        // (e.g., the app's policy doesn't change frontmost) or the notification is missed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            post()
        }
    }

    /// Posts a Cmd-N keystroke to `pid` to open a new window. Assumes the target app is already
    /// active (callers activate it first when needed). Reused by CmdTab's "new window" shortcut,
    /// which targets the already-frontmost app.
    func postCmdN(toPid pid: pid_t) {
        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: Self.virtualKeyN, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: Self.virtualKeyN, keyDown: false) else {
            Logger.debug("NewWindow: Failed to construct Cmd-N CGEvents for pid \(pid)")
            return
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.postToPid(pid)
        keyUp.postToPid(pid)
    }
}
