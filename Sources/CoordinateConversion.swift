import Foundation
import AppKit

/// Utilities for converting between Cocoa coordinates (origin at bottom-left, y increases upward),
/// screen-local coordinates (origin at a screen's top-left, y increases downward), and
/// accessibility coordinates (origin at the primary screen's top-left, y increases downward).
struct CoordinateConversion {
    /// Convert a Cocoa frame (global, origin bottom-left) into coordinates relative to the
    /// specified screen's top-left corner.
    /// - Parameters:
    ///   - cocoaFrame: Frame expressed in Cocoa coordinates.
    ///   - screenBounds: The full bounds of the screen in Cocoa coordinates.
    static func cocoaToScreen(cocoaFrame: CGRect, screenBounds: CGRect) -> CGRect {
        let screenTop = screenBounds.origin.y + screenBounds.height
        let screenX = cocoaFrame.origin.x - screenBounds.origin.x
        let screenY = screenTop - (cocoaFrame.origin.y + cocoaFrame.height)
        return CGRect(x: screenX, y: screenY, width: cocoaFrame.width, height: cocoaFrame.height)
    }

    /// Convert a screen-local frame (origin at screen top-left) to Cocoa coordinates.
    /// - Parameters:
    ///   - screenFrame: Frame in screen-local coordinates.
    ///   - screenBounds: The full bounds of the screen in Cocoa coordinates.
    static func screenToCocoa(screenFrame: CGRect, screenBounds: CGRect) -> CGRect {
        let screenTop = screenBounds.origin.y + screenBounds.height
        let cocoaX = screenBounds.origin.x + screenFrame.origin.x
        let cocoaY = screenTop - (screenFrame.origin.y + screenFrame.height)
        return CGRect(x: cocoaX, y: cocoaY, width: screenFrame.width, height: screenFrame.height)
    }

    /// Convert a Cocoa frame to Accessibility coordinates (origin at the primary screen's top-left).
    /// - Parameters:
    ///   - cocoaFrame: Frame in Cocoa coordinates.
    ///   - primaryScreenBounds: Primary screen bounds in Cocoa coordinates (used as reference).
    static func cocoaToAccessibility(cocoaFrame: CGRect, primaryScreenBounds: CGRect) -> CGRect {
        let primaryTop = primaryScreenBounds.origin.y + primaryScreenBounds.height
        let accessibilityY = primaryTop - (cocoaFrame.origin.y + cocoaFrame.height)
        return CGRect(x: cocoaFrame.origin.x, y: accessibilityY, width: cocoaFrame.width, height: cocoaFrame.height)
    }

    /// Convert an Accessibility frame back to Cocoa coordinates.
    /// - Parameters:
    ///   - accessibilityFrame: Frame in Accessibility coordinates (origin at primary screen top-left).
    ///   - primaryScreenBounds: Primary screen bounds in Cocoa coordinates (used as reference).
    static func accessibilityToCocoa(accessibilityFrame: CGRect, primaryScreenBounds: CGRect) -> CGRect {
        let primaryTop = primaryScreenBounds.origin.y + primaryScreenBounds.height
        let cocoaY = primaryTop - (accessibilityFrame.origin.y + accessibilityFrame.height)
        return CGRect(x: accessibilityFrame.origin.x, y: cocoaY, width: accessibilityFrame.width, height: accessibilityFrame.height)
    }
}
