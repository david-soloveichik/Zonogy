import AppKit
import QuartzCore

/// Briefly flashes a blueish border around a zone frame to confirm a
/// Control+Command click that targets an occupied zone (where there is no
/// placeholder to flash).  The overlay fades out automatically and is
/// completely non-interactive.
final class ZoneFlashOverlay {
    private var panel: NSPanel?

    /// Show a flashing blue border at the given Cocoa-coordinate frame.
    func flash(at cocoaFrame: CGRect) {
        dismiss()

        let p = NSPanel(
            contentRect: cocoaFrame,
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        p.isFloatingPanel = true
        p.level = .floating
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.isReleasedWhenClosed = false
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .stationary]
        p.setFrame(cocoaFrame, display: false)
        p.alphaValue = 1.0

        let borderView = NSView(frame: CGRect(origin: .zero, size: cocoaFrame.size))
        borderView.wantsLayer = true
        if let layer = borderView.layer {
            layer.cornerRadius = 12
            if #available(macOS 10.15, *) { layer.cornerCurve = .continuous }
            layer.borderWidth = 5.5
            layer.borderColor = NSColor.systemBlue.withAlphaComponent(0.88).cgColor
            layer.backgroundColor = CGColor.clear
        }
        p.contentView = borderView
        p.orderFront(nil)
        self.panel = p

        // Fade the entire overlay out after a brief pause.
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.45
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            p.animator().alphaValue = 0.0
        }, completionHandler: { [weak self] in
            self?.dismiss()
        })
    }

    private func dismiss() {
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
    }
}
