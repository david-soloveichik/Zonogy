/// Zonogy's own content windows: Preferences and the Welcome tour. Unlike its panels and overlays, they are
/// ordinary windows the user reads and clicks in, so zone resize bars keep clear of them.
import AppKit

enum OwnContentWindows {
    private static let identifiers: Set<NSUserInterfaceItemIdentifier> = [
        PreferencesWindowController.windowIdentifier,
        TourWindowController.windowIdentifier,
    ]

    /// Whether `window` is a content window, or a sheet on one (Add App, a gesture editor, an open panel).
    static func contains(_ window: NSWindow) -> Bool {
        var candidate: NSWindow? = window
        while let current = candidate {
            if let identifier = current.identifier, identifiers.contains(identifier) {
                return true
            }
            candidate = current.sheetParent
        }
        return false
    }

    /// Cocoa frames of the content windows on screen now, and of their sheets, which can reach past them.
    static var visibleFrames: [CGRect] {
        NSApp.windows.filter { $0.isVisible && contains($0) }.map(\.frame)
    }
}
