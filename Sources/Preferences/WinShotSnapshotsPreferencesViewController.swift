/// View controller for the WinShot Snapshots preferences tab, whose settings read as sentences with inline controls.
import AppKit

final class WinShotSnapshotsPreferencesViewController: NSViewController, NSTextFieldDelegate {
    private var winShotCheckbox: NSButton?
    private var screenRecordingBadge: PreferenceStatusBadge?
    private var winShotHintLabel: NSTextField?
    private var autoSaveSentence: NSStackView?
    private var autoSavePopup: NSPopUpButton?
    private var settleDelayClause: NSStackView?
    private var settleDelayField: NSTextField?
    private var settleDelayStepper: NSStepper?
    private var maxSnapshotsSentence: NSStackView?
    private var maxSnapshotsField: NSTextField?
    private var maxSnapshotsStepper: NSStepper?

    /// Lowercase, since each choice continues the sentence "Auto-save …".
    private static func title(for mode: WinShotAutoSaveMode) -> String {
        switch mode {
        case .off: return "never"
        case .onClearReset: return "before Clear/Reset or restore"
        case .onEveryChange: return "after every change"
        }
    }

    private static var featureHint: String {
        let shortcuts = KeyboardShortcutPreferences.shared
        return "A snapshot records which windows are in which zones on a display. Manually save one with \(shortcuts.keyPhrase(for: .saveWinShotSnapshot)) and restore with \(shortcuts.keyPhrase(for: .showWinShotChooser)) (settable in Shortcuts)."
    }

    override func loadView() {
        let containerView = NSView(frame: NSRect(x: 0, y: 0, width: 580, height: 440))

        let titleLabel = NSTextField(labelWithString: "WinShot Snapshots")
        titleLabel.font = NSFont.systemFont(ofSize: 16, weight: .semibold)

        let winShotCheckbox = NSButton(checkboxWithTitle: "Enable WinShot", target: self, action: #selector(winShotToggled(_:)))
        self.winShotCheckbox = winShotCheckbox
        // Shown only while the permission is missing, in the warning style of General's permission status.
        let screenRecordingBadge = PreferenceStatusBadge()
        screenRecordingBadge.update(title: "Needs Screen Recording permission (see General)",
                                    symbol: "exclamationmark.triangle.fill", color: .systemOrange)
        self.screenRecordingBadge = screenRecordingBadge
        let enableRow = NSStackView(views: [winShotCheckbox, screenRecordingBadge])
        enableRow.orientation = .horizontal
        enableRow.alignment = .centerY
        enableRow.spacing = 12

        // Text naming shortcuts is filled in by syncControls, which runs whenever the tab appears.
        let winShotHintLabel = NSTextField(wrappingLabelWithString: "")
        winShotHintLabel.font = NSFont.systemFont(ofSize: 12)
        winShotHintLabel.textColor = .secondaryLabelColor
        self.winShotHintLabel = winShotHintLabel

        let autoSavePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        autoSavePopup.target = self
        autoSavePopup.action = #selector(autoSaveModeChanged(_:))
        for mode in WinShotAutoSaveMode.allCases {
            autoSavePopup.addItem(withTitle: Self.title(for: mode))
            autoSavePopup.lastItem?.tag = mode.rawValue
        }
        self.autoSavePopup = autoSavePopup

        let settleDelay = makeNumberInput(
            range: WinShotPreferencesStore.minSettleDelaySeconds...WinShotPreferencesStore.maxSettleDelaySeconds,
            fieldAction: #selector(settleDelayFieldSubmitted(_:)),
            stepperAction: #selector(settleDelayStepperChanged(_:))
        )
        settleDelayField = settleDelay.field
        settleDelayStepper = settleDelay.stepper
        let settleDelayClause = Self.makeSentence(
            [Self.makeWords("once it lasts"), settleDelay.field, settleDelay.stepper, Self.makeWords("seconds")])
        self.settleDelayClause = settleDelayClause
        let autoSaveSentence = Self.makeSentence([Self.makeWords("Auto-save"), autoSavePopup, settleDelayClause])
        self.autoSaveSentence = autoSaveSentence

        let maxSnapshots = makeNumberInput(
            range: WinShotPreferencesStore.minSnapshotsStored...WinShotPreferencesStore.maxSnapshotsStored,
            fieldAction: #selector(maxSnapshotsFieldSubmitted(_:)),
            stepperAction: #selector(maxSnapshotsStepperChanged(_:))
        )
        maxSnapshotsField = maxSnapshots.field
        maxSnapshotsStepper = maxSnapshots.stepper
        let maxSnapshotsSentence = Self.makeSentence(
            [Self.makeWords("Keep up to"), maxSnapshots.field, maxSnapshots.stepper, Self.makeWords("snapshots per display")])
        self.maxSnapshotsSentence = maxSnapshotsSentence

        let settings = NSStackView(views: [winShotHintLabel, autoSaveSentence, maxSnapshotsSentence])
        settings.orientation = .vertical
        settings.alignment = .leading
        settings.spacing = 14
        settings.edgeInsets.left = 20

        let page = NSStackView(views: [titleLabel, enableRow, settings])
        page.orientation = .vertical
        page.alignment = .leading
        page.spacing = 6
        page.setCustomSpacing(18, after: titleLabel)
        page.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(page)
        NSLayoutConstraint.activate([
            page.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 20),
            page.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),
            page.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -20),
            winShotHintLabel.trailingAnchor.constraint(equalTo: page.trailingAnchor),
        ])

        self.view = containerView
        syncControls()
    }

    /// Shortcuts may have been rebound, or Screen Recording granted, since the tab was last shown.
    override func viewWillAppear() {
        super.viewWillAppear()
        syncControls()
    }

    // MARK: - Building blocks

    /// Words between a sentence's controls.
    private static func makeWords(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 13)
        return label
    }

    /// A setting that reads as a sentence: words and controls in one row, hugging their natural width.
    private static func makeSentence(_ parts: [NSView]) -> NSStackView {
        let row = NSStackView(views: parts)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        row.setHuggingPriority(.required, for: .horizontal)
        return row
    }

    /// A number field and its stepper, both limited to `range`.
    private func makeNumberInput(range: ClosedRange<Int>, fieldAction: Selector, stepperAction: Selector)
        -> (field: NSTextField, stepper: NSStepper)
    {
        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        formatter.minimum = NSNumber(value: range.lowerBound)
        formatter.maximum = NSNumber(value: range.upperBound)
        formatter.allowsFloats = false

        let field = NSTextField(string: "")
        field.alignment = .right
        field.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        field.formatter = formatter
        field.delegate = self
        field.target = self
        field.action = fieldAction
        field.widthAnchor.constraint(equalToConstant: 44).isActive = true

        let stepper = NSStepper()
        stepper.minValue = Double(range.lowerBound)
        stepper.maxValue = Double(range.upperBound)
        stepper.increment = 1
        stepper.valueWraps = false
        stepper.target = self
        stepper.action = stepperAction
        return (field, stepper)
    }

    // MARK: - Actions

    @objc private func winShotToggled(_ sender: NSButton) {
        let enabled = sender.state == .on
        AppController.shared.setWinShotEnabledFromSettings(enabled)
        syncControls()
    }

    @objc private func autoSaveModeChanged(_ sender: NSPopUpButton) {
        let mode = WinShotAutoSaveMode(rawValue: sender.selectedTag()) ?? WinShotPreferencesStore.defaultAutoSaveMode
        AppController.shared.setWinShotAutoSaveModeFromSettings(mode)
        syncControls()
    }

    @objc private func settleDelayStepperChanged(_ sender: NSStepper) {
        applySettleDelay(Int(sender.intValue))
    }

    @objc private func settleDelayFieldSubmitted(_ sender: NSTextField) {
        applySettleDelay(sender.integerValue)
    }

    @objc private func maxSnapshotsStepperChanged(_ sender: NSStepper) {
        applyMaxSnapshotsStored(Int(sender.intValue))
    }

    @objc private func maxSnapshotsFieldSubmitted(_ sender: NSTextField) {
        applyMaxSnapshotsStored(sender.integerValue)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let textField = obj.object as? NSTextField else {
            return
        }
        if textField == maxSnapshotsField {
            applyMaxSnapshotsStored(textField.integerValue)
        } else if textField == settleDelayField {
            applySettleDelay(textField.integerValue)
        }
    }

    private func applySettleDelay(_ rawValue: Int) {
        AppController.shared.setWinShotSettleDelayFromSettings(rawValue)
        syncControls()
    }

    private func applyMaxSnapshotsStored(_ rawValue: Int) {
        AppController.shared.setWinShotMaxSnapshotsStoredFromSettings(rawValue)
        syncControls()
    }

    private func syncControls() {
        let winShotEnabled = AppController.shared.isWinShotEnabled
        winShotCheckbox?.state = winShotEnabled ? .on : .off
        screenRecordingBadge?.isHidden = CGPreflightScreenCaptureAccess()
        winShotHintLabel?.stringValue = Self.featureHint

        let mode = AppController.shared.winShotAutoSaveMode
        autoSavePopup?.selectItem(withTag: mode.rawValue)
        // The duration finishes the sentence only for the mode it applies to.
        settleDelayClause?.isHidden = mode != .onEveryChange
        let settleDelay = AppController.shared.winShotSettleDelaySeconds
        settleDelayField?.integerValue = settleDelay
        settleDelayStepper?.integerValue = settleDelay

        let maxSnapshotsStored = AppController.shared.winShotMaxSnapshotsStoredInSettings
        maxSnapshotsField?.integerValue = maxSnapshotsStored
        maxSnapshotsStepper?.integerValue = maxSnapshotsStored

        for sentence in [autoSaveSentence, maxSnapshotsSentence].compactMap({ $0 }) {
            Self.setEnabled(winShotEnabled, in: sentence)
        }
        // The badge and the description's shortcut names can change the content's height.
        fitPreferredContentSizeToContent()
    }

    /// Dims a sentence's words and disables its controls together.
    private static func setEnabled(_ enabled: Bool, in sentence: NSStackView) {
        for part in sentence.arrangedSubviews {
            if let clause = part as? NSStackView {
                setEnabled(enabled, in: clause)
            } else if let words = part as? NSTextField, !words.isEditable {
                words.textColor = enabled ? .labelColor : .secondaryLabelColor
            } else if let control = part as? NSControl {
                control.isEnabled = enabled
            }
        }
    }
}
