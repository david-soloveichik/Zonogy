/// Debounces hover events to prevent flicker during fast Dock scrubbing.

import Foundation

/// Tracks hover state over Dock items and emits stable hover events with debouncing.
final class DockHoverTracker {
    /// Delay before showing the menu after hover starts (milliseconds).
    private static let showDelayMs: Int = 120

    /// Called when a stable hover event occurs (after debounce delay).
    var onStableHover: ((DockMenuHoverEvent) -> Void)?

    /// The app currently being shown in the menu (if any).
    private(set) var currentlyShowingAppURL: URL?

    /// Pending hover event waiting for debounce delay.
    private var pendingHoverEvent: DockMenuHoverEvent?
    private var pendingShowWorkItem: DispatchWorkItem?

    /// Receive a raw hover event from DockAXNotificationMonitor.
    /// - Parameter event: The hover event, or nil if hovering a non-running app or non-app item.
    ///   Note: nil does NOT reliably indicate cursor left the Dock. See SPECIFICATION-DOCKMENUS.md.
    func handleHoverEvent(_ event: DockMenuHoverEvent?) {
        if let event {
            handleHoverStart(event)
        } else {
            handleHoverEnd()
        }
    }

    /// Cancel all pending work items and reset state.
    func reset() {
        pendingShowWorkItem?.cancel()
        pendingShowWorkItem = nil
        pendingHoverEvent = nil
        currentlyShowingAppURL = nil
    }

    // MARK: - Private

    private func handleHoverStart(_ event: DockMenuHoverEvent) {
        // If we're already showing this app, update the event but don't reset debounce
        if currentlyShowingAppURL == event.appURL {
            // Already showing this app - just update position if needed
            // (Could add onPositionUpdate callback here if panel needs repositioning)
            return
        }

        // If we're hovering a different app, cancel pending show and restart debounce
        if pendingHoverEvent?.appURL != event.appURL {
            pendingShowWorkItem?.cancel()
            pendingShowWorkItem = nil
        }

        pendingHoverEvent = event

        // Start debounce timer if not already pending
        if pendingShowWorkItem == nil {
            let workItem = DispatchWorkItem { [weak self] in
                self?.showPendingHover()
            }
            pendingShowWorkItem = workItem
            DispatchQueue.main.asyncAfter(
                deadline: .now() + .milliseconds(Self.showDelayMs),
                execute: workItem
            )
        }
    }

    private func handleHoverEnd() {
        // Cancel pending show
        pendingShowWorkItem?.cancel()
        pendingShowWorkItem = nil
        pendingHoverEvent = nil
    }

    private func showPendingHover() {
        guard let event = pendingHoverEvent else { return }

        pendingShowWorkItem = nil
        pendingHoverEvent = nil

        Logger.debug("DockHoverTracker: stable hover on \(event.appURL.lastPathComponent)")
        onStableHover?(event)
    }

    func menuDidShow(appURL: URL) {
        currentlyShowingAppURL = appURL
    }
}
