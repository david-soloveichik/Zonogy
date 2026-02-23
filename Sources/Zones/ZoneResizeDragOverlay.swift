import AppKit

/// Lightweight drag overlay that tracks raw mouse deltas for smooth visual feedback
/// during zone resize drags, independent of the heavy layout/AX sync pipeline.
final class ZoneResizeDragOverlay {

    private final class OverlayPanel: NSPanel {
        init(frame: NSRect) {
            super.init(
                contentRect: frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            isReleasedWhenClosed = false
            isFloatingPanel = true
            becomesKeyOnlyIfNeeded = false
            ignoresMouseEvents = true
            isOpaque = false
            backgroundColor = .clear
            hasShadow = false
            level = .floating + 1 // Above handle windows
            collectionBehavior = [
                .moveToActiveSpace,
                .transient,
                .ignoresCycle,
                .fullScreenAuxiliary
            ]
        }

        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    private final class OverlayView: NSView {
        let orientation: ZoneLayout.SeparatorOrientation

        init(frame: NSRect, orientation: ZoneLayout.SeparatorOrientation) {
            self.orientation = orientation
            super.init(frame: frame)
            wantsLayer = true
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func draw(_ dirtyRect: NSRect) {
            ZoneResizeBarStyle.draw(in: bounds, orientation: orientation)
        }
    }

    private var overlayPanel: OverlayPanel?
    private var activeOrientation: ZoneLayout.SeparatorOrientation?
    /// Allowed range for the overlay origin on the movement axis (Cocoa coordinates).
    private var movementRange: ClosedRange<CGFloat>?

    /// Show the overlay at the given Cocoa frame (matching the handle window's current frame).
    /// `movementRange` clamps the overlay origin on its movement axis so it cannot
    /// exceed the zone layout's minimum size ratios.
    func show(cocoaFrame: CGRect, orientation: ZoneLayout.SeparatorOrientation, movementRange: ClosedRange<CGFloat>) {
        hide()

        let panel = OverlayPanel(frame: cocoaFrame)
        let view = OverlayView(
            frame: NSRect(origin: .zero, size: cocoaFrame.size),
            orientation: orientation
        )
        view.autoresizingMask = [.width, .height]
        panel.contentView = view
        panel.orderFrontRegardless()

        overlayPanel = panel
        activeOrientation = orientation
        self.movementRange = movementRange
    }

    /// Move the overlay by raw event deltas. Cocoa coordinates: +dx = right, +dy = up.
    /// Movement is constrained to the separator's axis and clamped to the movement range
    /// so the bar cannot visually exceed the minimum zone size.
    /// Returns the actual delta applied after clamping (Cocoa coordinates).
    func moveByDelta(dx: CGFloat, dy: CGFloat) -> CGPoint {
        guard let panel = overlayPanel, let orientation = activeOrientation else { return .zero }
        let origin = panel.frame.origin
        switch orientation {
        case .vertical:
            var newX = origin.x + dx
            if let range = movementRange {
                newX = min(max(newX, range.lowerBound), range.upperBound)
            }
            panel.setFrameOrigin(NSPoint(x: newX, y: origin.y))
            return CGPoint(x: newX - origin.x, y: 0)
        case .horizontal:
            var newY = origin.y + dy
            if let range = movementRange {
                newY = min(max(newY, range.lowerBound), range.upperBound)
            }
            panel.setFrameOrigin(NSPoint(x: origin.x, y: newY))
            return CGPoint(x: 0, y: newY - origin.y)
        }
    }

    /// Hide and tear down the overlay.
    func hide() {
        if let panel = overlayPanel {
            panel.orderOut(nil)
            panel.close()
            overlayPanel = nil
        }
        activeOrientation = nil
        movementRange = nil
    }
}
