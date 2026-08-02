import Foundation
import AppKit

/// Display mode for the blue placeholder button (normal close vs UnderCovers put-away).
enum PlaceholderButtonMode {
    case removeZone
    case underCovers
}

/// Placeholder windows should never steal keyboard focus from real apps.
/// Use a non-activating panel subclass so clicks don't bring Zonogy forward.
final class PlaceholderPanel: NSPanel {
    /// Called when a left press on the panel ends: after sendEvent dispatches a mouse-up on
    /// the panel surface, or after a button's tracking loop returns (controls swallow their
    /// mouse-up, so the buttons report completion themselves).
    var onLeftPressEnded: (() -> Void)?

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func makeKeyAndOrderFront(_ sender: Any?) {
        // Panels can be ordered front for visibility without becoming key.
        orderFront(sender)
    }

    override func sendEvent(_ event: NSEvent) {
        super.sendEvent(event)
        if event.type == .leftMouseUp {
            onLeftPressEnded?()
        }
    }
}
