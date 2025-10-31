import Foundation
import AppKit

/// Utilities for converting between Cocoa coordinates (y:0 at bottom-left, y increases upward)
/// and Screen coordinates (y:0 at top-left, y increases downward) used by Accessibility API.
struct CoordinateConversion {
    /// Convert a Cocoa coordinate frame to screen coordinates.
    /// - Parameters:
    ///   - cocoaFrame: Frame in Cocoa coordinates (origin at bottom-left)
    ///   - screenHeight: The full height of the screen
    /// - Returns: Frame in screen coordinates (origin at top-left)
    static func cocoaToScreen(cocoaFrame: CGRect, screenHeight: CGFloat) -> CGRect {
        let screenY = screenHeight - (cocoaFrame.origin.y + cocoaFrame.height)
        return CGRect(
            x: cocoaFrame.origin.x,
            y: screenY,
            width: cocoaFrame.width,
            height: cocoaFrame.height
        )
    }

    /// Convert a screen coordinate frame to Cocoa coordinates.
    /// - Parameters:
    ///   - screenFrame: Frame in screen coordinates (origin at top-left)
    ///   - screenHeight: The full height of the screen
    /// - Returns: Frame in Cocoa coordinates (origin at bottom-left)
    static func screenToCocoa(screenFrame: CGRect, screenHeight: CGFloat) -> CGRect {
        let cocoaY = screenHeight - (screenFrame.origin.y + screenFrame.height)
        return CGRect(
            x: screenFrame.origin.x,
            y: cocoaY,
            width: screenFrame.width,
            height: screenFrame.height
        )
    }
}
