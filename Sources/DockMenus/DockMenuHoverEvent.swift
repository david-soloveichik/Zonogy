/// Data model representing a hover event on a running app's Dock icon.

import Foundation

/// Dock orientation determines panel positioning relative to the Dock icon.
enum DockOrientation {
    /// Dock is on the bottom of the screen (horizontal layout).
    case horizontal
    /// Dock is on the left or right of the screen (vertical layout).
    case vertical
}

/// Represents a hover event on a running application's Dock icon.
struct DockMenuHoverEvent: Equatable {
    /// URL to the application bundle (e.g., file:///Applications/Safari.app).
    let appURL: URL

    /// The application's bundle identifier (e.g., "com.apple.Safari").
    let bundleIdentifier: String

    /// Accessibility frame of the hovered Dock item (screen coordinates, y:0 at top).
    let itemFrame: CGRect

    /// Accessibility frame of the Dock's AXList element (screen coordinates).
    let listFrame: CGRect

    /// Orientation of the Dock (horizontal for bottom, vertical for left/right).
    let dockOrientation: DockOrientation
}
