import AppKit

/// A large translucent blue circle drawn at the center of the tiling zone currently selected by
/// Control-Command zone navigation — or, for a selected floating zone, the upper half of that
/// circle resting on the screen's bottom edge over the floating-zone bar. It is a non-interactive
/// floating panel shown only while the gesture is in progress and torn down when the gesture
/// commits or cancels. Mirrors `OccupiedZoneTargetOverlay`'s floating-panel approach.
///
/// Both modes render the same full circle (a max-radius rounded square). The half-circle mode uses
/// a half-height panel with the circle's lower half hanging below the panel's bottom edge: the
/// window surface clips it, leaving an exact dome. (Shaping the view itself with `cornerRadius`
/// cannot produce a semicircle — Core Animation clamps the radius to half the layer's smaller
/// dimension, which flattens the sides.)
final class ZoneNavigationDotOverlay {
    private static let fillColor = NSColor.systemBlue.withAlphaComponent(0.45)
    /// One fixed circle diameter everywhere, independent of zone and screen dimensions.
    private static let circleDiameter: CGFloat = 170

    private var panel: NSPanel?
    private var dotView: NSView?

    /// Show (or move) the circle centered within `cocoaFrame` (a tiling zone frame).
    func show(centeredIn cocoaFrame: CGRect) {
        let diameter = Self.circleDiameter
        let panelFrame = CGRect(
            x: cocoaFrame.midX - diameter / 2,
            y: cocoaFrame.midY - diameter / 2,
            width: diameter,
            height: diameter
        )
        apply(panelFrame: panelFrame, circleOrigin: .zero, diameter: diameter)
    }

    /// Show (or move) the upper half of the circle with its flat edge on the screen's bottom edge,
    /// centered on the floating zone's bar. `screenCocoaFrame` anchors that flat edge on the true
    /// screen bottom.
    func showHalfCircle(onBar barCocoaFrame: CGRect, screenCocoaFrame: CGRect) {
        let diameter = Self.circleDiameter
        // The bar's canonical frame can overhang past the screen edge (edge-pinned cursor hits);
        // the dome's flat edge belongs on the screen bottom itself.
        let panelFrame = CGRect(
            x: barCocoaFrame.midX - diameter / 2,
            y: screenCocoaFrame.minY,
            width: diameter,
            height: diameter / 2
        )
        // The circle's lower half sits below the panel; the window edge clips it into a dome.
        apply(panelFrame: panelFrame, circleOrigin: CGPoint(x: 0, y: -diameter / 2), diameter: diameter)
    }

    /// Tear down the overlay (the gesture committed or was cancelled).
    func hide() {
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
        dotView = nil
    }

    private func apply(panelFrame: CGRect, circleOrigin: CGPoint, diameter: CGFloat) {
        let panel = ensurePanel()
        panel.setFrame(panelFrame, display: true)
        dotView?.frame = CGRect(x: circleOrigin.x, y: circleOrigin.y, width: diameter, height: diameter)
        dotView?.layer?.cornerRadius = diameter / 2
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
        // Above the Launcher (.popUpMenu): the gesture runs while the Launcher is open, and the
        // circle must stay visible over it (as well as over the normal-level windows beneath it).
        p.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.isReleasedWhenClosed = false
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .stationary]

        let view = NSView(frame: .zero)
        view.wantsLayer = true
        view.layer?.backgroundColor = Self.fillColor.cgColor
        p.contentView?.addSubview(view)
        p.orderFront(nil)

        self.panel = p
        self.dotView = view
        return p
    }

    deinit {
        hide()
    }
}
