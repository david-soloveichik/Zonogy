/// The keycap look shared by the held-modifier gesture editors: a rounded cap carrying one key's
/// glyph. Drawing the keys instead of naming them inside a sentence lets the walkthroughs and
/// pictograms be read at a glance — a cap is something to press, a word is something to parse.
/// The fill also says whether a key is the user's to change: a gray cap is fixed, a white one can
/// be clicked.
import AppKit

enum KeyCap {
    /// Colors of one cap.
    struct Style {
        let fill: NSColor
        let border: NSColor
        let text: NSColor
        var borderWidth: CGFloat = 1

        /// A fixed key at rest. Derived from the label color rather than a control color so a cap
        /// reads on both the sheet background and the lighter section cards.
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
        /// A key the user can change: filled like a text field, so it reads as something to click,
        /// and it stands out on a shaded pictogram where the resting cap would sink in.
        static let settable = Style(
            fill: .controlBackgroundColor,
            border: NSColor.labelColor.withAlphaComponent(0.28),
            text: .labelColor
        )
        /// A settable key under the pointer.
        static let settableHovered = Style(
            fill: NSColor.controlAccentColor.withAlphaComponent(0.10),
            border: NSColor.controlAccentColor.withAlphaComponent(0.6),
            text: .labelColor
        )
        /// A settable key waiting for the key that will replace it.
        static let recording = Style(
            fill: NSColor.controlAccentColor.withAlphaComponent(0.18),
            border: .controlAccentColor,
            text: .labelColor,
            borderWidth: 2
        )

        /// This style with the warning-colored border of a key whose chord another shortcut holds.
        var contested: Style {
            Style(fill: fill, border: .systemOrange, text: text, borderWidth: 2)
        }
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
        let inset = style.borderWidth / 2
        let cap = NSBezierPath(
            roundedRect: rect.insetBy(dx: inset, dy: inset), xRadius: cornerRadius, yRadius: cornerRadius)
        style.fill.setFill()
        cap.fill()
        style.border.setStroke()
        cap.lineWidth = style.borderWidth
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
    /// useful. Covers every glyph `KeyboardShortcut.keyLabel` produces; keys that are already
    /// their own name (letters, "Space", "F5") fall through.
    static func spokenName(for label: String) -> String {
        [
            "⌃": "Control", "⌥": "Option", "⇧": "Shift", "⌘": "Command",
            "↩": "Return", "esc": "Escape", "⎋": "Escape", "⇥": "Tab",
            "⌫": "Delete", "⌦": "Forward Delete",
            "↖": "Home", "↘": "End", "⇞": "Page Up", "⇟": "Page Down",
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

/// A key the user can click, drawn as a white cap: highlighted under the pointer, filled with the
/// accent color and pulsing while it records a replacement, and outlined in the warning color
/// while the chord it holds is contested. What a click does is the owner's call — record a new
/// key in place, or, for a key set elsewhere, say where.
final class KeyCapButton: NSControl {
    var label: String {
        didSet {
            guard label != oldValue else { return }
            invalidateIntrinsicContentSize()
            superview?.needsLayout = true
            needsDisplay = true
        }
    }

    /// Whether another shortcut holds this key's chord.
    var isConflicting = false {
        didSet {
            if isConflicting != oldValue { needsDisplay = true }
        }
    }

    /// Whether the cap is waiting for a key press. Pulses while it is, as the table's chip does.
    var isRecording = false {
        didSet {
            guard isRecording != oldValue else { return }
            needsDisplay = true
            // Every change retires the pulse loop in flight: a completion of the old loop that
            // lands after a quick stop-and-restart must not start a second loop beside the new one.
            pulseGeneration += 1
            if isRecording {
                pulse(toAlpha: Self.pulseMinAlpha, generation: pulseGeneration)
            } else {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.15
                    self.animator().alphaValue = 1
                }
            }
        }
    }

    var onClick: ((KeyCapButton) -> Void)?

    override var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
    }

    private let capHeight: CGFloat
    private let capFont: NSFont
    private var trackingAreaForHover: NSTrackingArea?
    private var isHovered = false {
        didSet {
            if isHovered != oldValue { needsDisplay = true }
        }
    }

    private static let pulseMinAlpha: CGFloat = 0.55
    private var pulseGeneration = 0

    init(label: String, height: CGFloat = 20, fontSize: CGFloat = 12) {
        self.label = label
        self.capHeight = height
        self.capFont = KeyCap.font(ofSize: fontSize)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        // The recording pulse animates the view's alpha, which needs a layer.
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: KeyCap.width(for: label, font: capFont, height: capHeight), height: capHeight)
    }

    /// Baseline-align the cap's glyph with the description text beside it.
    override var firstBaselineOffsetFromTop: CGFloat {
        KeyCap.baselineOffsetFromTop(capHeight: capHeight, font: capFont)
    }

    // MARK: - Interaction

    override var acceptsFirstResponder: Bool { isEnabled }

    override func mouseDown(with event: NSEvent) {
        click()
    }

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " || event.keyCode == 36 {
            click()
        } else {
            super.keyDown(with: event)
        }
    }

    override func accessibilityPerformPress() -> Bool {
        click()
        return true
    }

    private func click() {
        guard isEnabled else { return }
        onClick?(self)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaForHover {
            removeTrackingArea(trackingAreaForHover)
        }
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self)
        addTrackingArea(area)
        trackingAreaForHover = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }

    override func resetCursorRects() {
        if isEnabled {
            addCursorRect(bounds, cursor: .pointingHand)
        }
    }

    // MARK: - Drawing

    private func pulse(toAlpha alpha: CGFloat, generation: Int) {
        guard isRecording, generation == pulseGeneration else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.7
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            self.animator().alphaValue = alpha
        }, completionHandler: { [weak self] in
            self?.pulse(toAlpha: alpha == Self.pulseMinAlpha ? 1 : Self.pulseMinAlpha, generation: generation)
        })
    }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: KeyCap.cornerRadius, yRadius: KeyCap.cornerRadius).fill()
    }

    override var focusRingMaskBounds: NSRect { bounds }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.cgContext.setAlpha(isEnabled ? 1 : 0.35)
        let style: KeyCap.Style
        if isRecording {
            style = .recording
        } else if isHovered && isEnabled {
            style = .settableHovered
        } else if isConflicting {
            style = KeyCap.Style.settable.contested
        } else {
            style = .settable
        }
        KeyCap.draw(in: bounds, label: label, font: capFont, style: style)
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
            // notification otherwise, whether the change came from a click or Restore Defaults.
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
