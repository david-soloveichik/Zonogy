import AppKit

/// Describes a single display and provides coordinate conversion helpers.
struct ScreenDescriptor {
    let displayId: CGDirectDisplayID
    let localizedName: String
    let cocoaBounds: CGRect
    let visibleCocoaBounds: CGRect
    private let primaryBounds: CGRect

    init(displayId: CGDirectDisplayID, localizedName: String, cocoaBounds: CGRect, visibleCocoaBounds: CGRect, primaryBounds: CGRect) {
        self.displayId = displayId
        self.localizedName = localizedName
        self.cocoaBounds = cocoaBounds
        self.visibleCocoaBounds = visibleCocoaBounds
        self.primaryBounds = primaryBounds
    }

    /// Visible bounds expressed in screen-local coordinates (origin at top-left of the display).
    var visibleScreenBounds: CGRect {
        CoordinateConversion.cocoaToScreen(cocoaFrame: visibleCocoaBounds, screenBounds: cocoaBounds)
    }

    /// Convert a Cocoa frame into screen-local coordinates.
    func cocoaToScreen(_ cocoaFrame: CGRect) -> CGRect {
        CoordinateConversion.cocoaToScreen(cocoaFrame: cocoaFrame, screenBounds: cocoaBounds)
    }

    /// Convert a screen-local frame into Cocoa coordinates.
    func screenToCocoa(_ screenFrame: CGRect) -> CGRect {
        CoordinateConversion.screenToCocoa(screenFrame: screenFrame, screenBounds: cocoaBounds)
    }

    /// Convert a screen-local frame into Accessibility coordinates (origin at primary screen top-left).
    func screenToAccessibility(_ screenFrame: CGRect) -> CGRect {
        let cocoaFrame = screenToCocoa(screenFrame)
        return CoordinateConversion.cocoaToAccessibility(cocoaFrame: cocoaFrame, primaryScreenBounds: primaryBounds)
    }

    /// Convert an Accessibility frame into screen-local coordinates.
    func accessibilityToScreen(_ accessibilityFrame: CGRect) -> CGRect {
        let cocoaFrame = CoordinateConversion.accessibilityToCocoa(accessibilityFrame: accessibilityFrame, primaryScreenBounds: primaryBounds)
        return cocoaToScreen(cocoaFrame)
    }
}
