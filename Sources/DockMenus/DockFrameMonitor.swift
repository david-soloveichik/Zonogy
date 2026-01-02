import Foundation
import AppKit
import ApplicationServices

/// Tracks Dock AXList frame changes and emits state updates.
final class DockFrameMonitor {
    struct State: Equatable {
        /// The AXFrame of the Dock's AXList element when AXSelectedChildrenChanged fires.
        var listFrame: CGRect?
    }

    var onStateChange: ((State) -> Void)?

    private var lastState: State?
    private var axNotificationMonitor: DockAXNotificationMonitor?

    func start() {
        guard axNotificationMonitor == nil else { return }

        let monitor = DockAXNotificationMonitor()
        monitor.onEvent = { [weak self] event in
            self?.handleDockEvent(event)
        }
        axNotificationMonitor = monitor
        monitor.start()
    }

    func stop() {
        axNotificationMonitor?.stop()
        axNotificationMonitor = nil
        lastState = nil
    }

    private func handleDockEvent(_ event: DockAXNotificationMonitor.Event) {
        if event.notification == (kAXSelectedChildrenChangedNotification as String) {
            let next = State(listFrame: event.listFrame)

            guard next != lastState else { return }
            lastState = next

            if let frame = next.listFrame {
                Logger.debug("DockFrameMonitor: list frame=\(frame)")
            }

            DispatchQueue.main.async { [weak self] in
                self?.onStateChange?(next)
            }
        }
    }
}
