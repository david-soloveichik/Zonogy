/// Modal sheet for choosing the modifier keys behind one of Zonogy's held-modifier gestures.
/// One implementation serves both editors; the factories at the bottom supply each gesture
/// family's copy (title, walkthrough text, and current combination).
import AppKit

final class ModifierCombinationSheetViewController: NSViewController {
    /// Optional extra toggles (checkbox rows) shown below the modifier checkboxes, under a
    /// header. Their on/off states are passed to `walkthroughText` and `onSave` (empty when the
    /// sheet has none).
    struct Options {
        let header: String
        let labels: [String]
        let initialStates: [Bool]
        /// The states Restore Default selects.
        let defaultStates: [Bool]
    }

    /// Called with the chosen combination and option states when the user confirms
    /// (the combination is guaranteed valid).
    var onSave: ((ModifierCombination, [Bool]) -> Void)?

    private let sheetTitle: String
    private let subtitle: String
    private let walkthroughHeader: String
    /// Builds the walkthrough text for the given combo glyphs ("—" while the selection is invalid)
    /// and the current option states.
    private let walkthroughText: (String, [Bool]) -> String
    private let initialModifiers: ModifierCombination
    private let options: Options?

    private var checkboxes: [(modifier: ModifierCombination, button: NSButton)] = []
    private var optionButtons: [NSButton] = []
    private var hintLabel: NSTextField!
    private var walkthroughLabel: NSTextField!
    private var saveButton: NSButton!

    private init(
        title: String,
        subtitle: String,
        walkthroughHeader: String,
        walkthroughText: @escaping (String, [Bool]) -> String,
        initialModifiers: ModifierCombination,
        options: Options? = nil
    ) {
        self.sheetTitle = title
        self.subtitle = subtitle
        self.walkthroughHeader = walkthroughHeader
        self.walkthroughText = walkthroughText
        self.initialModifiers = initialModifiers
        self.options = options
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

    private var optionStates: [Bool] {
        optionButtons.map { $0.state == .on }
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
                action: #selector(selectionChanged)
            )
            checkbox.state = initialModifiers.contains(entry.modifier) ? .on : .off
            checkboxes.append((entry.modifier, checkbox))
            stack.addArrangedSubview(checkbox)
        }

        stack.setCustomSpacing(14, after: checkboxes.last?.button ?? subtitleLabel)

        hintLabel = NSTextField(labelWithString: "Select at least two modifiers.")
        hintLabel.font = NSFont.systemFont(ofSize: 11)
        hintLabel.textColor = .systemRed
        stack.addArrangedSubview(hintLabel)

        if let options {
            let optionsHeader = NSTextField(labelWithString: options.header)
            optionsHeader.font = NSFont.boldSystemFont(ofSize: 12)
            stack.setCustomSpacing(14, after: hintLabel)
            stack.addArrangedSubview(optionsHeader)

            for (index, label) in options.labels.enumerated() {
                let checkbox = NSButton(checkboxWithTitle: label, target: self, action: #selector(selectionChanged))
                checkbox.state = options.initialStates[index] ? .on : .off
                optionButtons.append(checkbox)
                stack.addArrangedSubview(checkbox)
            }
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

    @objc private func selectionChanged() {
        refresh()
    }

    @objc private func restoreDefault() {
        for entry in checkboxes {
            entry.button.state = ModifierCombination.defaultModifiers.contains(entry.modifier) ? .on : .off
        }
        for (index, button) in optionButtons.enumerated() {
            button.state = options?.defaultStates[index] == true ? .on : .off
        }
        refresh()
    }

    @objc private func cancel() {
        dismiss(self)
    }

    @objc private func save() {
        let selected = selectedModifiers
        guard selected.isValid else { return }
        onSave?(selected, optionStates)
        dismiss(self)
    }

    /// Sync the validation hint, gesture walkthrough, and Save button to the currently checked
    /// modifiers and options. The walkthrough previews the combination in context (its lines
    /// embed the glyphs), so there is no separate preview line.
    private func refresh() {
        let selected = selectedModifiers

        hintLabel.isHidden = selected.isValid
        saveButton.isEnabled = selected.isValid

        walkthroughLabel.stringValue = walkthroughText(selected.isValid ? selected.displayString : "—", optionStates)
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

    /// The zone-navigation editor's option rows, in order; each row toggles one key group.
    private static let zoneNavigationOptionGroups: [ZoneNavigationKeyGroups] = [.arrows, .letters]

    /// The key groups the zone-navigation editor's option states select.
    static func zoneNavigationKeyGroups(fromOptionStates states: [Bool]) -> ZoneNavigationKeyGroups {
        zip(zoneNavigationOptionGroups, states).reduce(into: []) { groups, entry in
            if entry.1 { groups.insert(entry.0) }
        }
    }

    /// Editor for the modifiers and selection-key groups of keyboard zone navigation.
    static func zoneNavigation() -> ModifierCombinationSheetViewController {
        let current = ZoneNavigationKeyPreferences.shared.groups
        return ModifierCombinationSheetViewController(
            title: "Zone Navigation Modifiers",
            subtitle: "Choose the modifier keys to hold while navigating zones with the keyboard. "
                + "Select at least two.",
            walkthroughHeader: "How zone navigation works:",
            walkthroughText: { combo, optionStates in
                let groups = zoneNavigationKeyGroups(fromOptionStates: optionStates)
                guard !groups.isEmpty else {
                    return "• Zone navigation is off. Turn on the arrow keys or the letter keys above."
                }

                // The Launcher, Add Zone, Remove Zone, and Minimize steps borrow those shortcuts'
                // keys (claimed in that order), so show each key as currently configured — unless
                // an earlier in-gesture key leaves the borrowed key unreachable. The modifiers
                // appear only on the hold and release lines, and the reused-from attributions are
                // pooled into one closing note, so each action line stays short.
                var earlierBorrowedKeys: [CGKeyCode] = []
                var borrowedKeyNotes: [(key: String, source: String)] = []
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
                        keyCode, groups: groups, earlierBorrowedKeys: earlierBorrowedKeys
                    ) else {
                        return "• \(unavailableStep) is unavailable "
                            + "(the \(action.displayName) key \(key) already has another meaning in the gesture)"
                    }
                    earlierBorrowedKeys.append(keyCode)
                    borrowedKeyNotes.append((key, action.displayName))
                    return "• \(key): \(step)"
                }

                func naturalList(_ items: [String]) -> String {
                    items.count <= 2
                        ? items.joined(separator: " and ")
                        : items.dropLast().joined(separator: ", ") + ", and \(items.last ?? "")"
                }

                // The navigation keys of the enabled groups, indented under the hold line.
                var navigationKeyLines: [String] = []
                if groups.contains(.arrows) {
                    navigationKeyLines.append("    arrow keys: the next zone in that direction")
                }
                if groups.contains(.letters) {
                    navigationKeyLines += [
                        "    A/S/D/F: the top-left, top-right, bottom-left, or bottom-right zone",
                        "    G: the floating zone",
                        "    J/K/L: the first, second, or third display (its last-used window)",
                    ]
                }

                var lines = ["• Hold \(combo) and press a navigation key to put the blue circle on a zone:"]
                    + navigationKeyLines
                    + [
                        "• Release \(combo): focus this zone's window, or make it the destination if empty",
                        "While still holding \(combo):",
                        "• ↩ (Return): move the focused window into this zone (swaps if occupied)",
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
                            step: "remove this zone",
                            unavailableStep: "Removing this zone"
                        ),
                        borrowedKeyLine(
                            action: .minimizeActiveWindow,
                            step: "minimize this zone's window",
                            unavailableStep: "Minimizing this zone's window"
                        ),
                        "• ⎋ (Escape): cancel",
                    ]
                var notes: [String] = []
                if groups.contains(.letters) {
                    notes.append("A/S/D/F add the zone if the screen doesn't have it yet.")
                }
                if !borrowedKeyNotes.isEmpty {
                    let verb = borrowedKeyNotes.count == 1 ? "is" : "are"
                    let plural = borrowedKeyNotes.count == 1 ? "" : "s"
                    notes.append(
                        naturalList(borrowedKeyNotes.map(\.key)) + " \(verb) reused from the "
                            + naturalList(borrowedKeyNotes.map(\.source)) + " shortcut\(plural)."
                    )
                }
                if !notes.isEmpty {
                    lines.append(notes.joined(separator: " "))
                }
                return lines.joined(separator: "\n")
            },
            initialModifiers: ModifierCombinationPreferences.zoneNavigation.modifiers,
            options: Options(
                header: "Navigation keys:",
                labels: [
                    "Arrow keys move between zones",
                    "Letter keys jump to a zone (A/S/D/F, G) or a display (J/K/L)",
                ],
                initialStates: zoneNavigationOptionGroups.map { current.contains($0) },
                defaultStates: zoneNavigationOptionGroups.map { ZoneNavigationKeyGroups.all.contains($0) }
            )
        )
    }
}
