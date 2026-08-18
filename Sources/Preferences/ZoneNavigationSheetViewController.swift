/// The Zone Navigation editor: the modifiers held, which navigation-key groups are on, the key
/// behind each jump, and the walkthrough of the in-gesture actions. Keys the user can change are
/// white caps: clicking one records a replacement in place. The keys borrowed from the shortcut
/// table (Return, Space, =, -, M by default) are white too, and clicking one says which shortcut
/// to change instead; the arrows and Escape are gray, being fixed. Everything is staged in the
/// sheet and stored on Save.
import AppKit

final class ZoneNavigationSheetViewController: ModifierCombinationSheetViewController {
    /// Called with the chosen combination and keys when the user confirms (the combination is
    /// guaranteed valid).
    var onSave: ((ModifierCombination, ZoneNavigationKeys) -> Void)?

    /// The keys as edited so far.
    private var keys = ZoneNavigationKeyPreferences.shared.keys
    /// The conflicts the current modifiers and keys would have with the configured shortcuts,
    /// recomputed on every refresh, and the key codes of the gesture's chords among them (none
    /// while the combination is invalid — its conflicts are moot).
    private var conflicts = ShortcutConflicts.current()
    private var contestedKeyCodes: Set<CGKeyCode> = []

    // MARK: - Views

    private var groupCheckboxes: [(group: ZoneNavigationKeyGroups, checkbox: NSButton)] = []
    private var groupIllustrations: [KeyGroupIllustrationView] = []
    private var arrowsDiagram: ArrowKeysDiagramView!
    private var jumpCaps: [ZoneNavigationKey: KeyCapButton] = [:]
    /// Under the pictograms: how to change a key, what a recording is waiting for, or that the
    /// gesture is off.
    private var keysHintLabel: NSTextField!
    private var lastAnnouncedHint: String?
    private var popover: NSPopover?

    // MARK: - Recording

    private let recorder = ShortcutRecorder()
    private var recording: (jump: ZoneNavigationKey, cap: KeyCapButton)?
    /// Why the last key pressed while recording was refused; shown until another is pressed.
    private var refusal: String?

    /// Gap between the key groups, which sit side by side.
    private static let groupColumnGap: CGFloat = 20
    /// Width of one pictogram column. The card holds three of them — the arrow cluster, the zone
    /// grid, and the displays — with the two jump-key columns grouped under one checkbox.
    private static var diagramColumnWidth: CGFloat {
        ((cardContentWidth - groupColumnGap - KeyGroupIllustrationView.columnGap) / 3).rounded(.down)
    }

    init() {
        super.init(
            title: "Zone Navigation",
            subtitle: "Hold the modifier keys and press a navigation key: a blue circle highlights a zone.",
            modifiersHint: "Select at least two.",
            walkthroughHeader: "Acting on this zone",
            initialModifiers: ModifierCombinationPreferences.zoneNavigation.modifiers
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        recorder.stop()
        popover?.close()
    }

    // MARK: - Navigation keys section

    /// The key-group checkboxes side by side, each above the pictograms of where its keys land,
    /// with the hint line under them all.
    override func makeOwnSections() -> [NSView] {
        arrowsDiagram = ArrowKeysDiagramView()
        let zoneDiagram = ZoneJumpKeysDiagramView()
        let displayDiagram = DisplayJumpKeysDiagramView()
        jumpCaps = zoneDiagram.caps.merging(displayDiagram.caps) { first, _ in first }
        for (jump, cap) in jumpCaps {
            cap.onClick = { [weak self] cap in self?.capClicked(cap, jump: jump) }
            cap.setAccessibilityHelp("Click to change the key.")
        }

        let groups: [(group: ZoneNavigationKeyGroups, label: String, diagrams: [(diagram: KeyDiagramView, caption: String)])] = [
            (.arrows, "Arrow keys", [
                (arrowsDiagram, "Step to the next zone in that direction. The Floating Zone Bar is the bottom stop."),
            ]),
            (.jumps, "Jump keys", [
                (zoneDiagram, "Jump to that zone, adding it if it isn't there yet. The key on the bar is the floating zone."),
                (displayDiagram, "Jump to that display."),
            ]),
        ]
        // One band height across every pictogram, so all the captions start on the same line.
        let bandHeight = groups.flatMap(\.diagrams).map(\.diagram.intrinsicContentSize.height).max() ?? 0

        var columns: [NSView] = []
        for entry in groups {
            let checkbox = NSButton(checkboxWithTitle: entry.label, target: self, action: #selector(groupToggled))
            checkbox.state = keys.groups.contains(entry.group) ? .on : .off
            checkbox.font = NSFont.systemFont(ofSize: 13)
            groupCheckboxes.append((entry.group, checkbox))

            let illustration = KeyGroupIllustrationView(
                items: entry.diagrams, columnWidth: Self.diagramColumnWidth, bandHeight: bandHeight)
            groupIllustrations.append(illustration)

            let column = NSStackView(views: [checkbox, illustration])
            column.orientation = .vertical
            column.alignment = .leading
            column.spacing = 6
            columns.append(column)
        }
        let groupRow = NSStackView(views: columns)
        groupRow.orientation = .horizontal
        groupRow.alignment = .top
        groupRow.spacing = Self.groupColumnGap

        // The hint is the card's footer: set off from the captions above it, so it doesn't read as
        // one more caption line.
        keysHintLabel = makeHintLabel("")
        let content = NSStackView(views: [groupRow, keysHintLabel])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 12
        return [makeSection(header: "Navigation keys", content: [content])]
    }

    @objc private func groupToggled() {
        refresh()
    }

    // MARK: - Walkthrough

    /// The steps of the gesture. The Move, Launcher, Add Zone, Remove Zone, and Minimize steps
    /// borrow those shortcuts' keys (claimed in that order), so each shows the key as currently
    /// configured — unless an earlier in-gesture key leaves the borrowed key unreachable.
    override func makeWalkthrough() -> Walkthrough {
        var earlierBorrowedKeys: [CGKeyCode] = []
        func borrowedStep(
            action: KeyboardShortcutPreferences.ShortcutAction,
            detail: String,
            unavailableStep: String
        ) -> Walkthrough.Step {
            guard let shortcut = KeyboardShortcutPreferences.shared.shortcut(for: action) else {
                return Walkthrough.Step(
                    trigger: .unavailable,
                    detail: "\(unavailableStep) is unavailable (no \(action.displayName) shortcut is set)",
                    isAvailable: false
                )
            }
            let keyCode = CGKeyCode(shortcut.keyCode)
            let key = shortcut.keyDisplayString
            guard !ZoneNavigationInterceptor.shadowsBorrowedKey(
                keyCode, keys: keys, earlierBorrowedKeys: earlierBorrowedKeys
            ) else {
                return Walkthrough.Step(
                    trigger: .unavailable,
                    detail: "\(unavailableStep) is unavailable (the \(action.displayName) key \(key) "
                        + "already has another meaning in the gesture)",
                    isAvailable: false
                )
            }
            earlierBorrowedKeys.append(keyCode)
            let explanation = Self.borrowedKeyExplanation(action: action, key: key)
            return Walkthrough.Step(
                trigger: .settableKey(label: key, help: explanation, isConflicting: false) { [weak self] cap in
                    self?.explainBorrowedKey(explanation, at: cap)
                },
                detail: detail
            )
        }

        let items: [Walkthrough.Item] = [
            .line("Release the modifier keys: focus this zone's window, or make it the "
                + "destination if empty."),
            .heading("While still holding the modifier keys:"),
            .steps([
                borrowedStep(
                    action: .moveFocusedWindowToTargetZone,
                    detail: "Move the focused window into this zone (swaps if occupied)",
                    unavailableStep: "Moving the focused window into this zone"
                ),
                borrowedStep(
                    action: .showLauncher,
                    detail: "Make this zone the destination and open the Launcher",
                    unavailableStep: "Opening the Launcher on this zone"
                ),
                borrowedStep(action: .addZone, detail: "Add a zone", unavailableStep: "Adding a zone"),
                borrowedStep(
                    action: .removeZone, detail: "Remove this zone", unavailableStep: "Removing this zone"),
                borrowedStep(
                    action: .minimizeActiveWindow,
                    detail: "Minimize this zone's window",
                    unavailableStep: "Minimizing this zone's window"
                ),
                Walkthrough.Step(trigger: .key("esc"), detail: "Cancel"),
            ], columns: 2),
        ]

        // With no navigation keys there is nothing to select, so the whole gesture is out of reach.
        return Walkthrough(items: items, isReachable: !keys.groups.isEmpty)
    }

    override func conflictWarning() -> String? {
        conflicts.description(for: .zoneNavigation)
    }

    override func commit(_ modifiers: ModifierCombination) {
        onSave?(modifiers, keys)
    }

    override func restoreDefaults() {
        keys = .default
        for entry in groupCheckboxes {
            entry.checkbox.state = keys.groups.contains(entry.group) ? .on : .off
        }
        super.restoreDefaults()
    }

    /// Sync the staged keys to the checkboxes, then the pictograms, marks, and hint to the staged
    /// keys. Any recording in progress is over: the walkthrough is about to be rebuilt under it.
    override func refresh() {
        recorder.stop()
        keys.groups = groupCheckboxes.reduce(into: []) { groups, entry in
            if entry.checkbox.state == .on { groups.insert(entry.group) }
        }

        let selected = selectedModifiers
        conflicts = ShortcutConflicts.current(zoneNavigationModifiers: selected, zoneNavigationKeys: keys)
        contestedKeyCodes = selected.isValid
            ? Set(conflicts.conflicts(of: .zoneNavigation).compactMap { CGKeyCode(exactly: $0.shortcut.keyCode) })
            : []

        for (jump, cap) in jumpCaps {
            let keyCode = keys[jump]
            cap.label = Self.label(for: keyCode)
            cap.isConflicting = contestedKeyCodes.contains(keyCode)
            cap.setAccessibilityLabel("\(KeyCap.spokenName(for: cap.label)) key for \(jump.purpose)")
        }
        arrowsDiagram.contestedKeyCodes = contestedKeyCodes
        for (index, illustration) in groupIllustrations.enumerated() {
            illustration.isEnabled = keys.groups.contains(groupCheckboxes[index].group)
        }
        updateKeysHint()

        super.refresh()
    }

    // MARK: - Recording a key

    /// A click on a jump's cap starts recording into it — or, on the cap already recording, stops.
    private func capClicked(_ cap: KeyCapButton, jump: ZoneNavigationKey) {
        popover?.close()
        if recording?.cap === cap {
            recorder.stop()
            return
        }
        let started = recorder.start(
            recordingControl: { [weak cap] in cap },
            onKey: { [weak self] keyCode, _ in self?.record(keyCode, for: jump) },
            onEnd: { [weak self] in self?.recordingEnded() }
        )
        guard started else { return }
        recording = (jump, cap)
        refusal = nil
        cap.isRecording = true
        updateKeysHint()
    }

    /// Takes the pressed key for the recording jump, or refuses it and keeps listening. Held
    /// modifiers are ignored: the gesture's own modifiers are what will be held.
    private func record(_ keyCode: CGKeyCode, for jump: ZoneNavigationKey) {
        if let reason = refusalReason(for: keyCode, jump: jump) {
            refusal = reason
            updateKeysHint()
            return
        }
        keys[jump] = keyCode
        // Redraws everything around the new key, ending the recording on the way.
        refresh()
    }

    private func recordingEnded() {
        recording?.cap.isRecording = false
        recording = nil
        refusal = nil
        updateKeysHint()
    }

    /// Why `keyCode` can't be `jump`'s key, in words, or nil when it can.
    private func refusalReason(for keyCode: CGKeyCode, jump: ZoneNavigationKey) -> String? {
        switch keys.rejection(of: keyCode, as: jump) {
        case nil: return nil
        case .unnamed: return "That key can't be used here. Press another key."
        case .arrow: return "The arrow keys always step. Press another key."
        case .escape: return "Escape always cancels. Press another key."
        case .inUse: return "\(Self.label(for: keyCode)) is already used in this gesture. Press another key."
        }
    }

    private func updateKeysHint() {
        let text: String
        var color = NSColor.secondaryLabelColor
        if keys.groups.isEmpty {
            // The gesture can't start without a key to press, so flag it where it is fixed.
            text = "Zone navigation is off. Turn on the arrow keys or the jump keys."
            color = .systemRed
        } else if let recording {
            if let refusal {
                text = refusal
                color = .systemRed
            } else {
                text = "Press a key for \(recording.jump.purpose). Escape keeps \(Self.label(for: keys[recording.jump]))."
            }
        } else {
            text = "Click a white key to change it."
        }
        keysHintLabel.stringValue = text
        keysHintLabel.textColor = color

        // A recording's prompt and refusals are spoken: they land away from the cap that was just
        // clicked, where VoiceOver's attention is.
        if recording != nil, text != lastAnnouncedHint {
            NSAccessibility.post(
                element: view, notification: .announcementRequested,
                userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
        lastAnnouncedHint = recording != nil ? text : nil
    }

    // MARK: - Borrowed keys

    private static func borrowedKeyExplanation(action: KeyboardShortcutPreferences.ShortcutAction, key: String) -> String {
        "\(key) is the \(action.displayName) shortcut's key. To change it, change that shortcut in the Shortcuts list."
    }

    /// Says, in a popover on the cap, which table shortcut sets a borrowed key.
    private func explainBorrowedKey(_ explanation: String, at cap: KeyCapButton) {
        popover?.close()
        let text = NSTextField(wrappingLabelWithString: explanation)
        text.font = NSFont.systemFont(ofSize: 12)
        text.preferredMaxLayoutWidth = 250
        text.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(text)
        NSLayoutConstraint.activate([
            // Pinned to a width: a wrapping label yields horizontally, and the popover's fitting
            // size would otherwise squeeze it to its longest word.
            text.widthAnchor.constraint(equalToConstant: 250),
            text.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            text.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            text.topAnchor.constraint(equalTo: content.topAnchor, constant: 10),
            text.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
        ])
        let controller = NSViewController()
        controller.view = content

        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = controller
        popover.contentSize = content.fittingSize
        popover.show(relativeTo: cap.bounds, of: cap, preferredEdge: .maxY)
        self.popover = popover
    }

    private static func label(for keyCode: CGKeyCode) -> String {
        KeyboardShortcut.keyLabel(forKeyCode: UInt32(keyCode)) ?? "?"
    }
}

private extension ZoneNavigationKey {
    /// What the key is for, as the recording prompt and the caps' spoken names put it.
    var purpose: String {
        switch self {
        case .zone(.topLeft): return "the top-left zone"
        case .zone(.topRight): return "the top-right zone"
        case .zone(.bottomLeft): return "the bottom-left zone"
        case .zone(.bottomRight): return "the bottom-right zone"
        case .floatingZone: return "the floating zone"
        case .display(let ordinal):
            let ordinals = ["first", "second", "third"]
            return "the \(ordinals.indices.contains(ordinal) ? ordinals[ordinal] : "\(ordinal + 1)th") display"
        case .move: return "stepping"
        }
    }
}
