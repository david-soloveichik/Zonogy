/// When the user last pressed a key or a mouse button.
import CoreGraphics
import Foundation

enum LastUserPress {
    /// Seconds since the user last pressed a key or a mouse button (a modifier key pressed alone
    /// does not count). Reads the hardware event state, so events that applications post (Zonogy's
    /// own included) do not count.
    static func secondsAgo() -> TimeInterval {
        [CGEventType.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
            .map { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) }
            .min() ?? .infinity
    }
}
