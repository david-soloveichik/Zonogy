/// Modal sheet for choosing the keys behind one of Zonogy's held-modifier gestures: which
/// modifiers activate it, which key groups it listens for, and a walkthrough of what each key does
/// once it is running. One implementation serves both editors; the factories at the bottom supply
/// each gesture family's copy and current settings.
///
/// The sheet is built as sections of caps and pictures rather than paragraphs: the modifiers are
/// keycaps you switch on, the navigation keys are drawn where they land (see
/// `ZoneNavigationDiagramViews.swift`), and the walkthrough pairs a cap with the one thing that
/// key does.
import AppKit

final class ModifierCombinationSheetViewController: NSViewController {
    // MARK: - What an editor supplies

    /// Extra checkboxes shown under their own header, each illustrated by a pictogram. Their
    /// on/off states are passed to `walkthrough` and `onSave` (empty when the sheet has none).
    struct Options {
        let header: String
        let rows: [Row]
        /// Shown in place of the header's hint when every row is off.
        let allOffWarning: String

        struct Row {
            let label: String
            let initialState: Bool
            /// The state Restore Default selects.
            let defaultState: Bool
            /// Pictograms of what this row's keys select, with their captions. The sheet lays them
            /// out, since the column band has to be sized across every row at once.
            let diagrams: () -> [(diagram: KeyDiagramView, caption: String)]
        }
    }

    /// The bottom section: mostly rows of "press this, and this happens", with a closing note in
    /// small print. It never spells the chosen modifiers out — the lit caps above are the preview,
    /// and repeating their glyphs on every line only crowds the steps.
    struct Walkthrough {
        var items: [Item]
        /// For example, which shortcuts the mid-gesture keys borrow.
        var note: String?
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
            /// Keycaps, e.g. ["↩"] or ["esc"].
            case keys([String])
            /// A gesture with no key of its own, e.g. "double-click".
            case gesture(String)
            /// A step that can't be performed at all, so there is nothing to press.
            case unavailable
        }
    }

    /// Called with the chosen combination and option states when the user confirms
    /// (the combination is guaranteed valid).
    var onSave: ((ModifierCombination, [Bool]) -> Void)?

    // MARK: - Configuration

    private let sheetTitle: String
    private let subtitle: String
    private let modifiersHint: String
    private let walkthroughHeader: String
    /// Builds the walkthrough for the current option states. It takes no modifiers: the sheet
    /// names them rather than spelling them out, so the steps don't change with the combination.
    private let walkthrough: ([Bool]) -> Walkthrough
    /// The conflict a candidate combination and option states would have with the configured
    /// shortcuts (nil for none), shown under the modifier caps as they are toggled — so nothing is
    /// saved into a surprise. Consulted only while the combination is valid.
    private let conflictWarning: ((ModifierCombination, [Bool]) -> String?)?
    private let initialModifiers: ModifierCombination
    private let options: Options?

    // MARK: - Layout metrics

    private static let sheetWidth: CGFloat = 620
    private static let edgeInset: CGFloat = 20
    private static let cardInset: CGFloat = 11
    /// Usable width inside a section card.
    private static var cardContentWidth: CGFloat { sheetWidth - edgeInset * 2 - cardInset * 2 }
    /// Gap between the key groups, which sit side by side.
    private static let optionColumnGap: CGFloat = 20
    /// Gap between a walkthrough row's trigger column and its description.
    private static let triggerDetailGap: CGFloat = 12
    /// Gap between the walkthrough's columns.
    private static let walkthroughColumnGap: CGFloat = 20
    /// Gap between the scrolling content and the pinned button row below it.
    private static let buttonRowGap: CGFloat = 12

    /// Width of one pictogram column. The card holds three of them — the arrow cluster, the zone
    /// grid, and the displays — with the two letter-key columns grouped under one checkbox.
    private static var diagramColumnWidth: CGFloat {
        ((cardContentWidth - optionColumnGap - KeyGroupIllustrationView.columnGap) / 3).rounded(.down)
    }

    // MARK: - Views

    private var modifierCaps: [ModifierKeyCapButton] = []
    private var optionButtons: [NSButton] = []
    private var optionIllustrations: [KeyGroupIllustrationView] = []
    private var modifiersHintLabel: NSTextField!
    private var conflictWarningRow: NSStackView?
    private var conflictWarningLabel: NSTextField?
    /// The last conflict shown, so a refresh can tell a new or changed warning from a repeat.
    private var shownConflictWarning: String?
    private var optionsHintLabel: NSTextField?
    private var walkthroughStack: NSStackView!
    private var saveButton: NSButton!
    private var documentView: NSView?
    private var buttonRow: NSView?
    private var contentHeightConstraint: NSLayoutConstraint?

    private init(
        title: String,
        subtitle: String,
        modifiersHint: String,
        walkthroughHeader: String,
        walkthrough: @escaping ([Bool]) -> Walkthrough,
        conflictWarning: ((ModifierCombination, [Bool]) -> String?)? = nil,
        initialModifiers: ModifierCombination,
        options: Options? = nil
    ) {
        self.sheetTitle = title
        self.subtitle = subtitle
        self.modifiersHint = modifiersHint
        self.walkthroughHeader = walkthroughHeader
        self.walkthrough = walkthrough
        self.conflictWarning = conflictWarning
        self.initialModifiers = initialModifiers
        self.options = options
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private var selectedModifiers: ModifierCombination {
        modifierCaps.reduce(into: []) { result, cap in
            if cap.isOn { result.insert(cap.modifier) }
        }
    }

    private var optionStates: [Bool] {
        optionButtons.map { $0.state == .on }
    }

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
        if let options {
            stack.addArrangedSubview(makeOptionsSection(options))
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
    /// hint beside them rather than under them so the row costs one line.
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

        // The conflict line sits under the caps rather than in the hint beside them: the hint has
        // one job (validity), and a conflict names shortcuts, which needs the width. The mark is
        // decoration here — the label beside it says what is wrong.
        guard conflictWarning != nil else {
            return makeSection(header: "Modifier keys", content: [capRow])
        }
        let warningLabel = makeHintLabel("")
        let warningRow = NSStackView(views: [ConflictWarningView(), warningLabel])
        warningRow.orientation = .horizontal
        warningRow.alignment = .firstBaseline
        warningRow.spacing = 5
        conflictWarningRow = warningRow
        conflictWarningLabel = warningLabel
        return makeSection(header: "Modifier keys", content: [capRow, warningRow])
    }

    /// The key-group checkboxes side by side, each above the pictograms of where its keys land.
    private func makeOptionsSection(_ options: Options) -> NSView {
        // One band height across every pictogram, so all the captions start on the same line.
        let diagramsPerRow = options.rows.map { $0.diagrams() }
        let bandHeight = diagramsPerRow
            .flatMap { $0 }
            .map(\.diagram.intrinsicContentSize.height)
            .max() ?? 0

        var groupColumns: [NSView] = []
        for (index, row) in options.rows.enumerated() {
            let checkbox = NSButton(checkboxWithTitle: row.label, target: self, action: #selector(selectionChanged))
            checkbox.state = row.initialState ? .on : .off
            checkbox.font = NSFont.systemFont(ofSize: 13)
            optionButtons.append(checkbox)

            let illustration = KeyGroupIllustrationView(
                items: diagramsPerRow[index],
                columnWidth: Self.diagramColumnWidth,
                bandHeight: bandHeight
            )
            optionIllustrations.append(illustration)

            let column = NSStackView(views: [checkbox, illustration])
            column.orientation = .vertical
            column.alignment = .leading
            column.spacing = 6
            groupColumns.append(column)
        }

        let groupRow = NSStackView(views: groupColumns)
        groupRow.orientation = .horizontal
        groupRow.alignment = .top
        groupRow.spacing = Self.optionColumnGap

        // The gesture can't start without a key to press, so flag it where it is fixed.
        let hint = makeHintLabel(options.allOffWarning)
        hint.textColor = .systemRed
        optionsHintLabel = hint
        return makeSection(header: options.header, content: [groupRow, hint])
    }

    private func makeWalkthroughSection() -> NSView {
        walkthroughStack = NSStackView()
        walkthroughStack.orientation = .vertical
        walkthroughStack.alignment = .leading
        walkthroughStack.spacing = 4
        return makeSection(header: walkthroughHeader, content: [walkthroughStack])
    }

    private func makeButtonRow() -> NSView {
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
        let row = NSStackView(views: [restoreButton, spacer, cancelButton, saveButton])
        row.orientation = .horizontal
        row.spacing = 10
        row.widthAnchor.constraint(equalToConstant: Self.sheetWidth - Self.edgeInset * 2).isActive = true
        return row
    }

    /// A small header above a card holding `content`, matching the grouped look of System Settings.
    private func makeSection(header: String, content: [NSView]) -> NSView {
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

    private func makeHintLabel(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = NSFont.systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = Self.cardContentWidth
        return label
    }

    // MARK: - Actions

    @objc private func selectionChanged() {
        refresh()
    }

    @objc private func restoreDefault() {
        for cap in modifierCaps {
            cap.isOn = ModifierCombination.defaultModifiers.contains(cap.modifier)
        }
        for (index, button) in optionButtons.enumerated() {
            button.state = options?.rows[index].defaultState == true ? .on : .off
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

    // MARK: - Syncing to the current selection

    /// Sync the hints, pictograms, walkthrough, and Save button to the checked modifiers and
    /// options. The lit caps are the preview of the chosen combination, so nothing below repeats
    /// it.
    private func refresh() {
        let selected = selectedModifiers
        let states = optionStates

        modifiersHintLabel.textColor = selected.isValid ? .secondaryLabelColor : .systemRed
        saveButton.isEnabled = selected.isValid

        // An invalid combination is already flagged in red and can't be saved, so its conflicts
        // are moot.
        let warning = selected.isValid ? conflictWarning?(selected, states) : nil
        conflictWarningLabel?.stringValue = warning.map { "\($0)." } ?? ""
        conflictWarningRow?.isHidden = warning == nil
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

        let anyOptionOn = states.contains(true)
        for (index, illustration) in optionIllustrations.enumerated() {
            illustration.isEnabled = states.indices.contains(index) ? states[index] : true
        }
        optionsHintLabel?.isHidden = anyOptionOn

        rebuildWalkthrough(walkthrough(states))
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
                // declared in — which the closing note refers to.
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

        if let note = content.note {
            let label = NSTextField(wrappingLabelWithString: note)
            label.font = NSFont.systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            label.preferredMaxLayoutWidth = Self.cardContentWidth
            append(label, gapAbove: 12)
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
        case .keys(let labels):
            let caps = NSStackView(views: labels.map { label -> KeyCapView in
                let cap = KeyCapView(label: label)
                cap.isEnabled = isAvailable
                return cap
            })
            caps.orientation = .horizontal
            caps.alignment = .firstBaseline
            caps.spacing = 4
            return caps
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

// MARK: - The two editors

extension ModifierCombinationSheetViewController {
    /// Editor for the modifiers held while clicking or dragging to activate the mouse gestures.
    static func mouseGestures() -> ModifierCombinationSheetViewController {
        ModifierCombinationSheetViewController(
            title: "Mouse Gestures",
            subtitle: "Choose the modifier keys to hold while clicking or dragging.",
            modifiersHint: "Select at least two.",
            walkthroughHeader: "What the gestures do",
            walkthrough: { _ in
                Walkthrough(items: [
                    .heading("While holding the modifier keys:"),
                    // One column: these triggers are phrases, not caps, so a second column would
                    // leave too little room for the descriptions.
                    .steps([
                        Walkthrough.Step(
                            trigger: .gesture("click"),
                            detail: "Make a tiling zone the destination"),
                        Walkthrough.Step(
                            trigger: .gesture("double-click"),
                            detail: "Make it the destination and open the Launcher"),
                        Walkthrough.Step(
                            trigger: .gesture("drag a tiled window"),
                            detail: "Move it into the floating zone"),
                        Walkthrough.Step(
                            trigger: .gesture("drag a floating window"),
                            detail: "Drop it into an occupied zone, replacing that window"),
                        Walkthrough.Step(
                            trigger: .gesture("drag from another app"),
                            detail: "Route the drop into a zone"),
                    ], columns: 1),
                ])
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
            title: "Zone Navigation",
            subtitle: "Hold the modifier keys and press a navigation key: a blue circle highlights a zone.",
            modifiersHint: "Select at least two.",
            walkthroughHeader: "Acting on this zone",
            walkthrough: zoneNavigationWalkthrough,
            conflictWarning: { modifiers, optionStates in
                ShortcutConflicts.current(
                    zoneNavigationModifiers: modifiers,
                    zoneNavigationGroups: zoneNavigationKeyGroups(fromOptionStates: optionStates)
                ).description(for: .zoneNavigation)
            },
            initialModifiers: ModifierCombinationPreferences.zoneNavigation.modifiers,
            options: Options(
                header: "Navigation keys",
                rows: [
                    Options.Row(
                        label: "Arrow keys",
                        initialState: current.contains(.arrows),
                        defaultState: ZoneNavigationKeyGroups.all.contains(.arrows),
                        diagrams: {
                            [(
                                ArrowKeysDiagramView(),
                                "Step to the next zone in that direction. The Floating Zone Bar "
                                    + "is the bottom stop."
                            )]
                        }
                    ),
                    Options.Row(
                        label: "Letter keys",
                        initialState: current.contains(.letters),
                        defaultState: ZoneNavigationKeyGroups.all.contains(.letters),
                        diagrams: {
                            [
                                (
                                    ZoneLetterKeysDiagramView(),
                                    "Jump to that zone, adding it if it isn't there yet. "
                                        + "G is the floating zone."
                                ),
                                (DisplayLetterKeysDiagramView(), "Jump to that display."),
                            ]
                        }
                    ),
                ],
                allOffWarning: "Zone navigation is off. Turn on the arrow keys or the letter keys."
            )
        )
    }

    /// The steps of the zone-navigation gesture, for the currently checked modifiers and groups.
    ///
    /// The Launcher, Add Zone, Remove Zone, and Minimize steps borrow those shortcuts' keys
    /// (claimed in that order), so each shows the key as currently configured — unless an earlier
    /// in-gesture key leaves the borrowed key unreachable. The reused-from attributions are pooled
    /// into one closing note so each step stays to a single line.
    private static func zoneNavigationWalkthrough(optionStates: [Bool]) -> Walkthrough {
        let groups = zoneNavigationKeyGroups(fromOptionStates: optionStates)

        var earlierBorrowedKeys: [CGKeyCode] = []
        var borrowedKeyNotes: [(key: String, source: String)] = []
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
                keyCode, groups: groups, earlierBorrowedKeys: earlierBorrowedKeys
            ) else {
                return Walkthrough.Step(
                    trigger: .unavailable,
                    detail: "\(unavailableStep) is unavailable (the \(action.displayName) key \(key) "
                        + "already has another meaning in the gesture)",
                    isAvailable: false
                )
            }
            earlierBorrowedKeys.append(keyCode)
            borrowedKeyNotes.append((key, action.displayName))
            return Walkthrough.Step(trigger: .keys([key]), detail: detail)
        }

        let items: [Walkthrough.Item] = [
            .line("Release the modifier keys: focus this zone's window, or make it the "
                + "destination if empty."),
            .heading("While still holding the modifier keys:"),
            .steps([
                Walkthrough.Step(
                    trigger: .keys(["↩"]),
                    detail: "Move the focused window into this zone (swaps if occupied)"),
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
                Walkthrough.Step(trigger: .keys(["esc"]), detail: "Cancel"),
            ], columns: 2),
        ]

        var note: String?
        if !borrowedKeyNotes.isEmpty {
            // Name the borrowed keys rather than saying "these keys": ↩ and esc sit in the same
            // list but are fixed, and implying they're remappable would be worse than the extra words.
            let plural = borrowedKeyNotes.count == 1 ? "" : "s"
            note = borrowedKeyNotes.map(\.key).naturalList + " follow the "
                + borrowedKeyNotes.map(\.source).naturalList + " shortcut\(plural)."
        }

        // With no navigation keys there is nothing to select, so the whole gesture is out of reach.
        return Walkthrough(items: items, note: note, isReachable: !groups.isEmpty)
    }
}
