/// View controller for the WinShot Snapshots preferences tab, whose settings read as sentences with inline controls.
import AppKit

final class WinShotSnapshotsPreferencesViewController: NSViewController {
    private var winShotCheckbox: NSButton?
    private var screenRecordingBadge: PreferenceStatusBadge?
    private var winShotHintLabel: NSTextField?
    private var autoSaveSentence: NSStackView?
    private var autoSavePopup: NSPopUpButton?
    private var maxSnapshotsSentence: NSStackView?
    private var maxSnapshotsInput: NumberStepperInput?

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

        let tourButton = NSButton(title: "WinShot Tour…", target: self, action: #selector(showTour))
        tourButton.bezelStyle = .rounded
        tourButton.controlSize = .small
        tourButton.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(tourButton)

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
        let autoSaveSentence = Self.makeSentence([Self.makeWords("Auto-save"), autoSavePopup])
        self.autoSaveSentence = autoSaveSentence

        let maxSnapshotsInput = NumberStepperInput(
            range: WinShotPreferencesStore.minSnapshotsStored...WinShotPreferencesStore.maxSnapshotsStored
        ) { [weak self] value in
            AppController.shared.setWinShotMaxSnapshotsStoredFromSettings(value)
            self?.syncControls()
        }
        self.maxSnapshotsInput = maxSnapshotsInput
        let maxSnapshotsSentence = Self.makeSentence([
            Self.makeWords("Keep up to"), maxSnapshotsInput.field, maxSnapshotsInput.stepper,
            Self.makeWords("snapshots per display"),
        ])
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

            tourButton.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -20),
            tourButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
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

    // MARK: - Actions

    @objc private func showTour() {
        TourWindowController.shared.show(.winShot)
    }

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

    private func syncControls() {
        let winShotEnabled = AppController.shared.isWinShotEnabled
        winShotCheckbox?.state = winShotEnabled ? .on : .off
        screenRecordingBadge?.isHidden = CGPreflightScreenCaptureAccess()
        winShotHintLabel?.stringValue = Self.featureHint

        autoSavePopup?.selectItem(withTag: AppController.shared.winShotAutoSaveMode.rawValue)
        maxSnapshotsInput?.show(AppController.shared.winShotMaxSnapshotsStoredInSettings)

        for sentence in [autoSaveSentence, maxSnapshotsSentence].compactMap({ $0 }) {
            Self.setEnabled(winShotEnabled, in: sentence)
        }
        // The badge and the description's shortcut names can change the content's height.
        fitPreferredContentSizeToContent()
    }

    /// Dims a sentence's words and disables its controls together.
    private static func setEnabled(_ enabled: Bool, in sentence: NSStackView) {
        for part in sentence.arrangedSubviews {
            if let words = part as? NSTextField, !words.isEditable {
                words.textColor = enabled ? .labelColor : .secondaryLabelColor
            } else if let control = part as? NSControl {
                control.isEnabled = enabled
            }
        }
    }
}
