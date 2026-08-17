/// The sheet editing a held-modifier gesture: the modifier keys the gesture holds, laid out as
/// caps to switch on and off, and a walkthrough of what pressing or releasing does — as keycaps
/// and pictures rather than paragraphs. Each gesture's editor (`MouseGesturesSheetViewController`,
/// `ZoneNavigationSheetViewController`) supplies the copy, any section of its own between the two,
/// its walkthrough, and what saving stores.
import AppKit

class ModifierCombinationSheetViewController: NSViewController {
    /// The bottom section: mostly rows of "press this, and this happens". It never spells the
    /// chosen modifiers out — the lit caps above are the preview, and repeating their glyphs on
    /// every line only crowds the steps.
    struct Walkthrough {
        var items: [Item]
        /// False when the gesture can't run at all: every step is shown out of reach rather than
        /// described as if pressing its key would do something.
        var isReachable: Bool = true

        enum Item {
            /// A lead-in above a run of steps, e.g. "While still holding the modifier keys:".
            case heading(String)
            /// A full-width sentence, for a step of the gesture with no key of its own.
            case line(String)
            /// A run of key/action rows, laid out in `columns` columns, filled row by row so
            /// reading order matches the order the steps are declared in.
            case steps([Step], columns: Int)
        }

        struct Step {
            let trigger: Trigger
            let detail: String
            /// Dimmed when the current configuration can't reach this step.
            var isAvailable: Bool = true
        }

        /// What the user does, shown in the left column.
        enum Trigger {
            /// The cap of a fixed key, e.g. "esc".
            case key(String)
            /// The cap of a key the user can change, here or elsewhere: a click hands the cap to
            /// `action`, to anchor a recording or an explanation to. `help` is what assistive
            /// clients say a click does.
            case settableKey(label: String, help: String, isConflicting: Bool, action: (KeyCapButton) -> Void)
            /// A gesture with no key of its own, e.g. "double-click".
            case gesture(String)
            /// A step that can't be performed at all, so there is nothing to press.
            case unavailable
        }
    }

    // MARK: - Configuration

    private let sheetTitle: String
    private let subtitle: String
    private let modifiersHint: String
    private let walkthroughHeader: String
    private let initialModifiers: ModifierCombination

    // MARK: - Layout metrics

    static let sheetWidth: CGFloat = 620
    static let edgeInset: CGFloat = 20
    static let cardInset: CGFloat = 11
    /// Usable width inside a section card.
    static var cardContentWidth: CGFloat { sheetWidth - edgeInset * 2 - cardInset * 2 }
    /// Gap between a walkthrough row's trigger column and its description.
    private static let triggerDetailGap: CGFloat = 12
    /// Gap between the walkthrough's columns.
    private static let walkthroughColumnGap: CGFloat = 20
    /// Gap between the scrolling content and the pinned button row below it.
    private static let buttonRowGap: CGFloat = 12

    // MARK: - Views

    private var modifierCaps: [ModifierKeyCapButton] = []
    private var modifiersHintLabel: NSTextField!
    private var conflictWarningRow: NSStackView!
    private var conflictWarningLabel: NSTextField!
    /// The last conflict shown, so a refresh can tell a new or changed warning from a repeat.
    private var shownConflictWarning: String?
    private var walkthroughStack: NSStackView!
    private var saveButton: NSButton!
    private var documentView: NSView?
    private var buttonRow: NSView?
    private var contentHeightConstraint: NSLayoutConstraint?

    init(
        title: String,
        subtitle: String,
        modifiersHint: String,
        walkthroughHeader: String,
        initialModifiers: ModifierCombination
    ) {
        self.sheetTitle = title
        self.subtitle = subtitle
        self.modifiersHint = modifiersHint
        self.walkthroughHeader = walkthroughHeader
        self.initialModifiers = initialModifiers
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// The combination the lit caps show.
    var selectedModifiers: ModifierCombination {
        modifierCaps.reduce(into: []) { result, cap in
            if cap.isOn { result.insert(cap.modifier) }
        }
    }

    // MARK: - What each editor supplies

    /// Sections of the editor's own, placed between the modifiers and the walkthrough.
    func makeOwnSections() -> [NSView] { [] }

    /// The walkthrough for the current state; rebuilt on every refresh.
    func makeWalkthrough() -> Walkthrough { Walkthrough(items: []) }

    /// The conflict the current state would have with the configured shortcuts, shown under the
    /// modifier caps as they are toggled — so nothing is saved into a surprise. Consulted only
    /// while the combination is valid.
    func conflictWarning() -> String? { nil }

    /// Stores what the editor edits; called on Save, with a valid combination.
    func commit(_ modifiers: ModifierCombination) {}

    // MARK: - Building the sheet

    override func loadView() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(
            top: Self.edgeInset, left: Self.edgeInset, bottom: 6, right: Self.edgeInset)
        stack.translatesAutoresizingMaskIntoConstraints = false

        stack.addArrangedSubview(makeHeader())
        stack.addArrangedSubview(makeModifiersSection())
        for section in makeOwnSections() {
            stack.addArrangedSubview(section)
        }
        stack.addArrangedSubview(makeWalkthroughSection())

        // The sections scroll and the buttons stay put, so the sheet still fits — and can still be
        // confirmed — on a display too short for the whole walkthrough.
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        // Overlay scrollers float above the content, so its width never depends on whether the
        // walkthrough happens to overflow.
        scrollView.scrollerStyle = .overlay
        scrollView.documentView = document
        let heightConstraint = scrollView.heightAnchor.constraint(equalToConstant: 400)
        contentHeightConstraint = heightConstraint

        let buttonRow = makeButtonRow()
        self.buttonRow = buttonRow
        let container = NSView(frame: NSRect(x: 0, y: 0, width: Self.sheetWidth, height: 10))
        container.addSubview(scrollView)
        container.addSubview(buttonRow)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),

            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            heightConstraint,

            buttonRow.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: Self.buttonRowGap),
            buttonRow.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Self.edgeInset),
            buttonRow.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Self.edgeInset),
            buttonRow.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -Self.edgeInset),
            container.widthAnchor.constraint(equalToConstant: Self.sheetWidth),
        ])
        self.view = container
        self.documentView = document

        refresh()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        updateContentHeight()
    }

    /// Size the scrolling area to its content, but never past what the screen can show.
    private func updateContentHeight() {
        guard let documentView, let contentHeightConstraint else { return }
        let natural = documentView.fittingSize.height
        let screenHeight = (view.window?.screen ?? NSScreen.main)?.visibleFrame.height ?? 900
        // Subtract what sits below the scroll area rather than guessing past it, so the button row
        // stays on screen even on a very short display.
        let chrome = Self.buttonRowGap + Self.edgeInset + (buttonRow?.fittingSize.height ?? 32)
        let ceiling = max(120, screenHeight - 120 - chrome)
        contentHeightConstraint.constant = min(natural, ceiling)
    }

    private func makeHeader() -> NSView {
        let title = NSTextField(labelWithString: sheetTitle)
        title.font = NSFont.systemFont(ofSize: 15, weight: .semibold)

        let subtitleLabel = NSTextField(wrappingLabelWithString: subtitle)
        subtitleLabel.font = NSFont.systemFont(ofSize: 12)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.preferredMaxLayoutWidth = Self.sheetWidth - Self.edgeInset * 2

        let stack = NSStackView(views: [title, subtitleLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        return stack
    }

    /// The modifier caps, laid out as the row of keys the gesture holds down, with the validation
    /// hint beside them rather than under them so the row costs one line, and the conflict line
    /// under them: the hint has one job (validity), and a conflict names shortcuts, which needs the
    /// width. The mark there is decoration — the label beside it says what is wrong.
    private func makeModifiersSection() -> NSView {
        let capRow = NSStackView()
        capRow.orientation = .horizontal
        capRow.alignment = .centerY
        capRow.spacing = 8
        for entry in ModifierCombination.displayOrder {
            let cap = ModifierKeyCapButton(entry: entry)
            cap.isOn = initialModifiers.contains(entry.modifier)
            cap.onToggle = { [weak self] in self?.refresh() }
            modifierCaps.append(cap)
            capRow.addArrangedSubview(cap)
        }

        modifiersHintLabel = makeHintLabel(modifiersHint)
        if let lastCap = modifierCaps.last {
            capRow.setCustomSpacing(14, after: lastCap)
        }
        capRow.addArrangedSubview(modifiersHintLabel)

        conflictWarningLabel = makeHintLabel("")
        conflictWarningRow = NSStackView(views: [ConflictWarningView(), conflictWarningLabel])
        conflictWarningRow.orientation = .horizontal
        conflictWarningRow.alignment = .firstBaseline
        conflictWarningRow.spacing = 5
        return makeSection(header: "Modifier keys", content: [capRow, conflictWarningRow])
    }

    private func makeWalkthroughSection() -> NSView {
        walkthroughStack = NSStackView()
        walkthroughStack.orientation = .vertical
        walkthroughStack.alignment = .leading
        walkthroughStack.spacing = 4
        return makeSection(header: walkthroughHeader, content: [walkthroughStack])
    }

    private func makeButtonRow() -> NSView {
        let restoreButton = NSButton(title: "Restore Defaults", target: self, action: #selector(restoreDefaults))
        restoreButton.bezelStyle = .rounded
        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}" // Escape
        saveButton = NSButton(title: "Save", target: self, action: #selector(save))
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r" // Return

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [restoreButton, spacer, cancelButton, saveButton])
        row.orientation = .horizontal
        row.spacing = 10
        row.widthAnchor.constraint(equalToConstant: Self.sheetWidth - Self.edgeInset * 2).isActive = true
        return row
    }

    /// A small header above a card holding `content`, matching the grouped look of System Settings.
    func makeSection(header: String, content: [NSView]) -> NSView {
        let headerLabel = NSTextField(labelWithString: header)
        headerLabel.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        headerLabel.textColor = .secondaryLabelColor

        let card = SectionCardView()
        let inner = NSStackView(views: content)
        inner.translatesAutoresizingMaskIntoConstraints = false
        inner.orientation = .vertical
        inner.alignment = .leading
        inner.spacing = 6
        card.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.topAnchor.constraint(equalTo: card.topAnchor, constant: Self.cardInset),
            inner.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Self.cardInset),
            inner.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -Self.cardInset),
            inner.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -Self.cardInset),
            card.widthAnchor.constraint(equalToConstant: Self.sheetWidth - Self.edgeInset * 2),
        ])

        let section = NSStackView(views: [headerLabel, card])
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 5
        return section
    }

    /// Small secondary print, wrapping to the card's width.
    func makeHintLabel(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = NSFont.systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = Self.cardContentWidth
        return label
    }

    // MARK: - Actions

    /// Puts the factory settings back: an editor with settings of its own resets them first, then
    /// calls up to reset the modifiers and refresh.
    @objc func restoreDefaults() {
        for cap in modifierCaps {
            cap.isOn = ModifierCombination.defaultModifiers.contains(cap.modifier)
        }
        refresh()
    }

    @objc private func cancel() {
        dismiss(self)
    }

    @objc private func save() {
        let selected = selectedModifiers
        guard selected.isValid else { return }
        commit(selected)
        dismiss(self)
    }

    // MARK: - Syncing to the current selection

    /// Sync the hints, walkthrough, and Save button to the current state. The lit caps are the
    /// preview of the chosen combination, so nothing below repeats it. An editor with views of its
    /// own updates them, then calls up.
    func refresh() {
        let selected = selectedModifiers

        modifiersHintLabel.textColor = selected.isValid ? .secondaryLabelColor : .systemRed
        saveButton.isEnabled = selected.isValid

        // An invalid combination is already flagged in red and can't be saved, so its conflicts
        // are moot.
        let warning = selected.isValid ? conflictWarning() : nil
        conflictWarningLabel.stringValue = warning.map { "\($0)." } ?? ""
        conflictWarningRow.isHidden = warning == nil
        // A warning that appears, changes, or clears on a shown sheet is spoken: it lands away from
        // the cap or checkbox that was just toggled, where VoiceOver's attention is. A warning that
        // merely went unchecked because the combination turned invalid isn't called clear.
        if view.window != nil, warning != shownConflictWarning,
           let announcement = warning ?? (selected.isValid ? "No shortcut conflict" : nil) {
            NSAccessibility.post(
                element: view, notification: .announcementRequested,
                userInfo: [.announcement: announcement, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
        shownConflictWarning = warning

        rebuildWalkthrough(makeWalkthrough())
        updateContentHeight()
    }

    private func rebuildWalkthrough(_ content: Walkthrough) {
        for view in walkthroughStack.arrangedSubviews {
            walkthroughStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        /// Appends `view`, opening a gap above it when it follows something.
        func append(_ view: NSView, gapAbove: CGFloat = 0) {
            if gapAbove > 0, let previous = walkthroughStack.arrangedSubviews.last {
                walkthroughStack.setCustomSpacing(gapAbove, after: previous)
            }
            walkthroughStack.addArrangedSubview(view)
        }

        func makeText(_ string: String, weight: NSFont.Weight, isAvailable: Bool) -> NSTextField {
            let label = NSTextField(wrappingLabelWithString: string)
            label.font = NSFont.systemFont(ofSize: 12, weight: weight)
            label.textColor = isAvailable ? .labelColor : .tertiaryLabelColor
            label.preferredMaxLayoutWidth = Self.cardContentWidth
            return label
        }

        for item in content.items {
            switch item {
            case .heading(let text):
                append(makeText(text, weight: .medium, isAvailable: content.isReachable), gapAbove: 12)

            case .line(let text):
                append(makeText(text, weight: .regular, isAvailable: content.isReachable))

            case .steps(let steps, let columns):
                // One trigger-column width across the block, so every description in it starts at
                // the same x however wide each row's caps or gesture name happen to be.
                let triggers = steps.map { makeTriggerView(for: $0, isReachable: content.isReachable) }
                let triggerWidth = triggers.map { $0.fittingSize.width }.max() ?? 0
                let gaps = Self.walkthroughColumnGap * CGFloat(columns - 1)
                let columnWidth = (Self.cardContentWidth - gaps) / CGFloat(columns)
                let detailWidth = columnWidth - triggerWidth - Self.triggerDetailGap

                func makeCell(_ index: Int) -> NSView {
                    let step = steps[index]
                    let detail = makeText(
                        step.detail, weight: .regular,
                        isAvailable: step.isAvailable && content.isReachable)
                    detail.preferredMaxLayoutWidth = detailWidth
                    detail.widthAnchor.constraint(equalToConstant: detailWidth).isActive = true

                    let trigger = triggers[index]
                    let slot = BaselineSlotView()
                    slot.translatesAutoresizingMaskIntoConstraints = false
                    slot.addSubview(trigger)
                    NSLayoutConstraint.activate([
                        slot.widthAnchor.constraint(equalToConstant: triggerWidth),
                        slot.heightAnchor.constraint(equalTo: trigger.heightAnchor),
                        trigger.leadingAnchor.constraint(equalTo: slot.leadingAnchor),
                        trigger.topAnchor.constraint(equalTo: slot.topAnchor),
                    ])

                    let cell = NSStackView(views: [slot, detail])
                    cell.orientation = .horizontal
                    cell.alignment = .firstBaseline
                    cell.spacing = Self.triggerDetailGap
                    return cell
                }

                // Filled row by row: the view hierarchy is rows, so this is the order assistive
                // tech walks, and left-to-right reading then matches the order the steps are
                // declared in.
                for rowIndex in stride(from: 0, to: steps.count, by: columns) {
                    let cells = (rowIndex..<min(rowIndex + columns, steps.count)).map(makeCell)
                    let row = NSStackView(views: cells)
                    row.orientation = .horizontal
                    row.alignment = .top
                    row.spacing = Self.walkthroughColumnGap
                    append(row)
                }
            }
        }
    }

    /// The left column of one walkthrough row. Every branch clears
    /// `translatesAutoresizingMaskIntoConstraints`: the result is positioned with constraints
    /// inside a `BaselineSlotView`, and a view still translating its (zero) frame would fight them.
    private func makeTriggerView(for step: Walkthrough.Step, isReachable: Bool) -> NSView {
        let isAvailable = step.isAvailable && isReachable
        let trigger = makeTriggerContent(for: step, isAvailable: isAvailable)
        trigger.translatesAutoresizingMaskIntoConstraints = false
        return trigger
    }

    private func makeTriggerContent(for step: Walkthrough.Step, isAvailable: Bool) -> NSView {
        switch step.trigger {
        case .key(let label):
            let cap = KeyCapView(label: label)
            cap.isEnabled = isAvailable
            return cap
        case .settableKey(let label, let help, let isConflicting, let action):
            let cap = KeyCapButton(label: label)
            cap.isConflicting = isConflicting
            cap.isEnabled = isAvailable
            cap.onClick = action
            cap.setAccessibilityLabel(KeyCap.spokenName(for: label))
            cap.setAccessibilityHelp(help)
            return cap
        case .gesture(let name):
            let label = NSTextField(labelWithString: name)
            label.font = NSFont.systemFont(ofSize: 12, weight: .medium)
            label.textColor = isAvailable ? .labelColor : .tertiaryLabelColor
            return label
        case .unavailable:
            return EmptyTriggerView()
        }
    }
}

/// Top-anchors the scrolling content, so short content sits at the top of the sheet rather than
/// against its bottom edge.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// The blank trigger of a step that can't be performed. It states a zero intrinsic size rather
/// than leaving one to the autoresizing mask, which no longer supplies a frame once translation is
/// disabled — an unsized subview would make the slot's height ambiguous.
private final class EmptyTriggerView: NSView {
    override var intrinsicContentSize: NSSize { .zero }
}

/// Holds one walkthrough trigger in a fixed-width column, passing its child's baseline through so
/// the description beside it sits on the same line as the cap. A plain container reports no
/// baseline of its own, which would shove every row out of alignment.
private final class BaselineSlotView: NSView {
    override var firstBaselineOffsetFromTop: CGFloat {
        subviews.first?.firstBaselineOffsetFromTop ?? 0
    }
}

/// The rounded, filled container behind one section of the sheet.
private final class SectionCardView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        NSColor.controlBackgroundColor.setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}
