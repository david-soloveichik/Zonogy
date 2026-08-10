/// Modal sheet for choosing the modifier keys behind one of Zonogy's held-modifier gestures.
/// One implementation serves both editors; the factories at the bottom supply each gesture
/// family's copy (title, walkthrough text, and current combination).
import AppKit

final class ModifierCombinationSheetViewController: NSViewController {
    /// An optional preset picker (radio row) shown below the modifier checkboxes. The selected
    /// index is passed to `walkthroughText` and `onSave` (0 when the sheet has no picker).
    struct Choice {
        let header: String
        let labels: [String]
        let initialIndex: Int
        /// The index Restore Default selects.
        let defaultIndex: Int
    }

    /// Called with the chosen combination and preset index when the user confirms
    /// (the combination is guaranteed valid).
    var onSave: ((ModifierCombination, Int) -> Void)?

    private let sheetTitle: String
    private let subtitle: String
    private let previewPrefix: String
    private let walkthroughHeader: String
    /// Builds the walkthrough text for the given combo glyphs ("—" while the selection is invalid)
    /// and the selected preset index.
    private let walkthroughText: (String, Int) -> String
    private let initialModifiers: ModifierCombination
    private let choice: Choice?

    private var checkboxes: [(modifier: ModifierCombination, button: NSButton)] = []
    private var choiceButtons: [NSButton] = []
    private var selectedChoiceIndex: Int
    private var previewLabel: NSTextField!
    private var hintLabel: NSTextField!
    private var walkthroughLabel: NSTextField!
    private var saveButton: NSButton!

    private init(
        title: String,
        subtitle: String,
        previewPrefix: String,
        walkthroughHeader: String,
        walkthroughText: @escaping (String, Int) -> String,
        initialModifiers: ModifierCombination,
        choice: Choice? = nil
    ) {
        self.sheetTitle = title
        self.subtitle = subtitle
        self.previewPrefix = previewPrefix
        self.walkthroughHeader = walkthroughHeader
        self.walkthroughText = walkthroughText
        self.initialModifiers = initialModifiers
        self.choice = choice
        self.selectedChoiceIndex = choice?.initialIndex ?? 0
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private var selectedModifiers: ModifierCombination {
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

        let title = NSTextField(labelWithString: sheetTitle)
        title.font = NSFont.boldSystemFont(ofSize: 15)

        let subtitleLabel = NSTextField(wrappingLabelWithString: subtitle)
        subtitleLabel.font = NSFont.systemFont(ofSize: 12)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.preferredMaxLayoutWidth = 400

        stack.addArrangedSubview(title)
        stack.addArrangedSubview(subtitleLabel)
        stack.setCustomSpacing(14, after: subtitleLabel)

        for entry in ModifierCombination.displayOrder {
            let checkbox = NSButton(
                checkboxWithTitle: "\(entry.symbol)  \(entry.name)",
                target: self,
                action: #selector(checkboxToggled)
            )
            checkbox.state = initialModifiers.contains(entry.modifier) ? .on : .off
            checkboxes.append((entry.modifier, checkbox))
            stack.addArrangedSubview(checkbox)
        }

        previewLabel = NSTextField(labelWithString: "")
        previewLabel.font = NSFont.systemFont(ofSize: 12)
        stack.setCustomSpacing(14, after: checkboxes.last?.button ?? subtitleLabel)
        stack.addArrangedSubview(previewLabel)

        hintLabel = NSTextField(labelWithString: "Select at least two modifiers.")
        hintLabel.font = NSFont.systemFont(ofSize: 11)
        hintLabel.textColor = .systemRed
        stack.addArrangedSubview(hintLabel)

        if let choice {
            let choiceHeader = NSTextField(labelWithString: choice.header)
            choiceHeader.font = NSFont.boldSystemFont(ofSize: 12)
            stack.setCustomSpacing(14, after: hintLabel)
            stack.addArrangedSubview(choiceHeader)

            for (index, label) in choice.labels.enumerated() {
                let radio = NSButton(radioButtonWithTitle: label, target: self, action: #selector(choiceChanged(_:)))
                radio.tag = index
                radio.state = index == selectedChoiceIndex ? .on : .off
                choiceButtons.append(radio)
            }
            let choiceRow = NSStackView(views: choiceButtons)
            choiceRow.orientation = .horizontal
            choiceRow.spacing = 12
            stack.addArrangedSubview(choiceRow)
        }

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(separator)
        separator.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true

        let walkthroughHeaderLabel = NSTextField(labelWithString: walkthroughHeader)
        walkthroughHeaderLabel.font = NSFont.boldSystemFont(ofSize: 12)
        stack.addArrangedSubview(walkthroughHeaderLabel)

        walkthroughLabel = NSTextField(wrappingLabelWithString: "")
        walkthroughLabel.font = NSFont.systemFont(ofSize: 12)
        walkthroughLabel.textColor = .secondaryLabelColor
        walkthroughLabel.preferredMaxLayoutWidth = 400
        stack.addArrangedSubview(walkthroughLabel)

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
        stack.setCustomSpacing(16, after: walkthroughLabel)
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

    @objc private func choiceChanged(_ sender: NSButton) {
        selectedChoiceIndex = sender.tag
        for button in choiceButtons {
            button.state = button.tag == selectedChoiceIndex ? .on : .off
        }
        refresh()
    }

    @objc private func restoreDefault() {
        for entry in checkboxes {
            entry.button.state = ModifierCombination.defaultModifiers.contains(entry.modifier) ? .on : .off
        }
        selectedChoiceIndex = choice?.defaultIndex ?? 0
        for button in choiceButtons {
            button.state = button.tag == selectedChoiceIndex ? .on : .off
        }
        refresh()
    }

    @objc private func cancel() {
        dismiss(self)
    }

    @objc private func save() {
        let selected = selectedModifiers
        guard selected.isValid else { return }
        onSave?(selected, selectedChoiceIndex)
        dismiss(self)
    }

    /// Sync the live preview, validation hint, gesture walkthrough, and Save button to the
    /// currently checked modifiers.
    private func refresh() {
        let selected = selectedModifiers

        previewLabel.stringValue = "\(previewPrefix): \(selected.displayString.isEmpty ? "(none)" : selected.displayString)"
        hintLabel.isHidden = selected.isValid
        saveButton.isEnabled = selected.isValid

        walkthroughLabel.stringValue = walkthroughText(selected.isValid ? selected.displayString : "—", selectedChoiceIndex)
    }
}

// MARK: - The two editors

extension ModifierCombinationSheetViewController {
    /// Editor for the modifiers held while clicking or dragging to activate the mouse gestures.
    static func mouseGestures() -> ModifierCombinationSheetViewController {
        ModifierCombinationSheetViewController(
            title: "Mouse Gesture Modifiers",
            subtitle: "Choose the modifier keys to hold while clicking or dragging to activate "
                + "Zonogy's mouse gestures. Select at least two.",
            previewPrefix: "Gesture modifiers",
            walkthroughHeader: "These gestures use these modifiers:",
            walkthroughText: { combo, _ in
                [
                    "• \(combo)-click a tiling zone → make it the destination",
                    "• \(combo)-double-click → make it the destination and open the Launcher",
                    "• \(combo)-drag a tiled window → move it into the floating zone",
                    "• \(combo)-drag a floating window → drop it into an occupied zone (replacing it)",
                    "• \(combo)-drag from another app → route the drop into a zone",
                ].joined(separator: "\n")
            },
            initialModifiers: ModifierCombinationPreferences.mouseGestures.modifiers
        )
    }

    /// Editor for the modifiers and selection-key preset of keyboard zone navigation. The preset
    /// choice indexes `ZoneNavigationKeyset.allCases`.
    static func zoneNavigation() -> ModifierCombinationSheetViewController {
        let keysets = ZoneNavigationKeyset.allCases
        let current = ZoneNavigationKeysetPreferences.shared.keyset
        return ModifierCombinationSheetViewController(
            title: "Zone Navigation Modifiers",
            subtitle: "Choose the modifier keys to hold while navigating zones with the keyboard. "
                + "Select at least two.",
            previewPrefix: "Navigation modifiers",
            walkthroughHeader: "How zone navigation works:",
            walkthroughText: { combo, choiceIndex in
                let keyset = keysets[choiceIndex]
                let navigationKeys = "arrow keys" + (keyset.lettersDisplayString.map { " or \($0)" } ?? "")

                // The Launcher, Add Zone, and Remove Zone steps borrow those shortcuts' keys
                // (claimed in that order), so show each key as currently configured — unless an
                // earlier in-gesture key leaves the borrowed key unreachable.
                var earlierBorrowedKeys: [CGKeyCode] = []
                func borrowedKeyLine(
                    action: KeyboardShortcutPreferences.ShortcutAction,
                    step: String,
                    unavailableStep: String
                ) -> String {
                    guard let shortcut = KeyboardShortcutPreferences.shared.shortcut(for: action) else {
                        return "• \(unavailableStep) is unavailable (no \(action.displayName) shortcut is set)"
                    }
                    let keyCode = CGKeyCode(shortcut.keyCode)
                    let key = shortcut.keyDisplayString
                    guard !ZoneNavigationInterceptor.shadowsBorrowedKey(
                        keyCode, keyset: keyset, earlierBorrowedKeys: earlierBorrowedKeys
                    ) else {
                        return "• \(unavailableStep) is unavailable "
                            + "(the \(action.displayName) key \(key) already has another meaning in the gesture)"
                    }
                    earlierBorrowedKeys.append(keyCode)
                    return "• \(combo)\(key): \(step) (\(key) is reused from the \(action.displayName) shortcut)"
                }

                return [
                    "• Hold \(combo) and press \(navigationKeys) to move the blue circle between zones",
                    "• Release \(combo): focus this zone's window, or make it the destination if empty",
                    "• \(combo)↩ (Return): move the focused window into this zone (swapping windows if occupied)",
                    borrowedKeyLine(
                        action: .showLauncher,
                        step: "make this zone the destination and open the Launcher there",
                        unavailableStep: "Opening the Launcher on this zone"
                    ),
                    borrowedKeyLine(
                        action: .addZone,
                        step: "add a zone",
                        unavailableStep: "Adding a zone"
                    ),
                    borrowedKeyLine(
                        action: .removeZone,
                        step: "remove this zone (minimizing its window)",
                        unavailableStep: "Removing this zone"
                    ),
                    "• ⎋ (Escape): cancel",
                ].joined(separator: "\n")
            },
            initialModifiers: ModifierCombinationPreferences.zoneNavigation.modifiers,
            choice: Choice(
                header: "Navigation keys:",
                // "+" marks the letter presets as joining the always-active arrows.
                labels: keysets.map { $0.lettersDisplayString == nil ? $0.displayName : "+ \($0.displayName)" },
                initialIndex: keysets.firstIndex(of: current) ?? 0,
                defaultIndex: keysets.firstIndex(of: ZoneNavigationKeyset.defaultKeyset) ?? 0
            )
        )
    }
}
