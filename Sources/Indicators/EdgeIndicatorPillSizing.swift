import AppKit
import CoreGraphics

/// Shared sizing and window-level constants for edge-mounted indicator pills (floating targeting + add-zone).
enum EdgeIndicatorPillSizing {
    static let baseThickness: CGFloat = 6
    static let hoverThickness: CGFloat = 10
    static let dragThickness: CGFloat = 12
}

/// Window levels for edge-mounted indicator pills. The pills sit just above the Dock so a Dock
/// sharing their screen edge cannot capture their hovers, clicks, or drops. The raised level
/// additionally lifts an expanded or pulsing pill above status-level UI so it reads clearly.
enum EdgeIndicatorWindowLevel {
    /// One step above the Dock, still below the menu bar.
    static let resting = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)
    static let raised = NSWindow.Level.statusBar
}
