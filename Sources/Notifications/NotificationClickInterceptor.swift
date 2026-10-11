/// Lets Zonogy act on a left mouse-down on a notification before Notification Center receives it.
import ApplicationServices
import Foundation

/// Hands each left mouse-down on a shown notification to `onPress`, then lets it through unchanged.
///
/// Performance-critical, like the Dock press tap: the tap is enabled only while a notification of
/// a running application shows (a disabled tap costs nothing per event), and it answers on the
/// mouse tap thread, so a press anywhere else passes at once without involving the main thread. A
/// press on a notification waits while `onPress` runs on the main thread, so whatever `onPress`
/// sends is sent before Notification Center sees the press.
final class NotificationClickInterceptor {
    /// Runs on the main thread while the press waits, with the pressed notification's applications
    /// (see `NotificationCenterMonitor.ShownNotification.pids`).
    var onPress: (([pid_t]) -> Void)?

    /// The shown notifications of running applications, mirrored for the tap's thread.
    @ThreadSafe private var targets: [NotificationCenterMonitor.ShownNotification] = []

    private var pressTap: EventTapController?

    func start() {
        guard pressTap == nil else { return }
        let tap = EventTapController(
            name: "NotificationClickInterceptor press",
            events: [.leftMouseDown],
            runLoop: EventTapThread.mouse.runLoop
        ) { [weak self] _, event in
            self?.processPress(event)
            return .pass
        }
        tap.isEnabled = !targets.isEmpty
        if tap.start() {
            pressTap = tap
        }
    }

    /// Called on the main thread whenever the shown notifications change.
    func update(with notifications: [NotificationCenterMonitor.ShownNotification]) {
        targets = notifications.filter { !$0.pids.isEmpty }
        pressTap?.isEnabled = !targets.isEmpty
    }

    /// Notifications of different applications never overlap; a stack's overlapping ones share one.
    private func processPress(_ event: CGEvent) {
        let location = event.location
        guard let target = targets.first(where: { $0.frame.contains(location) }) else { return }
        MainRunLoop.performAndWait {
            self.onPress?(target.pids)
        }
    }
}
