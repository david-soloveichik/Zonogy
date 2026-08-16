/// The keycap look shared by the held-modifier gesture editors: a rounded cap carrying one key's
/// glyph. Drawing the keys instead of naming them inside a sentence lets the walkthroughs and
/// pictograms be read at a glance — a cap is something to press, a word is something to parse.
import AppKit

enum KeyCap {
    /// Colors of one cap.
    struct Style {
        let fill: NSColor
        let border: NSColor
        let text: NSColor

        /// A key at rest. Derived from the label color rather than a control color so a cap reads
        /// on both the sheet background and the lighter section cards.
        static let plain = Style(
            fill: NSColor.labelColor.withAlphaComponent(0.06),
            border: NSColor.labelColor.withAlphaComponent(0.22),
            text: .labelColor
        )
        /// A key the user has chosen to hold.
        static let held = Style(
            fill: .controlAccentColor,
            border: .controlAccentColor,
            text: .alternateSelectedControlTextColor
        )
        /// A key drawn on top of a shaded pictogram, where the resting cap would sink into its
        /// background instead of reading as the thing to press.
        static let onCanvas = Style(
            fill: .controlBackgroundColor,
            border: NSColor.labelColor.withAlphaComponent(0.28),
            text: .labelColor
        )
    }

    static let cornerRadius: CGFloat = 5

    static func font(ofSize size: CGFloat) -> NSFont {
        NSFont.systemFont(ofSize: size, weight: .medium)
    }

    /// The cap width that fits `label`, never narrower than `height` so single glyphs stay square.
    static func width(for label: String, font: NSFont, height: CGFloat, padding: CGFloat = 8) -> CGFloat {
        let textWidth = (label as NSString).size(withAttributes: [.font: font]).width
        return max(height, (textWidth + padding * 2).rounded(.up))
    }

    /// Draws a cap filling `rect`, with `label` centered on it.
    static func draw(in rect: NSRect, label: String, font: NSFont, style: Style) {
        let cap = NSBezierPath(
            roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: cornerRadius, yRadius: cornerRadius)
        style.fill.setFill()
        cap.fill()
        style.border.setStroke()
        cap.lineWidth = 1
        cap.stroke()
        drawText(label, in: rect, font: font, color: style.text)
    }

    /// Draws `text` centered in `rect`.
    static func drawText(_ text: String, in rect: NSRect, font: NSFont, color: NSColor) {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let size = (text as NSString).size(withAttributes: attributes)
        let origin = NSPoint(x: (rect.midX - size.width / 2).rounded(), y: (rect.midY - size.height / 2).rounded())
        (text as NSString).draw(at: origin, withAttributes: attributes)
    }

    /// Distance from the top of a cap of `height` down to the baseline of its centered label, so a
    /// cap can sit on the same baseline as the text beside it in a stack view.
    static func baselineOffsetFromTop(capHeight: CGFloat, font: NSFont) -> CGFloat {
        let textHeight = font.ascender - font.descender
        return capHeight - ((capHeight - textHeight) / 2 - font.descender)
    }

    /// What a cap's glyph is called out loud, since VoiceOver reads a bare "⌘" or "↩" as nothing
    /// useful. Falls back to the glyph for keys that are already their own name (letters, "Space").
    static func spokenName(for label: String) -> String {
        [
            "⌃": "Control", "⌥": "Option", "⇧": "Shift", "⌘": "Command",
            "↩": "Return", "esc": "Escape",
            "↑": "Up arrow", "↓": "Down arrow", "←": "Left arrow", "→": "Right arrow",
        ][label] ?? label
    }
}

/// One static cap, sized to its glyph — the left column of a walkthrough row.
final class KeyCapView: NSView {
    private let label: String
    private let capHeight: CGFloat
    private let font: NSFont

    /// Dimmed when the step this cap belongs to can't be reached.
    var isEnabled: Bool = true {
        didSet {
            if isEnabled != oldValue { needsDisplay = true }
        }
    }

    init(label: String, height: CGFloat = 20, fontSize: CGFloat = 12) {
        self.label = label
        self.capHeight = height
        self.font = KeyCap.font(ofSize: fontSize)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(KeyCap.spokenName(for: label))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: KeyCap.width(for: label, font: font, height: capHeight), height: capHeight)
    }

    /// Baseline-align the cap's glyph with the description text beside it.
    override var firstBaselineOffsetFromTop: CGFloat {
        KeyCap.baselineOffsetFromTop(capHeight: capHeight, font: font)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.cgContext.setAlpha(isEnabled ? 1 : 0.35)
        KeyCap.draw(in: bounds, label: label, font: font, style: .plain)
    }
}

/// A modifier key drawn as a cap the user switches on or off: its glyph above its name, filled
/// with the accent color while held. Behaves as a checkbox — the gesture holds every lit cap.
final class ModifierKeyCapButton: NSControl {
    let modifier: ModifierCombination

    private let symbol: String
    private let name: String
    private let symbolFont = KeyCap.font(ofSize: 17)
    private let nameFont = KeyCap.font(ofSize: 10)

    private static let capHeight: CGFloat = 42
    private static let minimumWidth: CGFloat = 60

    var isOn: Bool = false {
        didSet {
            guard isOn != oldValue else { return }
            needsDisplay = true
            // A custom check box has to announce its own value changes; assistive clients get no
            // notification otherwise, whether the change came from a click or Restore Default.
            NSAccessibility.post(element: self, notification: .valueChanged)
        }
    }

    var onToggle: (() -> Void)?

    init(entry: (modifier: ModifierCombination, symbol: String, name: String)) {
        self.modifier = entry.modifier
        self.symbol = entry.symbol
        self.name = entry.name
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true)
        setAccessibilityRole(.checkBox)
        setAccessibilityLabel(entry.name)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var intrinsicContentSize: NSSize {
        let nameWidth = (name as NSString).size(withAttributes: [.font: nameFont]).width
        return NSSize(width: max(Self.minimumWidth, (nameWidth + 20).rounded(.up)), height: Self.capHeight)
    }

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        toggle()
    }

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " || event.keyCode == 36 {
            toggle()
        } else {
            super.keyDown(with: event)
        }
    }

    override func accessibilityValue() -> Any? {
        isOn ? 1 : 0
    }

    override func accessibilityPerformPress() -> Bool {
        toggle()
        return true
    }

    private func toggle() {
        isOn.toggle()
        onToggle?()
    }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: KeyCap.cornerRadius, yRadius: KeyCap.cornerRadius).fill()
    }

    override var focusRingMaskBounds: NSRect { bounds }

    override func draw(_ dirtyRect: NSRect) {
        let style: KeyCap.Style = isOn ? .held : .plain
        let cap = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            xRadius: KeyCap.cornerRadius,
            yRadius: KeyCap.cornerRadius
        )
        style.fill.setFill()
        cap.fill()
        style.border.setStroke()
        cap.lineWidth = 1
        cap.stroke()

        let symbolRect = NSRect(x: 0, y: bounds.height * 0.42, width: bounds.width, height: bounds.height * 0.5)
        KeyCap.drawText(symbol, in: symbolRect, font: symbolFont, color: style.text)

        let nameRect = NSRect(x: 0, y: 6, width: bounds.width, height: 13)
        let nameColor = isOn ? style.text : NSColor.secondaryLabelColor
        KeyCap.drawText(name, in: nameRect, font: nameFont, color: nameColor)
    }
}
