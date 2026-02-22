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

        private let barThickness: CGFloat = 4.0
        private let barColor = NSColor.white.withAlphaComponent(0.9)
        private let barCornerRadius: CGFloat = 2.0
        private let barInset: CGFloat = 4.0

        init(frame: NSRect, orientation: ZoneLayout.SeparatorOrientation) {
            self.orientation = orientation
            super.init(frame: frame)
            wantsLayer = true
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func draw(_ dirtyRect: NSRect) {
            let drawRect: NSRect
            switch orientation {
            case .vertical:
                let x = (bounds.width - barThickness) / 2
                let y = barInset
                let height = max(0, bounds.height - (barInset * 2))
                drawRect = NSRect(x: x, y: y, width: barThickness, height: height)
            case .horizontal:
                let y = (bounds.height - barThickness) / 2
                let x = barInset
                let width = max(0, bounds.width - (barInset * 2))
                drawRect = NSRect(x: x, y: y, width: width, height: barThickness)
            }

            barColor.setFill()
            let path = NSBezierPath(roundedRect: drawRect, xRadius: barCornerRadius, yRadius: barCornerRadius)
            path.fill()
        }
    }

    private var overlayPanel: OverlayPanel?
    private var activeOrientation: ZoneLayout.SeparatorOrientation?

    /// Show the overlay at the given Cocoa frame (matching the handle window's current frame).
    func show(cocoaFrame: CGRect, orientation: ZoneLayout.SeparatorOrientation) {
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
    }

    /// Move the overlay by raw event deltas. Cocoa coordinates: +dx = right, +dy = up.
    /// Movement is constrained to the separator's axis: vertical bars move left/right only,
    /// horizontal bars move up/down only.
    func moveByDelta(dx: CGFloat, dy: CGFloat) {
        guard let panel = overlayPanel, let orientation = activeOrientation else { return }
        let origin = panel.frame.origin
        switch orientation {
        case .vertical:
            // Vertical separator divides left/right zones — moves only horizontally.
            panel.setFrameOrigin(NSPoint(x: origin.x + dx, y: origin.y))
        case .horizontal:
            // Horizontal separator divides top/bottom zones — moves only vertically.
            panel.setFrameOrigin(NSPoint(x: origin.x, y: origin.y + dy))
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
    }
}
