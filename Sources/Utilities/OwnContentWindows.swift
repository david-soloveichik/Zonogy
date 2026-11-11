/// Zonogy's own content windows: Preferences and the Welcome tour. Unlike its panels and overlays, they are
/// ordinary windows the user reads and clicks in, so zone resize bars keep off their display while one of
/// them is focused.
import AppKit

enum OwnContentWindows {
    private static let identifiers: Set<NSUserInterfaceItemIdentifier> = [
        PreferencesWindowController.windowIdentifier,
        TourWindowController.windowIdentifier,
    ]

    static func contains(_ window: NSWindow) -> Bool {
        window.identifier.map(identifiers.contains) ?? false
    }
}
