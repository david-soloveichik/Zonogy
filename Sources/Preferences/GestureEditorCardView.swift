/// A clickable card opening one of the held-modifier gesture editors, shown above the shortcut
/// table.
///
/// These two gestures have no single key combination to list as a table row, so a plain button
/// under the table both buried them and said nothing about their current setting. A card names the
/// gesture, previews the modifiers it holds as lit keycaps, and says what you do while holding
/// them — so the whole configuration is legible without opening the sheet.
import AppKit

final class GestureEditorCardView: NSControl {
    private let cardTitle: String
    private let summary: String
    /// Read on every refresh, so the caps track edits made in the sheet.
    private let modifiers: () -> ModifierCombination
    private let onOpen: () -> Void

    private var capsRow: NSStackView!
    private var trackingAreaForHover: NSTrackingArea?
    /// The last description handed to accessibility, so a refresh can tell a real change from the
    /// initial one during `init`.
    private var announcedDescription: String?

    private var isHovered = false {
        didSet {
            if isHovered != oldValue { needsDisplay = true }
        }
    }

    init(
        symbolName: String,
        title: String,
        summary: String,
        modifiers: @escaping () -> ModifierCombination,
        onOpen: @escaping () -> Void
    ) {
        self.cardTitle = title
        self.summary = summary
        self.modifiers = modifiers
        self.onOpen = onOpen
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)

        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 17, weight: .regular)
        icon.contentTintColor = .controlAccentColor

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)

        capsRow = NSStackView()
        capsRow.orientation = .horizontal
        capsRow.alignment = .centerY
        capsRow.spacing = 3

        let text = NSStackView(views: [titleLabel, capsRow])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 4

        let chevron = NSImageView()
        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
        chevron.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        chevron.contentTintColor = .tertiaryLabelColor

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [icon, text, spacer, chevron])
        row.translatesAutoresizingMaskIntoConstraints = false
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10

        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: 11),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 13),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -13),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -11),
        ])

        refresh()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Re-read the stored modifiers and redraw the caps.
    func refresh() {
        for view in capsRow.arrangedSubviews {
            capsRow.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        let combination = modifiers()
        for entry in ModifierCombination.displayOrder where combination.contains(entry.modifier) {
            capsRow.addArrangedSubview(KeyCapView(label: entry.symbol, height: 17, fontSize: 11))
        }
        let label = NSTextField(labelWithString: "+ " + summary)
        label.font = NSFont.systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        capsRow.setCustomSpacing(7, after: capsRow.arrangedSubviews.last ?? capsRow)
        capsRow.addArrangedSubview(label)

        // Spoken as names: the glyphs the caps draw are exactly what `KeyCap.spokenName` exists
        // to avoid reading aloud.
        let spoken = ModifierCombination.displayOrder
            .filter { combination.contains($0.modifier) }
            .map(\.name)
            .joined(separator: " ")
        let description = "\(spoken), then \(summary)"
        let changed = announcedDescription != nil && announcedDescription != description
        announcedDescription = description
        setAccessibilityValueDescription(description)
        // Save and Reset All both re-read the stored modifiers behind the user's back, so the
        // preview can change without any interaction with the card itself.
        if changed {
            NSAccessibility.post(element: self, notification: .valueChanged)
        }
    }

    // MARK: - Interaction

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        onOpen()
    }

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " || event.keyCode == 36 {
            onOpen()
        } else {
            super.keyDown(with: event)
        }
    }

    override func accessibilityPerformPress() -> Bool {
        onOpen()
        return true
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
        addCursorRect(bounds, cursor: .pointingHand)
    }

    // MARK: - Drawing

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
    }

    override var focusRingMaskBounds: NSRect { bounds }

    override func draw(_ dirtyRect: NSRect) {
        let card = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        if isHovered {
            NSColor.controlAccentColor.withAlphaComponent(0.10).setFill()
            card.fill()
            NSColor.controlAccentColor.withAlphaComponent(0.55).setStroke()
        } else {
            NSColor.controlBackgroundColor.setFill()
            card.fill()
            NSColor.separatorColor.setStroke()
        }
        card.lineWidth = 1
        card.stroke()
    }
}
