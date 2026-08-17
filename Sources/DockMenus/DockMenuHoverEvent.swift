/// Data model representing a hover event on a running app's Dock icon.

import Foundation

/// Represents a hover event on a running application's Dock icon.
struct DockMenuHoverEvent: Equatable {
    /// URL to the application bundle (e.g., file:///Applications/Safari.app).
    let appURL: URL

    /// The application's bundle identifier (e.g., "com.apple.Safari").
    let bundleIdentifier: String

    /// Accessibility frame of the hovered Dock item (screen coordinates, y:0 at top).
    let itemFrame: CGRect
}
