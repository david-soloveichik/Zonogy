/// Pictograms for the Zone Navigation editor, showing where each navigation key lands rather than
/// spelling the mapping out in prose. A, S, D, F sit on the four cells of a screen's zone grid,
/// G on the Floating Zone Bar, and J, K, L on the displays in left-to-right order — mappings that
/// are spatial by nature, and so are read far faster from a picture than from a list.
import AppKit

/// Base for those pictograms: fixed-size pictures that draw dimmed while the key group they
/// illustrate is switched off, so the picture stays put as a reference instead of disappearing.
class KeyDiagramView: NSView {
    /// Cap metrics shared by every pictogram, so all the glyphs match.
    static let capHeight: CGFloat = 19
    static let capFont = KeyCap.font(ofSize: 12)

    var isEnabled: Bool = true {
        didSet {
            if isEnabled != oldValue { needsDisplay = true }
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
    }

    /// What the picture says, in words. The mapping it carries appears nowhere else in the sheet,
    /// so it has to be spelled out for anyone who can't see the picture.
    var spokenDescription: String { "" }

    override func accessibilityLabel() -> String? {
        spokenDescription
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.cgContext.setAlpha(isEnabled ? 1 : 0.3)
        drawDiagram()
    }

    /// Subclass hook, drawn through the dimming set by `draw`.
    func drawDiagram() {}

    /// Draws one key glyph centered on `center`.
    final func drawCap(_ label: String, centeredAt center: NSPoint, style: KeyCap.Style = .plain) {
        let width = KeyCap.width(for: label, font: Self.capFont, height: Self.capHeight)
        let rect = NSRect(
            x: (center.x - width / 2).rounded(),
            y: (center.y - Self.capHeight / 2).rounded(),
            width: width,
            height: Self.capHeight
        )
        KeyCap.draw(in: rect, label: label, font: Self.capFont, style: style)
    }

    /// Outlines a screen (or display) and returns the drawn rect.
    @discardableResult
    final func drawScreen(_ rect: NSRect, cornerRadius: CGFloat = 5) -> NSRect {
        let path = NSBezierPath(
            roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: cornerRadius, yRadius: cornerRadius)
        NSColor.tertiaryLabelColor.setStroke()
        path.lineWidth = 1
        path.stroke()
        return rect
    }

    /// Fills one zone of a screen.
    final func drawZone(_ rect: NSRect) {
        NSColor.secondaryLabelColor.withAlphaComponent(0.13).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
    }
}

/// The arrow keys as they sit on the keyboard.
final class ArrowKeysDiagramView: KeyDiagramView {
    private static let capWidth: CGFloat = 26
    private static let gap: CGFloat = 4

    override var spokenDescription: String {
        "The four arrow keys: up above, and left, down, right below."
    }

    override var intrinsicContentSize: NSSize {
        NSSize(
            width: Self.capWidth * 3 + Self.gap * 2,
            height: Self.capHeight * 2 + Self.gap
        )
    }

    override func drawDiagram() {
        let bottomRow = Self.capHeight / 2
        let topRow = Self.capHeight + Self.gap + Self.capHeight / 2
        let step = Self.capWidth + Self.gap
        drawCap("↑", centeredAt: NSPoint(x: bounds.midX, y: topRow))
        drawCap("←", centeredAt: NSPoint(x: bounds.midX - step, y: bottomRow))
        drawCap("↓", centeredAt: NSPoint(x: bounds.midX, y: bottomRow))
        drawCap("→", centeredAt: NSPoint(x: bounds.midX + step, y: bottomRow))
    }
}

/// A screen's two-by-two zone grid with the letter that jumps to each cell, plus the Floating Zone
/// Bar across the bottom edge carrying G.
final class ZoneLetterKeysDiagramView: KeyDiagramView {
    /// Height of the band along the bottom edge reserved for the Floating Zone Bar and its cap.
    private static let floatingBand: CGFloat = 23
    private static let screenInset: CGFloat = 6
    private static let zoneGap: CGFloat = 4

    override var spokenDescription: String {
        "A display's four zones, each labelled with the key that jumps to it: A top left, S top "
            + "right, D bottom left, F bottom right. G labels the Floating Zone Bar on the "
            + "display's bottom edge."
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 162, height: 80)
    }

    override func drawDiagram() {
        let screen = drawScreen(bounds)

        // The four cells A/S/D/F address, above the band the floating bar occupies.
        let inner = screen.insetBy(dx: Self.screenInset, dy: Self.screenInset)
        let grid = NSRect(
            x: inner.minX,
            y: inner.minY + Self.floatingBand,
            width: inner.width,
            height: inner.height - Self.floatingBand
        )
        let columnWidth = (grid.width - Self.zoneGap) / 2
        let rowHeight = (grid.height - Self.zoneGap) / 2
        let cells: [(String, NSRect)] = [
            ("A", NSRect(x: grid.minX, y: grid.maxY - rowHeight, width: columnWidth, height: rowHeight)),
            ("S", NSRect(x: grid.maxX - columnWidth, y: grid.maxY - rowHeight, width: columnWidth, height: rowHeight)),
            ("D", NSRect(x: grid.minX, y: grid.minY, width: columnWidth, height: rowHeight)),
            ("F", NSRect(x: grid.maxX - columnWidth, y: grid.minY, width: columnWidth, height: rowHeight)),
        ]
        for (label, rect) in cells {
            drawZone(rect)
            drawCap(label, centeredAt: NSPoint(x: rect.midX, y: rect.midY), style: .onCanvas)
        }

        // The Floating Zone Bar on the screen's bottom edge, with G resting on it.
        let barWidth = (screen.width * 0.32).rounded()
        let barHeight: CGFloat = 4
        let bar = NSRect(
            x: screen.midX - barWidth / 2, y: screen.minY + 4, width: barWidth, height: barHeight)
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: bar, xRadius: barHeight / 2, yRadius: barHeight / 2).fill()
        drawCap(
            "G",
            centeredAt: NSPoint(x: screen.midX, y: bar.maxY + 2 + Self.capHeight / 2),
            style: .onCanvas
        )
    }
}

/// The displays in left-to-right order, with the letter that jumps to each.
final class DisplayLetterKeysDiagramView: KeyDiagramView {
    private static let labels = ["J", "K", "L"]
    private static let displaySize = NSSize(width: 46, height: 32)
    private static let gap: CGFloat = 12
    private static let standHeight: CGFloat = 4

    override var spokenDescription: String {
        "Three displays side by side, each labelled with the key that jumps to it: J, then K, then L."
    }

    override var intrinsicContentSize: NSSize {
        NSSize(
            width: Self.displaySize.width * CGFloat(Self.labels.count) + Self.gap * CGFloat(Self.labels.count - 1),
            height: Self.displaySize.height + Self.standHeight
        )
    }

    override func drawDiagram() {
        for (index, label) in Self.labels.enumerated() {
            let origin = NSPoint(
                x: (Self.displaySize.width + Self.gap) * CGFloat(index),
                y: Self.standHeight
            )
            let screen = NSRect(origin: origin, size: Self.displaySize)
            drawZone(screen.insetBy(dx: 1, dy: 1))
            drawScreen(screen, cornerRadius: 4)
            drawCap(label, centeredAt: NSPoint(x: screen.midX, y: screen.midY), style: .onCanvas)

            // A stub of a stand, so the shapes read as displays rather than as more zones.
            let stand = NSRect(x: screen.midX - 7, y: 0, width: 14, height: Self.standHeight)
            NSColor.tertiaryLabelColor.setFill()
            NSBezierPath(roundedRect: stand, xRadius: 1.5, yRadius: 1.5).fill()
        }
    }
}

/// One key group's pictograms and their captions, shown under the checkbox that switches the group
/// on. Each pictogram is centered in a fixed-width column with its caption below, and every column
/// in the sheet shares one band height, so the captions all start on the same line however tall
/// each picture happens to be — which lets the key groups sit side by side instead of stacking.
/// Dimming them together keeps the layout still while the group is off, leaving the pictures in
/// place as a reference.
final class KeyGroupIllustrationView: NSView {
    /// Gap between adjacent pictogram columns.
    static let columnGap: CGFloat = 16

    private let diagrams: [KeyDiagramView]
    private let captions: [NSTextField]

    var isEnabled: Bool = true {
        didSet {
            guard isEnabled != oldValue else { return }
            diagrams.forEach { $0.isEnabled = isEnabled }
            captions.forEach { $0.textColor = isEnabled ? .secondaryLabelColor : .tertiaryLabelColor }
        }
    }

    init(
        items: [(diagram: KeyDiagramView, caption: String)],
        columnWidth: CGFloat,
        bandHeight: CGFloat
    ) {
        self.diagrams = items.map(\.diagram)
        self.captions = items.map { item in
            let label = NSTextField(wrappingLabelWithString: item.caption)
            label.font = NSFont.systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            label.preferredMaxLayoutWidth = columnWidth
            label.widthAnchor.constraint(equalToConstant: columnWidth).isActive = true
            return label
        }
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let outer = NSStackView()
        outer.translatesAutoresizingMaskIntoConstraints = false
        outer.orientation = .horizontal
        outer.alignment = .top
        outer.spacing = Self.columnGap

        for (index, diagram) in diagrams.enumerated() {
            let band = NSView()
            band.translatesAutoresizingMaskIntoConstraints = false
            band.addSubview(diagram)
            NSLayoutConstraint.activate([
                band.widthAnchor.constraint(equalToConstant: columnWidth),
                band.heightAnchor.constraint(equalToConstant: bandHeight),
                diagram.centerXAnchor.constraint(equalTo: band.centerXAnchor),
                diagram.centerYAnchor.constraint(equalTo: band.centerYAnchor),
            ])

            let column = NSStackView(views: [band, captions[index]])
            column.orientation = .vertical
            column.alignment = .leading
            column.spacing = 8
            outer.addArrangedSubview(column)
        }

        addSubview(outer)
        NSLayoutConstraint.activate([
            outer.topAnchor.constraint(equalTo: topAnchor),
            outer.leadingAnchor.constraint(equalTo: leadingAnchor),
            outer.trailingAnchor.constraint(equalTo: trailingAnchor),
            outer.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}
