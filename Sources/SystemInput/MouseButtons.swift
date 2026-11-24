import AppKit
import ApplicationServices

/// Global mouse button state helpers.
///
/// Uses a fast local event state check when available, and falls back to the
/// combined session state so we can reason about gestures while Zonogy is not
/// the frontmost app.
enum MouseButtons {
    static func isLeftMouseButtonDown() -> Bool {
        if NSEvent.pressedMouseButtons & 0x1 != 0 {
            return true
        }
        return CGEventSource.buttonState(.combinedSessionState, button: .left)
    }

    static func secondsSinceLastLeftMouseUp() -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .leftMouseUp)
    }

    /// The pointer as it was at one moment, so a decision that must first wait on a slow call
    /// still judges the pointer as it was before that call.
    struct Snapshot {
        /// Cursor location in Cocoa global coordinates.
        let location: CGPoint
        let isLeftButtonDown: Bool
        let secondsSinceLeftButtonUp: TimeInterval
    }

    static func snapshot() -> Snapshot {
        Snapshot(
            location: NSEvent.mouseLocation,
            isLeftButtonDown: isLeftMouseButtonDown(),
            secondsSinceLeftButtonUp: secondsSinceLastLeftMouseUp()
        )
    }
}

