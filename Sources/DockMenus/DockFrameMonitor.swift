import Foundation
import AppKit
import ApplicationServices

/// Tracks where the Dock is (display, edge, revealed frame) and whether it is visible, from Dock
/// accessibility events, and emits state updates.
final class DockFrameMonitor {
    struct State: Equatable {
        /// Where the Dock is and its fully revealed frame; nil until the Dock has been located.
        var location: DockLocation?
        /// Whether the Dock is considered visible (vs hidden due to autohide).
        var isVisible: Bool = false
    }

    var onStateChange: ((State) -> Void)?

    /// Called when hover changes: a running app's Dock icon (event), or a non-running app/non-app item (nil).
    /// Note: nil does NOT reliably indicate cursor left the Dock. See SPECIFICATION-DOCKMENUS.md.
    var onAppHover: ((DockMenuHoverEvent?) -> Void)?

    private var lastState: State?
    private var axNotificationMonitor: DockAXNotificationMonitor?

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

    /// Re-discovers and re-attaches the underlying Dock AX observer. Called when the Dock may have
    /// rebuilt its accessibility hierarchy (wake / display reconfiguration). No-op if monitoring
    /// isn't active.
    func reestablishObserver(reason: String) {
        axNotificationMonitor?.reestablish(reason: reason)
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

        guard event.notification == (kAXSelectedChildrenChangedNotification as String) else { return }

        // DockLocation turns the AXList frame (sampled at any point of the auto-hide slide, on any
        // display) into the Dock's revealed frame. Keep the last location when a frame cannot be
        // placed (e.g. mid display reconfiguration) rather than leaving click interception frameless.
        let location = event.listFrame.flatMap { listFrame in
            DockLocation.resolve(
                listFrame: listFrame,
                itemFrame: event.itemFrame,
                orientation: event.orientation ?? .horizontal,
                displays: Self.currentDisplays()
            )
        }
        if location == nil {
            Logger.debug("DockFrameMonitor: could not locate the Dock from frame; keeping last location")
        }

        let wasVisible = lastState?.isVisible ?? false
        let next = State(location: location ?? lastState?.location, isVisible: true)

        guard next != lastState else {
            Logger.debug("DockFrameMonitor: state unchanged, skipping")
            return
        }
        lastState = next

        if !wasVisible {
            Logger.debug("DockFrameMonitor: Dock visibility changed to visible")
        }
        Logger.debug("DockFrameMonitor: state changed, dispatching frame=\(next.location.map { String(describing: $0.revealedFrame) } ?? "nil")")

        DispatchQueue.main.async { [weak self] in
            self?.onStateChange?(next)
        }
    }

    /// The connected displays in accessibility coordinates.
    private static func currentDisplays() -> [DockLocation.Display] {
        let screens = NSScreen.screens
        guard let primaryBounds = screens.first?.frame else { return [] }
        return screens.map { screen in
            DockLocation.Display(
                frame: CoordinateConversion.cocoaToAccessibility(cocoaFrame: screen.frame, primaryScreenBounds: primaryBounds),
                visibleFrame: CoordinateConversion.cocoaToAccessibility(cocoaFrame: screen.visibleFrame, primaryScreenBounds: primaryBounds)
            )
        }
    }
}
