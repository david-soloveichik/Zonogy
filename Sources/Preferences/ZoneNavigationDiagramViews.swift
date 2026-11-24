/// Pictograms for the Zone Navigation editor, showing where each navigation key lands rather than
/// spelling the mapping out in prose: the arrows as they sit on the keyboard, the jump keys on the
/// four cells of a screen's zone grid and on the Floating Zone Bar, and on the displays in
/// left-to-right order — mappings that are spatial by nature, and so are read far faster from a
/// picture than from a list. The jump keys are the user's to change, so their caps are real
/// buttons laid over the picture; the arrows are fixed, and drawn.
import AppKit
import Carbon

/// Base for those pictograms: fixed-size pictures that draw dimmed while the key group they
/// illustrate is switched off, so the picture stays put as a reference instead of disappearing.
/// A picture with nothing to click in it is an image to assistive clients.
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

    /// Draws one fixed key's glyph centered on `center`.
    final func drawCap(_ label: String, centeredAt center: NSPoint, style: KeyCap.Style = .plain) {
        KeyCap.draw(in: Self.capRect(for: label, centeredAt: center), label: label, font: Self.capFont, style: style)
    }

    /// The rect of a cap for `label` centered on `center`.
    static func capRect(for label: String, centeredAt center: NSPoint) -> NSRect {
        let width = KeyCap.width(for: label, font: capFont, height: capHeight)
        return NSRect(
            x: (center.x - width / 2).rounded(),
            y: (center.y - capHeight / 2).rounded(),
            width: width,
            height: capHeight
        )
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

/// The arrow keys as they sit on the keyboard. Fixed keys, so drawn — but a chord another
/// shortcut holds is still marked, as on the settable caps.
final class ArrowKeysDiagramView: KeyDiagramView {
    private static let capWidth: CGFloat = 26
    private static let gap: CGFloat = 4

    /// Key codes of arrows whose chord another shortcut holds.
    var contestedKeyCodes: Set<CGKeyCode> = [] {
        didSet {
            if contestedKeyCodes != oldValue { needsDisplay = true }
        }
    }

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
        let arrows: [(label: String, keyCode: Int, center: NSPoint)] = [
            ("↑", kVK_UpArrow, NSPoint(x: bounds.midX, y: topRow)),
            ("←", kVK_LeftArrow, NSPoint(x: bounds.midX - step, y: bottomRow)),
            ("↓", kVK_DownArrow, NSPoint(x: bounds.midX, y: bottomRow)),
            ("→", kVK_RightArrow, NSPoint(x: bounds.midX + step, y: bottomRow)),
        ]
        for arrow in arrows {
            let contested = contestedKeyCodes.contains(CGKeyCode(arrow.keyCode))
            drawCap(arrow.label, centeredAt: arrow.center, style: contested ? KeyCap.Style.plain.contested : .plain)
        }
    }
}

/// Base for the pictograms whose keys are the user's to change: one `KeyCapButton` per jump shown,
/// laid over the drawn picture by its center and dimmed along with it. The owner sets each cap's
/// label and what a click does. To assistive clients the picture is a group, not an image, so
/// the caps inside it can be reached; its description still says what the picture shows.
class JumpKeysDiagramView: KeyDiagramView {
    let caps: [ZoneNavigationKey: KeyCapButton]

    init(jumps: [ZoneNavigationKey]) {
        caps = Dictionary(uniqueKeysWithValues: jumps.map { jump in
            (jump, KeyCapButton(label: "", height: KeyDiagramView.capHeight, fontSize: 12))
        })
        super.init(frame: .zero)
        setAccessibilityRole(.group)
        for jump in jumps {
            guard let cap = caps[jump] else { continue }
            // Placed by frame in `layout`, not by constraints.
            cap.translatesAutoresizingMaskIntoConstraints = true
            addSubview(cap)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isEnabled: Bool {
        didSet {
            caps.values.forEach { $0.isEnabled = isEnabled }
        }
    }

    /// Where each cap sits, by center.
    func capCenters() -> [ZoneNavigationKey: NSPoint] { [:] }

    /// The cap's key, spoken, for the picture's description.
    final func spokenKey(_ jump: ZoneNavigationKey) -> String {
        KeyCap.spokenName(for: caps[jump]?.label ?? "")
    }

    override func layout() {
        super.layout()
        for (jump, center) in capCenters() {
            guard let cap = caps[jump] else { continue }
            let size = cap.intrinsicContentSize
            cap.frame = NSRect(
                x: (center.x - size.width / 2).rounded(),
                y: (center.y - size.height / 2).rounded(),
                width: size.width,
                height: size.height
            )
        }
    }
}

/// A screen's two-by-two zone grid with the key that jumps to each cell, plus the Floating Zone
/// Bar across the bottom edge carrying the floating zone's key.
final class ZoneJumpKeysDiagramView: JumpKeysDiagramView {
    /// Height of the band along the bottom edge reserved for the Floating Zone Bar and its cap.
    private static let floatingBand: CGFloat = 23
    private static let screenInset: CGFloat = 6
    private static let zoneGap: CGFloat = 4

    init() {
        super.init(jumps: [.zone(.topLeft), .zone(.topRight), .zone(.bottomLeft), .zone(.bottomRight), .floatingZone])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var spokenDescription: String {
        "A display's four zones, each labelled with the key that jumps to it: \(spokenKey(.zone(.topLeft))) "
            + "top left, \(spokenKey(.zone(.topRight))) top right, \(spokenKey(.zone(.bottomLeft))) bottom "
            + "left, \(spokenKey(.zone(.bottomRight))) bottom right. \(spokenKey(.floatingZone)) labels the "
            + "Floating Zone Bar on the display's bottom edge."
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 162, height: 80)
    }

    /// The four cells above the band the floating bar occupies.
    private var cellRects: [ZoneNavigationKey: NSRect] {
        let inner = bounds.insetBy(dx: Self.screenInset, dy: Self.screenInset)
        let grid = NSRect(
            x: inner.minX,
            y: inner.minY + Self.floatingBand,
            width: inner.width,
            height: inner.height - Self.floatingBand
        )
        let columnWidth = (grid.width - Self.zoneGap) / 2
        let rowHeight = (grid.height - Self.zoneGap) / 2
        return [
            .zone(.topLeft): NSRect(x: grid.minX, y: grid.maxY - rowHeight, width: columnWidth, height: rowHeight),
            .zone(.topRight): NSRect(x: grid.maxX - columnWidth, y: grid.maxY - rowHeight, width: columnWidth, height: rowHeight),
            .zone(.bottomLeft): NSRect(x: grid.minX, y: grid.minY, width: columnWidth, height: rowHeight),
            .zone(.bottomRight): NSRect(x: grid.maxX - columnWidth, y: grid.minY, width: columnWidth, height: rowHeight),
        ]
    }

    /// The Floating Zone Bar on the screen's bottom edge.
    private var barRect: NSRect {
        let barWidth = (bounds.width * 0.32).rounded()
        return NSRect(x: bounds.midX - barWidth / 2, y: bounds.minY + 4, width: barWidth, height: 4)
    }

    override func capCenters() -> [ZoneNavigationKey: NSPoint] {
        var centers = cellRects.mapValues { NSPoint(x: $0.midX, y: $0.midY) }
        centers[.floatingZone] = NSPoint(x: bounds.midX, y: barRect.maxY + 2 + Self.capHeight / 2)
        return centers
    }

    override func drawDiagram() {
        drawScreen(bounds)
        for rect in cellRects.values {
            drawZone(rect)
        }
        let bar = barRect
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: bar, xRadius: bar.height / 2, yRadius: bar.height / 2).fill()
    }
}

/// The displays in left-to-right order, with the key that jumps to each.
final class DisplayJumpKeysDiagramView: JumpKeysDiagramView {
    private static let displayCount = 3
    private static let displaySize = NSSize(width: 46, height: 32)
    private static let gap: CGFloat = 12
    private static let standHeight: CGFloat = 4

    init() {
        super.init(jumps: (0..<Self.displayCount).map { .display(ordinal: $0) })
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var spokenDescription: String {
        let keys = (0..<Self.displayCount).map { spokenKey(.display(ordinal: $0)) }
        return "Three displays side by side, each labelled with the key that jumps to it: "
            + "\(keys[0]), then \(keys[1]), then \(keys[2])."
    }

    override var intrinsicContentSize: NSSize {
        NSSize(
            width: Self.displaySize.width * CGFloat(Self.displayCount) + Self.gap * CGFloat(Self.displayCount - 1),
            height: Self.displaySize.height + Self.standHeight
        )
    }

    private func screenRect(_ index: Int) -> NSRect {
        NSRect(
            origin: NSPoint(x: (Self.displaySize.width + Self.gap) * CGFloat(index), y: Self.standHeight),
            size: Self.displaySize
        )
    }

    override func capCenters() -> [ZoneNavigationKey: NSPoint] {
        Dictionary(uniqueKeysWithValues: (0..<Self.displayCount).map { index in
            let screen = screenRect(index)
            return (.display(ordinal: index), NSPoint(x: screen.midX, y: screen.midY))
        })
    }

    override func drawDiagram() {
        for index in 0..<Self.displayCount {
            let screen = screenRect(index)
            drawZone(screen.insetBy(dx: 1, dy: 1))
            drawScreen(screen, cornerRadius: 4)

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
