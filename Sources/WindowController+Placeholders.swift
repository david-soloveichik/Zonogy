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
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func makeKeyAndOrderFront(_ sender: Any?) {
        // Panels can be ordered front for visibility without becoming key.
        orderFront(sender)
    }
}
