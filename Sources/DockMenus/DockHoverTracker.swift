/// Debounces hover events to prevent flicker during fast Dock scrubbing.

import Foundation

/// Tracks hover state over Dock items and emits stable hover events with debouncing.
final class DockHoverTracker {
    /// Delay before showing the menu after hover starts (milliseconds).
    private static let showDelayMs: Int = 120

    /// Grace period before hiding the menu after hover ends (milliseconds).
    private static let hideGraceMs: Int = 200

    /// Called when a stable hover event occurs (after debounce delay).
    var onStableHover: ((DockMenuHoverEvent) -> Void)?

    /// Called when hover ends (after grace period).
    var onHoverEnd: (() -> Void)?

    /// The app currently being shown in the menu (if any).
    private(set) var currentlyShowingAppURL: URL?

    /// Pending hover event waiting for debounce delay.
    private var pendingHoverEvent: DockMenuHoverEvent?
    private var pendingShowWorkItem: DispatchWorkItem?

    /// Grace period work item for hiding.
    private var hideGraceWorkItem: DispatchWorkItem?

    /// Receive a raw hover event from DockAXNotificationMonitor.
    /// - Parameter event: The hover event, or nil if cursor left the Dock.
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
        hideGraceWorkItem?.cancel()
        hideGraceWorkItem = nil
        pendingHoverEvent = nil
        currentlyShowingAppURL = nil
    }

    // MARK: - Private

    private func handleHoverStart(_ event: DockMenuHoverEvent) {
        // Cancel any pending hide
        hideGraceWorkItem?.cancel()
        hideGraceWorkItem = nil

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

        // If nothing is showing, no need for grace period
        guard currentlyShowingAppURL != nil else { return }

        // Start grace period for hide (allows cursor to move to panel)
        if hideGraceWorkItem == nil {
            let workItem = DispatchWorkItem { [weak self] in
                self?.hideAfterGrace()
            }
            hideGraceWorkItem = workItem
            DispatchQueue.main.asyncAfter(
                deadline: .now() + .milliseconds(Self.hideGraceMs),
                execute: workItem
            )
        }
    }

    private func showPendingHover() {
        guard let event = pendingHoverEvent else { return }

        pendingShowWorkItem = nil
        pendingHoverEvent = nil
        currentlyShowingAppURL = event.appURL

        Logger.debug("DockHoverTracker: stable hover on \(event.appURL.lastPathComponent)")
        onStableHover?(event)
    }

    private func hideAfterGrace() {
        hideGraceWorkItem = nil
        currentlyShowingAppURL = nil

        Logger.debug("DockHoverTracker: hover ended")
        onHoverEnd?()
    }

    /// Called by panel controller when cursor enters the panel.
    /// Cancels the hide grace period.
    func cursorEnteredPanel() {
        hideGraceWorkItem?.cancel()
        hideGraceWorkItem = nil
    }

    /// Called by panel controller when cursor exits the panel.
    /// Starts the hide grace period.
    func cursorExitedPanel() {
        // Only start grace if we're not hovering over a Dock item
        guard pendingHoverEvent == nil else { return }
        handleHoverEnd()
    }

    /// Called when an action is performed (user clicked something).
    /// Immediately hides without grace period.
    func actionPerformed() {
        pendingShowWorkItem?.cancel()
        pendingShowWorkItem = nil
        hideGraceWorkItem?.cancel()
        hideGraceWorkItem = nil
        pendingHoverEvent = nil
        currentlyShowingAppURL = nil
        onHoverEnd?()
    }
}
