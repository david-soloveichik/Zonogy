/// Takes over left-button gestures on shown notifications, so a notification can be dragged onto a
/// drop destination as well as clicked.
import ApplicationServices
import Foundation

/// A press on a shown notification is held until the button comes up, since only then is it known to
/// be a click or a drag (see `PressGestureInterceptor`). A click is handed back: `onClick` runs, then
/// the press and its release are posted again, so Notification Center receives the click unchanged,
/// only later. A drag goes to the drag callbacks instead, and Notification Center never sees the
/// gesture. Presses with Shift or Control pass untouched, keeping Notification Center's own handling,
/// and so does a press on a notification that something else covers.
///
/// Performance-critical, like the Dock press tap: the press tap is enabled only while a notification
/// shows (a disabled tap costs nothing per event), and it answers on the mouse tap thread, so a press
/// anywhere else passes at once without involving the main thread. Callbacks run on the main thread;
/// positions are in accessibility coordinates.
final class NotificationGestureInterceptor {
    typealias ShownNotification = NotificationCenterMonitor.ShownNotification

    /// A press taken over, kept to be posted again if it turns out to be a click.
    struct HeldPress {
        let notification: ShownNotification
        let event: CGEvent
    }

    /// Runs before a click on the notification is handed back to Notification Center, so whatever it
    /// sends is sent before Notification Center sees the press.
    var onClick: ((ShownNotification) -> Void)?
    /// The press on the notification became a drag at the given point; the drag is followed only
    /// while this is set.
    var onBeginDrag: ((ShownNotification, CGPoint) -> Void)?
    var onUpdateDrag: ((CGPoint) -> Void)?
    var onEndDrag: ((CGPoint) -> Void)?
    /// The drag ended without its release; nothing is dropped.
    var onAbortDrag: (() -> Void)?
    /// Runs after the release ending a held gesture is swallowed: no event monitor sees that mouse-up
    /// (a click's posted copy comes later).
    var onSwallowedRelease: (() -> Void)?

    /// Marks the events posted to hand a click back, so the press tap lets them through.
    private static let handBackEventMarker: Int64 = 0x5A4E4E43

    /// The shown notifications, mirrored for the press tap's thread.
    @ThreadSafe private var shown: [ShownNotification] = []

    private lazy var gesture = PressGestureInterceptor(name: "NotificationGestureInterceptor", claimant: self)

    func start() {
        gesture.start()
    }

    /// Called on the main thread whenever the shown notifications change.
    func update(with notifications: [ShownNotification]) {
        shown = notifications
        gesture.isPressTapEnabled = !notifications.isEmpty
    }

    /// Cancels the drag in flight (e.g., the user pressed Escape): the rest of the gesture is
    /// swallowed without further callbacks.
    func cancelInProgressDrag() {
        gesture.cancelInProgressDrag()
    }

    /// The shown notification that is the topmost UI at `point`, as Accessibility finds it: a menu or
    /// panel drawn over a notification keeps its own presses, and a scan that lags the screen (the
    /// panel just scrolled, say) cannot pass one notification off as another. The rectangles only
    /// decide which presses are worth this check.
    private func topmostNotification(at point: CGPoint) -> ShownNotification? {
        let shown = self.shown
        let hit = AccessibilityHitTest.topmost(at: point) { element -> ShownNotification? in
            var identifier: CFTypeRef?
            guard AXCall.copyAttribute(element, kAXIdentifierAttribute as CFString, &identifier) == .success else {
                return nil
            }
            return shown.first { $0.identifier == identifier as? String }
        }
        guard case .match(let notification) = hit else {
            return nil
        }
        return notification
    }

    /// Posts the held press and its release, each where it happened, so Notification Center tracks
    /// the click itself, as it would have. The cursor visits the press point for an instant, at most a
    /// few points from where the button came up.
    private func handBack(_ press: CGEvent, release: CGEvent) {
        guard let releaseCopy = release.copy() else { return }
        for event in [press, releaseCopy] {
            event.setIntegerValueField(.eventSourceUserData, value: Self.handBackEventMarker)
            event.post(tap: .cghidEventTap)
        }
    }
}

// MARK: - PressGestureClaimant

extension NotificationGestureInterceptor: PressGestureClaimant {
    /// Runs on the mouse tap thread.
    func mayClaimPress(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) != Self.handBackEventMarker
            && event.flags.isDisjoint(with: [.maskShift, .maskControl])
            && shown.contains { $0.frame.contains(event.location) }
    }

    func claimPress(_ event: CGEvent) -> HeldPress? {
        guard let notification = topmostNotification(at: event.location), let press = event.copy() else {
            return nil
        }
        return HeldPress(notification: notification, event: press)
    }

    func beginDrag(of press: HeldPress, at point: CGPoint) -> Bool {
        guard let onBeginDrag else { return false }
        onBeginDrag(press.notification, point)
        return true
    }

    func updateDrag(to point: CGPoint) {
        onUpdateDrag?(point)
    }

    func endDrag(at point: CGPoint) {
        onEndDrag?(point)
    }

    func abortDrag() {
        onAbortDrag?()
    }

    /// The click is handed back only while the pressed notification is still the topmost UI where it
    /// was pressed. Otherwise (it left the screen meanwhile, say) the click is dropped rather than
    /// delivered to whatever is there now.
    func click(_ press: HeldPress, release: CGEvent) {
        guard topmostNotification(at: press.event.location)?.identifier == press.notification.identifier else {
            Logger.debug("NotificationGestureInterceptor: the pressed notification is gone; click dropped")
            return
        }
        onClick?(press.notification)
        handBack(press.event, release: release)
    }

    func didSwallowRelease() {
        onSwallowedRelease?()
    }
}
