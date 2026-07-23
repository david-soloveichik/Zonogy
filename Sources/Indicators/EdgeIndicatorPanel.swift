import AppKit

/// Shared non-activating, status-bar-level panel for edge-mounted zone indicators.
final class EdgeIndicatorPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        level = .statusBar
        collectionBehavior = [.moveToActiveSpace, .transient, .ignoresCycle]
        ignoresMouseEvents = false
        hasShadow = false
    }
}
