/// Displays a compact status capsule with a symbol, readable label, and subtle tinted background.
import AppKit

final class PreferenceStatusBadge: NSStackView {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var tint: NSColor = .secondaryLabelColor

    init() {
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        spacing = 6
        edgeInsets = NSEdgeInsets(top: 5, left: 10, bottom: 5, right: 10)
        translatesAutoresizingMaskIntoConstraints = false
        // Hug the entire stack, including the space around the icon and label.
        setHuggingPriority(.required, for: .horizontal)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        label.textColor = .labelColor
        label.setContentHuggingPriority(.required, for: .horizontal)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        addArrangedSubview(icon)
        addArrangedSubview(label)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 12),
            icon.heightAnchor.constraint(equalToConstant: 12),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        icon.setAccessibilityElement(false)
        label.setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func update(title: String, symbol: String, color: NSColor) {
        label.stringValue = title
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.contentTintColor = color
        tint = color
        setAccessibilityLabel("Status: \(title)")
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        tint.withAlphaComponent(0.12).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
