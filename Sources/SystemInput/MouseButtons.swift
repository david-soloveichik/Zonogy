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
}

