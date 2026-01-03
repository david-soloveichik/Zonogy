import Foundation
import AppKit
import ApplicationServices

/// Tracks Dock AXList frame changes and emits state updates.
final class DockFrameMonitor {
    struct State: Equatable {
        /// The AXFrame of the Dock's AXList element when AXSelectedChildrenChanged fires.
        var listFrame: CGRect?
        /// Whether the Dock is considered visible (vs hidden due to autohide).
        var isVisible: Bool = false
    }

    var onStateChange: ((State) -> Void)?

    /// Called when cursor hovers over a running app's Dock icon (or nil when hover ends).
    var onAppHover: ((DockMenuHoverEvent?) -> Void)?

    private var lastState: State?
    private var axNotificationMonitor: DockAXNotificationMonitor?

    /// Cached frame from when the Dock was visible (non-negative x).
    /// Used to handle autohide animation where Dock reports hidden position before animation completes.
    private var cachedVisibleFrame: CGRect?

    func start() {
        guard axNotificationMonitor == nil else { return }

        let monitor = DockAXNotificationMonitor()
        monitor.onEvent = { [weak self] event in
            self?.handleDockEvent(event)
        }
        monitor.onAppHover = { [weak self] event in
            self?.onAppHover?(event)
        }
        axNotificationMonitor = monitor
        monitor.start()
    }

    func stop() {
        axNotificationMonitor?.stop()
        axNotificationMonitor = nil
        lastState = nil
    }

    /// Called by the click interceptor when it clicks in the Dock frame but finds no Dock element.
    /// This indicates the Dock is hidden (autohide).
    func markDockHidden() {
        guard lastState?.isVisible == true else { return }

        Logger.debug("DockFrameMonitor: Dock visibility changed to hidden")
        var next = lastState ?? State()
        next.isVisible = false
        lastState = next

        DispatchQueue.main.async { [weak self] in
            self?.onStateChange?(next)
        }
    }

    private func handleDockEvent(_ event: DockAXNotificationMonitor.Event) {
        Logger.debug("DockFrameMonitor: received event notification=\(event.notification) listFrame=\(event.listFrame.map { String(describing: $0) } ?? "nil")")

        if event.notification == (kAXSelectedChildrenChangedNotification as String) {
            // Determine the effective frame, handling Dock autohide animation
            let effectiveFrame: CGRect?
            if let frame = event.listFrame {
                if frame.origin.x >= 0 {
                    // Dock is visible - cache this frame
                    cachedVisibleFrame = frame
                    effectiveFrame = frame
                } else {
                    // Dock reports hidden position (negative x) - use cached visible frame if available
                    Logger.debug("DockFrameMonitor: negative x detected, using cached frame=\(cachedVisibleFrame.map { String(describing: $0) } ?? "nil")")
                    effectiveFrame = cachedVisibleFrame ?? frame
                }
            } else {
                effectiveFrame = nil
            }

            let wasVisible = lastState?.isVisible ?? false
            let next = State(listFrame: effectiveFrame, isVisible: true)

            guard next != lastState else {
                Logger.debug("DockFrameMonitor: state unchanged, skipping")
                return
            }
            lastState = next

            if !wasVisible {
                Logger.debug("DockFrameMonitor: Dock visibility changed to visible")
            }
            Logger.debug("DockFrameMonitor: state changed, dispatching frame=\(next.listFrame.map { String(describing: $0) } ?? "nil")")

            DispatchQueue.main.async { [weak self] in
                self?.onStateChange?(next)
            }
        }
    }
}
