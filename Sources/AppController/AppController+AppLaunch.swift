/// Launches applications for the Launcher, DockMenus, and new-window requests, and brings up the
/// window of a launched application that restores it minimized (it was minimized when the
/// application last quit), which would otherwise leave the launch showing no window.

import AppKit
import Foundation

extension AppController {
    /// Launches the application at `url` and activates it. `logPrefix` names the requesting feature.
    internal func launchApplication(at url: URL, logPrefix: String) {
        let awaitedBundleId = awaitFirstWindow(ofLaunchAt: url)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { [weak self] app, error in
            if let error {
                Logger.error("\(logPrefix): Failed to launch app at \(url.path): \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self?.endLaunchWait(awaitedBundleId)
                }
            } else if let app {
                Logger.debug("\(logPrefix): Launched \(app.localizedName ?? url.lastPathComponent)")
            }
        }
    }

    /// Remembers a launch of the application at `url`, unless it is already running, until the
    /// launch shows a window or fails, or the application quits. Returns the remembered bundle identifier.
    @discardableResult
    internal func awaitFirstWindow(ofLaunchAt url: URL) -> String? {
        guard let bundleId = ApplicationIdentity.bundleIdentifier(forApplicationURL: url),
              !ApplicationIdentity.isRunning(bundleIdentifier: bundleId) else {
            return nil
        }
        launchesAwaitingFirstWindow.insert(bundleId)
        return bundleId
    }

    internal func endLaunchWait(_ bundleId: String?) {
        guard let bundleId else { return }
        launchesAwaitingFirstWindow.remove(bundleId)
    }

    /// A window that comes up (captured unminimized, or unminimized by anyone) completes its
    /// application's launch; a captured one is placed as usual.
    internal func completeLaunch(showing window: ManagedWindow) {
        guard !launchesAwaitingFirstWindow.isEmpty else { return }
        endLaunchWait(bundleIdentifier(ofPid: window.backing.pid))
    }

    /// Selects the preferred window of an application whose launch has shown only minimized
    /// windows so far. An application that stopped answering is handled once it answers again.
    internal func showLaunchedWindowIfOnlyMinimized(pid: pid_t) {
        guard !launchesAwaitingFirstWindow.isEmpty,
              let bundleId = bundleIdentifier(ofPid: pid),
              launchesAwaitingFirstWindow.contains(bundleId),
              !sleepWakeProtectionActive,
              !AXUnavailableApps.contains(pid),
              // No window of the app is in a zone yet, so the Launcher's and DockMenus' selections agree.
              selectPreferredWindow(ofAppWithBundleIdentifier: bundleId, activateInPlace: false) else {
            return
        }
        Logger.debug("AppLaunch: \(bundleId) came up with only minimized windows; selected its preferred window")
        launchesAwaitingFirstWindow.remove(bundleId)
    }

    // MARK: - WindowControllerDelegate

    func windowController(_ controller: WindowController, didCaptureMinimizedWindow window: ManagedWindow) {
        guard !launchesAwaitingFirstWindow.isEmpty else { return }
        let pid = window.backing.pid
        // Decide once the capture pass ends: a window the application restores unminimized along
        // with this one is placed as usual and completes the launch instead.
        DispatchQueue.main.async { [weak self] in
            self?.showLaunchedWindowIfOnlyMinimized(pid: pid)
        }
    }

    private func bundleIdentifier(ofPid pid: pid_t) -> String? {
        NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
    }
}
