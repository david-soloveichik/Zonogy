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
            enableDebugOverlay: dockMenusConfig.showsDockFrameOverlay,
            refreshCoalesceInterval: dockMenusConfig.refreshCoalesceInterval
        )
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
            debugDockFrameOverlay: preferences.enabled,
            refreshCoalesceIntervalSeconds: baseConfig.refreshCoalesceIntervalSeconds
        )
    }

    private func applyDockMenusConfiguration() {
        stopDockMenus()
        startDockMenusIfConfigured()
    }
}
