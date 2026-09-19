/// Floating panel window for the WinShot snapshot chooser
import AppKit

final class WinShotChooserWindow: FrostedPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 400, height: 180), cornerRadius: 16)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        // The system keeps a movable window on screen after a display reconfiguration, and nothing
        // else repositions an open chooser when its display changes size.
        isMovable = true
        visualEffectView.layer?.backgroundColor = NSColor(calibratedRed: 0.7, green: 0.85, blue: 1.0, alpha: 0.9).cgColor  // Blue tint
    }
}
