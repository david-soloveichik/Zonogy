/// Notification Center wiring: pre-positions an application's minimized windows when the user
/// presses one of its notifications, and draws the notification debug rectangles.
import Foundation

extension AppController {
    internal var isNotificationDebugOverlayEnabledInSettings: Bool {
        DebugPreferencesStore.loadNotificationOverlayEnabled()
    }

    internal func startNotificationPressPrePositioning() {
        notificationClickInterceptor.onPress = { [weak self] pid in
            self?.prePositionMinimizedWindows(ofApplication: pid, reason: "notification-press")
        }
        notificationClickInterceptor.start()
        notificationCenterMonitor.onChange = { [weak self] notifications in
            self?.notificationClickInterceptor.update(with: notifications)
            self?.notificationDebugOverlay?.showBorders(around: notifications.map(\.frame))
        }
        notificationCenterMonitor.start()
        applyNotificationDebugOverlaySetting()
    }

    internal func setNotificationDebugOverlayEnabledFromSettings(_ enabled: Bool) {
        Logger.debug("Debug: show notification debug rectangles=\(enabled)")
        DebugPreferencesStore.saveNotificationOverlayEnabled(enabled)
        applyNotificationDebugOverlaySetting()
    }

    /// Shows or removes the notification borders to match the Debug setting.
    private func applyNotificationDebugOverlaySetting() {
        notificationDebugOverlay?.showBorders(around: [])
        notificationDebugOverlay = nil
        guard isNotificationDebugOverlayEnabledInSettings else { return }
        let overlay = NotificationDebugOverlayController(primaryScreenBounds: primaryScreenBounds)
        overlay.showBorders(around: notificationCenterMonitor.notifications.map(\.frame))
        notificationDebugOverlay = overlay
    }
}
