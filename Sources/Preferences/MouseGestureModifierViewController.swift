/// Modal sheet for choosing which modifier keys activate Zonogy's mouse gestures.
import AppKit

final class MouseGestureModifierViewController: NSViewController {
    /// Called with the chosen combination when the user confirms (guaranteed valid).
    var onSave: ((MouseGestureModifiers) -> Void)?

    private var checkboxes: [(modifier: MouseGestureModifiers, button: NSButton)] = []
    private var previewLabel: NSTextField!
    private var hintLabel: NSTextField!
    private var actionsLabel: NSTextField!
    private var saveButton: NSButton!

    private var selectedModifiers: MouseGestureModifiers {
        checkboxes.reduce(into: []) { result, entry in
            if entry.button.state == .on { result.insert(entry.modifier) }
        }
    }

    override func loadView() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "Mouse Gesture Modifiers")
        title.font = NSFont.boldSystemFont(ofSize: 15)

        let subtitle = NSTextField(wrappingLabelWithString:
            "Choose the modifier keys to hold while clicking or dragging to activate Zonogy's mouse gestures. Select at least two.")
        subtitle.font = NSFont.systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor
        subtitle.preferredMaxLayoutWidth = 400

        stack.addArrangedSubview(title)
        stack.addArrangedSubview(subtitle)
        stack.setCustomSpacing(14, after: subtitle)

        let current = MouseGestureModifierPreferences.shared.modifiers
        for entry in MouseGestureModifiers.displayOrder {
            let checkbox = NSButton(
                checkboxWithTitle: "\(entry.symbol)  \(entry.name)",
                target: self,
                action: #selector(checkboxToggled)
            )
            checkbox.state = current.contains(entry.modifier) ? .on : .off
            checkboxes.append((entry.modifier, checkbox))
            stack.addArrangedSubview(checkbox)
        }

        previewLabel = NSTextField(labelWithString: "")
        previewLabel.font = NSFont.systemFont(ofSize: 12)
        stack.setCustomSpacing(14, after: checkboxes.last?.button ?? subtitle)
        stack.addArrangedSubview(previewLabel)

        hintLabel = NSTextField(labelWithString: "Select at least two modifiers.")
        hintLabel.font = NSFont.systemFont(ofSize: 11)
        hintLabel.textColor = .systemRed
        stack.addArrangedSubview(hintLabel)

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(separator)
        separator.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true

        let actionsHeader = NSTextField(labelWithString: "These gestures use these modifiers:")
        actionsHeader.font = NSFont.boldSystemFont(ofSize: 12)
        stack.addArrangedSubview(actionsHeader)

        actionsLabel = NSTextField(wrappingLabelWithString: "")
        actionsLabel.font = NSFont.systemFont(ofSize: 12)
        actionsLabel.textColor = .secondaryLabelColor
        actionsLabel.preferredMaxLayoutWidth = 400
        stack.addArrangedSubview(actionsLabel)

        // Button row: Restore Default on the left, Cancel/Save on the right.
        let restoreButton = NSButton(title: "Restore Default", target: self, action: #selector(restoreDefault))
        restoreButton.bezelStyle = .rounded
        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}" // Escape
        saveButton = NSButton(title: "Save", target: self, action: #selector(save))
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r" // Return

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttonRow = NSStackView(views: [restoreButton, spacer, cancelButton, saveButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 10
        stack.setCustomSpacing(16, after: actionsLabel)
        stack.addArrangedSubview(buttonRow)
        buttonRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 10))
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            container.widthAnchor.constraint(equalToConstant: 440),
        ])
        self.view = container

        refresh()
    }

    @objc private func checkboxToggled() {
        refresh()
    }

    @objc private func restoreDefault() {
        for entry in checkboxes {
            entry.button.state = MouseGestureModifiers.defaultModifiers.contains(entry.modifier) ? .on : .off
        }
        refresh()
    }

    @objc private func cancel() {
        dismiss(self)
    }

    @objc private func save() {
        let selected = selectedModifiers
        guard selected.isValid else { return }
        onSave?(selected)
        dismiss(self)
    }

    /// Sync the live preview, validation hint, affected-gesture list, and Save button to the
    /// currently checked modifiers.
    private func refresh() {
        let selected = selectedModifiers
        let combo = selected.isValid ? selected.displayString : "—"

        previewLabel.stringValue = "Gesture modifiers: \(selected.displayString.isEmpty ? "(none)" : selected.displayString)"
        hintLabel.isHidden = selected.isValid
        saveButton.isEnabled = selected.isValid

        actionsLabel.stringValue = [
            "• \(combo)-click a tiling zone → make it the destination",
            "• \(combo)-double-click → make it the destination and open the Launcher",
            "• \(combo)-drag a tiled window → move it into the floating zone",
            "• \(combo)-drag a floating window → drop it into an occupied zone (replacing it)",
            "• \(combo)-drag from another app → route the drop into a zone",
        ].joined(separator: "\n")
    }
}
