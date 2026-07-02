import AppKit

/// A clickable pictogram of one zone layout style for the General preferences tab:
/// a mini screen showing the style's maximum zone arrangement and its add-zone bar edge(s).
final class ZoneLayoutStyleOptionView: NSControl {
    let style: ZoneLayoutStyle

    var isSelected: Bool = false {
        didSet {
            if isSelected != oldValue {
                needsDisplay = true
            }
        }
    }

    var onSelect: ((ZoneLayoutStyle) -> Void)?

    private let pictogramSize = NSSize(width: 132, height: 88)

    init(style: ZoneLayoutStyle) {
        self.style = style
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityRole(.radioButton)
        setAccessibilityElement(true)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        pictogramSize
    }

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        onSelect?(style)
    }

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " || event.keyCode == 36 {
            onSelect?(style)
        } else {
            super.keyDown(with: event)
        }
    }

    override func accessibilityPerformPress() -> Bool {
        onSelect?(style)
        return true
    }

    override func accessibilityValue() -> Any? {
        isSelected ? 1 : 0
    }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: 8, yRadius: 8).fill()
    }

    override var focusRingMaskBounds: NSRect {
        bounds
    }

    override func draw(_ dirtyRect: NSRect) {
        let accent = NSColor.controlAccentColor

        // Card background and selection ring
        let cardRect = bounds.insetBy(dx: 1.5, dy: 1.5)
        let card = NSBezierPath(roundedRect: cardRect, xRadius: 8, yRadius: 8)
        if isSelected {
            accent.withAlphaComponent(0.12).setFill()
            card.fill()
            accent.setStroke()
            card.lineWidth = 2
        } else {
            NSColor.separatorColor.setStroke()
            card.lineWidth = 1
        }
        card.stroke()

        // Mini screen
        let screenRect = bounds.insetBy(dx: 14, dy: 12)
        let screen = NSBezierPath(roundedRect: screenRect, xRadius: 3, yRadius: 3)
        NSColor.tertiaryLabelColor.setStroke()
        screen.lineWidth = 1
        screen.stroke()

        // Zones at the style's maximum arrangement
        let zoneColor = isSelected
            ? accent.withAlphaComponent(0.45)
            : NSColor.secondaryLabelColor.withAlphaComponent(0.35)
        zoneColor.setFill()
        for zoneRect in zoneRects(in: screenRect.insetBy(dx: 3, dy: 3)) {
            NSBezierPath(roundedRect: zoneRect, xRadius: 2, yRadius: 2).fill()
        }

        // Add-zone bars on their screen edges
        accent.setFill()
        let pillHeight = (screenRect.height * 0.42).rounded()
        let pillY = screenRect.midY - pillHeight / 2
        let pillWidth: CGFloat = 3
        for side in style.barSides {
            let pillX = side == .right ? screenRect.maxX - pillWidth + 1.5 : screenRect.minX - 1.5
            let pillRect = NSRect(x: pillX, y: pillY, width: pillWidth, height: pillHeight)
            NSBezierPath(roundedRect: pillRect, xRadius: pillWidth / 2, yRadius: pillWidth / 2).fill()
        }
    }

    /// Zone rectangles for the style's maximum zone count, in view coordinates.
    /// (Vertical mirroring relative to screen coordinates does not matter: the
    /// stacked-zone split is symmetric in the pictogram.)
    private func zoneRects(in area: NSRect) -> [NSRect] {
        let gap: CGFloat = 3
        let columnWidth = (area.width - gap) / 2
        let leftColumn = NSRect(x: area.minX, y: area.minY, width: columnWidth, height: area.height)
        let rightColumn = NSRect(x: area.minX + columnWidth + gap, y: area.minY, width: columnWidth, height: area.height)

        func stacked(_ column: NSRect) -> [NSRect] {
            let rowHeight = (column.height - gap) / 2
            return [
                NSRect(x: column.minX, y: column.minY + rowHeight + gap, width: column.width, height: rowHeight),
                NSRect(x: column.minX, y: column.minY, width: column.width, height: rowHeight)
            ]
        }

        switch style {
        case .rightBar:
            return [leftColumn] + stacked(rightColumn)
        case .leftBar:
            return stacked(leftColumn) + [rightColumn]
        case .dualBar:
            return stacked(leftColumn) + stacked(rightColumn)
        }
    }
}
