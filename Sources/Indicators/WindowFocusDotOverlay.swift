import AppKit

/// A large translucent blue dot drawn at the center of the window currently marked by Control-Command
/// window-focus navigation. It is a non-interactive floating panel shown only while the gesture is in
/// progress and torn down when the gesture commits or cancels. Mirrors `OccupiedZoneTargetOverlay`'s
/// floating-panel approach.
final class WindowFocusDotOverlay {
    private static let fillColor = NSColor.systemBlue.withAlphaComponent(0.45)
    /// Dot diameter is this fraction of the window's shorter side, clamped to the range below.
    private static let diameterFraction: CGFloat = 0.32
    private static let minDiameter: CGFloat = 70
    private static let maxDiameter: CGFloat = 170

    private var panel: NSPanel?
    private var dotView: NSView?

    /// Show (or move) the dot centered within `windowCocoaFrame`, sizing it relative to the window.
    func show(centeredIn windowCocoaFrame: CGRect) {
        let shorterSide = min(windowCocoaFrame.width, windowCocoaFrame.height)
        let diameter = max(Self.minDiameter, min(shorterSide * Self.diameterFraction, Self.maxDiameter))
        let frame = CGRect(
            x: windowCocoaFrame.midX - diameter / 2,
            y: windowCocoaFrame.midY - diameter / 2,
            width: diameter,
            height: diameter
        )

        let panel = ensurePanel()
        panel.setFrame(frame, display: true)
        dotView?.layer?.cornerRadius = diameter / 2
    }

    /// Tear down the overlay (the gesture committed or was cancelled).
    func hide() {
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
        dotView = nil
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }

        let p = NSPanel(
            contentRect: .zero,
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        p.isFloatingPanel = true
        // Floating level keeps the dot above the (normal-level) windows it is marking.
        p.level = .floating
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.isReleasedWhenClosed = false
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .stationary]

        let view = NSView(frame: .zero)
        view.autoresizingMask = [.width, .height]
        view.wantsLayer = true
        if let layer = view.layer {
            layer.backgroundColor = Self.fillColor.cgColor
            if #available(macOS 10.15, *) { layer.cornerCurve = .continuous }
        }
        p.contentView = view
        p.orderFront(nil)

        self.panel = p
        self.dotView = view
        return p
    }

    deinit {
        hide()
    }
}
