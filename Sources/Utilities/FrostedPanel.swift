/// Rounded frosted-glass floating panel with a faint glass rim: the shared chrome of the Launcher,
/// the Cmd-Tab switcher, Dock menus, and the WinShot chooser.

import AppKit

/// Subclasses add their content to `visualEffectView` and pick a `collectionBehavior`.
class FrostedPanel: NSPanel {
    /// The clipped frosted surface that holds the panel's content.
    let visualEffectView = NSVisualEffectView()

    init(contentRect: NSRect, cornerRadius: CGFloat) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isReleasedWhenClosed = false
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .popUpMenu  // Above zone overlays and the Dock
        isMovable = false
        isMovableByWindowBackground = false

        visualEffectView.material = .hudWindow
        visualEffectView.blendingMode = .behindWindow
        visualEffectView.state = .active
        visualEffectView.wantsLayer = true
        visualEffectView.layer?.cornerRadius = cornerRadius
        visualEffectView.layer?.masksToBounds = true

        let container = NSView()
        container.wantsLayer = true
        for view in [visualEffectView, RimView(cornerRadius: cornerRadius)] {
            container.addSubview(view)
            view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                view.topAnchor.constraint(equalTo: container.topAnchor),
                view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        }
        contentView = container
    }

    /// Key by default so the panel takes typing and arrow keys; hover-only panels override this.
    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        false
    }
}

/// The rim: a dark hairline hugging the edge and a light one just inside it, shaded as if lit from
/// above, so the panel reads as a raised pane even against windows of the same color.
private final class RimView: NSView {
    private let cornerRadius: CGFloat

    init(cornerRadius: CGFloat) {
        self.cornerRadius = cornerRadius
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Decorative only: pointer events go to the content beneath.
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        drawHairline(inset: 0.5, top: NSColor.black.withAlphaComponent(0.06), bottom: NSColor.black.withAlphaComponent(0.15))
        drawHairline(inset: 1.5, top: NSColor.white.withAlphaComponent(0.24), bottom: NSColor.white.withAlphaComponent(0.04))
    }

    /// Draws a one-point line centered `inset` points inside the edge, fading from `top` to `bottom`.
    private func drawHairline(inset: CGFloat, top: NSColor, bottom: NSColor) {
        let line = NSBezierPath(
            roundedRect: bounds.insetBy(dx: inset, dy: inset),
            xRadius: cornerRadius - inset,
            yRadius: cornerRadius - inset
        )
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(cgPath: line.cgPath.copy(strokingWithWidth: 1, lineCap: .butt, lineJoin: .miter, miterLimit: 10)).addClip()
        NSGradient(starting: top, ending: bottom)?.draw(in: bounds, angle: -90)
        NSGraphicsContext.restoreGraphicsState()
    }
}
