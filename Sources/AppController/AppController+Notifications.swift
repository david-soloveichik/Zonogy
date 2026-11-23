/// Notification Center wiring: pre-positions an application's minimized windows when the user
/// clicks one of its notifications, lets the user drag a notification onto a drop destination, and
/// draws the notification debug rectangles.
import AppKit
import Foundation

extension AppController {
    internal var isNotificationDebugOverlayEnabledInSettings: Bool {
        DebugPreferencesStore.loadNotificationOverlayEnabled()
    }

    internal func startNotificationGestures() {
        let interceptor = notificationGestureInterceptor
        interceptor.onClick = { [weak self] notification in
            self?.prePositionMinimizedWindows(ofApplications: notification.pids, reason: "notification-click")
        }
        interceptor.onBeginDrag = { [weak self] notification, cursorPointAX in
            guard let self else { return }
            Logger.debug("Notification drag: began on a notification of \(notification.applicationName ?? "an unknown app")")
            notificationDragController.beginDrag(
                for: notification,
                title: notification.applicationName ?? "Notification",
                initialCursorPointCocoa: cocoaPoint(fromAccessibilityPoint: cursorPointAX),
                driveViaMouseMonitors: false
            )
        }
        interceptor.onUpdateDrag = { [weak self] cursorPointAX in
            guard let self else { return }
            notificationDragController.updateDrag(
                cursorPointAX: cursorPointAX,
                cursorPointCocoa: cocoaPoint(fromAccessibilityPoint: cursorPointAX)
            )
        }
        interceptor.onEndDrag = { [weak self] cursorPointAX in
            self?.notificationDragController.endDrag(cursorPointAX: cursorPointAX)
        }
        interceptor.onAbortDrag = { [weak self] in
            self?.notificationDragController.cancelDrag()
            self?.dragDropCoordinator.tearDownDragSession()
        }
        // The swallowed release still ends the gesture for manual-drag tracking: a notification drag
        // claimed the button and blocks window drags until its mouse-up, so without this the next
        // window drag would be ignored.
        interceptor.onSwallowedRelease = { [weak self] in
            self?.windowController.handleMouseUp()
        }
        interceptor.start()
        notificationCenterMonitor.onChange = { [weak self] notifications in
            self?.notificationGestureInterceptor.update(with: notifications)
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

    // MARK: - Dragging a notification

    /// Shows the preview of a dragged notification and drives the drag over the drop destinations.
    /// The drop targets its destination, then presses the notification: whichever window its
    /// application brings up arrives there (a minimized one restores straight into it).
    internal func makeNotificationDragController() -> CursorDrivenRowDragController<NotificationCenterMonitor.ShownNotification> {
        CursorDrivenRowDragController(
            logPrefix: "Notification drag",
            currentCursorAXProvider: { [weak self] in
                self?.currentCursorAccessibilityPoint()
            },
            onDidBeginDrag: { [weak self] _ in
                self?.launcherController.hide()
                self?.beginCursorDrivenLaunchTargetDrag()
            },
            onDidUpdateDrag: { [weak self] cursorPointAX in
                self?.dragDropCoordinator.updateCursorDrivenDragSession(cursorPointAX: cursorPointAX)
            },
            onDidEndDrag: { [weak self] notification, cursorPointAX in
                guard let self else { return }
                performCursorDrivenLaunchTargetDrop(cursorPointAX: cursorPointAX, reason: "notification-drag") {
                    self.prePositionMinimizedWindows(ofApplications: notification.pids, reason: "notification-drag")
                    self.notificationCenterMonitor.press(notification)
                }
            },
            onDidCancelByUser: { [weak self] _ in
                // The interceptor still owns the button until release; mark the drag cancelled so
                // that release cannot drop.
                self?.notificationGestureInterceptor.cancelInProgressDrag()
                self?.dragDropCoordinator.tearDownDragSession()
            }
        )
    }

    private func cocoaPoint(fromAccessibilityPoint point: CGPoint) -> CGPoint {
        CoordinateConversion.accessibilityToCocoa(point: point, primaryScreenBounds: primaryScreenBounds)
    }
}
