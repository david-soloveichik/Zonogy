/// Floating panel window for the WinShot snapshot chooser
import AppKit

final class WinShotChooserWindow: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 180),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isReleasedWhenClosed = false
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        isOpaque = false
        backgroundColor = NSColor.black.withAlphaComponent(0.85)
        hasShadow = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    }

    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        false
    }

    /// Position the window centered on the specified screen
    func centerOnScreen(_ screenId: CGDirectDisplayID) {
        guard let screen = NSScreen.screens.first(where: { screen in
            guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return false
            }
            return CGDirectDisplayID(screenNumber.uint32Value) == screenId
        }) else {
            // Fall back to main screen
            if let mainScreen = NSScreen.main {
                center(on: mainScreen)
            }
            return
        }

        center(on: screen)
    }

    private func center(on screen: NSScreen) {
        let screenFrame = screen.visibleFrame
        let windowSize = frame.size
        let x = screenFrame.midX - windowSize.width / 2
        let y = screenFrame.midY - windowSize.height / 2
        setFrameOrigin(NSPoint(x: x, y: y))
    }
}
