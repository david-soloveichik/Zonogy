import AppKit
import ApplicationServices
import Foundation

/// DockMenus feature wiring and lifecycle management.
extension AppController {
    internal var isDockMenusEnabledInSettings: Bool {
        let config = effectiveDockMenusConfiguration()
        return config.isEnabled || config.showsDockFrameOverlay
    }

    internal func startDockMenusIfConfigured() {
        let dockMenusConfig = effectiveDockMenusConfiguration()
        guard dockMenusConfig.isEnabled || dockMenusConfig.showsDockFrameOverlay else {
            Logger.debug("DockMenus: disabled")
            return
        }

        Logger.debug("DockMenus: enabled (debugOverlay=\(dockMenusConfig.showsDockFrameOverlay))")
        let coordinator = DockMenusCoordinator(
            primaryScreenBounds: screenContextStore.primaryScreenBounds,
            enableDebugOverlay: dockMenusConfig.showsDockFrameOverlay
        )
        coordinator.delegate = self
        dockMenusCoordinator = coordinator
        coordinator.start()
    }

    internal func stopDockMenus() {
        Logger.debug("DockMenus: stop requested")
        dockMenusCoordinator?.stop()
        dockMenusCoordinator = nil
    }

    internal func setDockMenusEnabledFromSettings(_ enabled: Bool) {
        Logger.debug("DockMenus: settings updated enabled=\(enabled)")
        DockMenusPreferencesStore.saveEnabled(enabled)
        applyDockMenusConfiguration()
    }

    private func effectiveDockMenusConfiguration() -> DockMenusConfiguration {
        let baseConfig = configuration.dockMenusConfiguration
        guard let preferences = DockMenusPreferencesStore.loadPreferences() else {
            return baseConfig
        }

        return DockMenusConfiguration(
            enabled: preferences.enabled,
            debugDockFrameOverlay: preferences.enabled
        )
    }

    private func applyDockMenusConfiguration() {
        stopDockMenus()
        startDockMenusIfConfigured()
    }
}

// MARK: - DockMenusCoordinatorDelegate

extension AppController: DockMenusCoordinatorDelegate {
    func dockMenusCoordinator(_ coordinator: DockMenusCoordinator, didClickDockAppWithURL appURL: URL) {
        Logger.debug("DockMenus: click on \(appURL.lastPathComponent)")
        // DockMenus uses activateInPlace:true - windows already in a zone are activated
        // without being moved to the targeted zone (unlike the Launcher)
        performDefaultLauncherAction(for: appURL, activateInPlace: true)
    }

    func dockMenusCoordinator(_ coordinator: DockMenusCoordinator, windowsForBundleId bundleId: String) -> [LauncherWindowItem] {
        // Reuse the existing LauncherWindowProvider implementation
        return windowsForApp(bundleIdentifier: bundleId)
    }

    func dockMenusCoordinator(_ coordinator: DockMenusCoordinator, didSelectWindow window: LauncherWindowItem) {
        Logger.debug("DockMenus: window selected \(window.title)")
        // Reuse Launcher's window selection with activateInPlace semantics
        handleWindowSelection(window, activateInPlace: true)
    }

    func dockMenusCoordinator(_ coordinator: DockMenusCoordinator, didSelectAppHeader bundleId: String) {
        Logger.debug("DockMenus: app header selected for \(bundleId)")
        // Activate the app without targeting a specific window
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first {
            app.activate(options: [.activateIgnoringOtherApps])
        }
    }
}
