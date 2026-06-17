import AppKit
import Foundation
import QuartzCore

/// Shared visual tokens for the targeted-zone border flash. Used by both the occupied-zone overlay
/// (`ZoneFlashOverlay`, below) and the empty-zone placeholder border animation
/// (`PlaceholderContentView.flashBorder`) so the two stay in lockstep.
enum ZoneFlashStyle {
    /// Vivid blue the border starts at when the flash fires.
    static let color = NSColor.systemBlue.withAlphaComponent(0.88)
    /// Border width the flash starts at before settling back to the resting width.
    static let borderWidth: CGFloat = 9.0
    /// How long the flash takes to fade to its resting state.
    static let duration: CFTimeInterval = 0.45
    /// Easing shared by both flash animations.
    static var timing: CAMediaTimingFunction { CAMediaTimingFunction(name: .easeOut) }
}

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
            layer.cornerRadius = isTahoe ? 20 : windowCornerRadius
            if #available(macOS 10.15, *) { layer.cornerCurve = .continuous }
            layer.borderWidth = ZoneFlashStyle.borderWidth
            layer.borderColor = ZoneFlashStyle.color.cgColor
            layer.backgroundColor = CGColor.clear
        }
        p.contentView = borderView
        p.orderFront(nil)
        self.panel = p

        // Fade the entire overlay out after a brief pause, then tear down *this* panel. We capture
        // `p` directly rather than calling `dismiss()` (which acts on `self.panel`): a newer flash
        // may have already replaced `self.panel`, and dismissing that would cut the newer flash
        // short. This happens during rapid target changes — e.g. holding/tapping the keyboard
        // navigation shortcut faster than the fade duration — where each flash's completion would
        // otherwise dismiss the next flash's panel right after it appears.
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = ZoneFlashStyle.duration
            ctx.timingFunction = ZoneFlashStyle.timing
            p.animator().alphaValue = 0.0
        }, completionHandler: { [weak self] in
            p.orderOut(nil)
            p.close()
            if self?.panel === p {
                self?.panel = nil
            }
        })
    }

    private func dismiss() {
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
    }
}
