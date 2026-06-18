import AppKit
import Foundation
import QuartzCore

/// Shared visual tokens for the targeted-zone border flash. Used by both the occupied-zone overlay
/// (`OccupiedZoneTargetOverlay`, below) and the empty-zone placeholder border animation
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

/// Draws a persistent blue border over a targeted *occupied* tiling zone — the occupied-zone analog of
/// the highlighted placeholder border shown for a targeted empty zone. An occupied zone has no
/// placeholder, so this floats a non-interactive bordered panel over the zone frame, deliberately drawn
/// on top of the occupant window, so the user can see which zone the next window will land in.
///
/// Only one zone is targeted at a time, so a single panel suffices. `show(at:)`/`hide()` track the
/// border's visibility (driven by the indicator refresh); `flash(at:)` pulses the border on a target
/// change and settles into the resting border — mirroring the placeholder's persistent border plus its
/// `flashBorder` animation.
final class OccupiedZoneTargetOverlay {
    /// Resting border once any flash settles. Brighter and a touch thicker than the empty-zone
    /// placeholder border so it stays legible when drawn over arbitrary window content.
    private static let restingColor = NSColor.systemBlue.withAlphaComponent(0.80)
    private static let restingWidth: CGFloat = 4.0

    private var panel: NSPanel?
    private var borderView: NSView?

    /// Show (or move) the persistent border at the given Cocoa-coordinate frame.
    func show(at cocoaFrame: CGRect) {
        present(at: cocoaFrame)
    }

    /// Pulse the border to confirm a target change, settling into the resting border. Ensures the
    /// panel is present at `cocoaFrame` first so the flash is robust even if it fires before a refresh.
    func flash(at cocoaFrame: CGRect) {
        guard let layer = present(at: cocoaFrame)?.layer else { return }

        let colorAnim = CABasicAnimation(keyPath: "borderColor")
        colorAnim.fromValue = ZoneFlashStyle.color.cgColor
        colorAnim.toValue = Self.restingColor.cgColor
        colorAnim.duration = ZoneFlashStyle.duration
        colorAnim.timingFunction = ZoneFlashStyle.timing
        layer.add(colorAnim, forKey: "borderColorFlash")

        let widthAnim = CABasicAnimation(keyPath: "borderWidth")
        widthAnim.fromValue = ZoneFlashStyle.borderWidth
        widthAnim.toValue = Self.restingWidth
        widthAnim.duration = ZoneFlashStyle.duration
        widthAnim.timingFunction = ZoneFlashStyle.timing
        layer.add(widthAnim, forKey: "borderWidthFlash")
    }

    /// Tear down the overlay (the target is no longer an occupied tiling zone).
    func hide() {
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
        borderView = nil
    }

    /// Lazily create the bordered panel, move it to `cocoaFrame`, and return its border view.
    @discardableResult
    private func present(at cocoaFrame: CGRect) -> NSView? {
        let panel = ensurePanel()
        panel.setFrame(cocoaFrame, display: true)
        return borderView
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
        // Floating level keeps the border above the (normal-level) occupant window so it stays visible
        // even when that window is frontmost — matching the user's intent to see the destination zone.
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
            layer.cornerRadius = isTahoe ? 20 : windowCornerRadius
            if #available(macOS 10.15, *) { layer.cornerCurve = .continuous }
            layer.borderWidth = Self.restingWidth
            layer.borderColor = Self.restingColor.cgColor
            layer.backgroundColor = CGColor.clear
        }
        p.contentView = view
        // Order front once on creation; the floating level keeps it above the occupant window without
        // re-raising on every refresh (which would also fight choosers presented over the same zone).
        p.orderFront(nil)

        self.panel = p
        self.borderView = view
        return p
    }
}
