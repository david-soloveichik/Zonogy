import AppKit

/// Shared visual style and drawing for the zone resize bar, used by both the
/// static handle view and the smooth drag overlay so they stay in sync.
enum ZoneResizeBarStyle {
    static let thickness: CGFloat = 4.0
    static let color = NSColor.white.withAlphaComponent(0.9)
    static let cornerRadius: CGFloat = 2.0
    static let inset: CGFloat = 4.0

    /// Draw the resize bar centered on the appropriate axis within `bounds`.
    static func draw(in bounds: CGRect, orientation: ZoneLayout.SeparatorOrientation) {
        let drawRect: NSRect
        switch orientation {
        case .vertical:
            let x = (bounds.width - thickness) / 2
            let y = inset
            let height = max(0, bounds.height - (inset * 2))
            drawRect = NSRect(x: x, y: y, width: thickness, height: height)
        case .horizontal:
            let y = (bounds.height - thickness) / 2
            let x = inset
            let width = max(0, bounds.width - (inset * 2))
            drawRect = NSRect(x: x, y: y, width: width, height: thickness)
        }

        color.setFill()
        let path = NSBezierPath(roundedRect: drawRect, xRadius: cornerRadius, yRadius: cornerRadius)
        path.fill()
    }
}
