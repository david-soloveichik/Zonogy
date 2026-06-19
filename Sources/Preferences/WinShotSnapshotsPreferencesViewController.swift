/// View controller for the WinShot Snapshots preferences tab
import AppKit

final class WinShotSnapshotsPreferencesViewController: NSViewController, NSTextFieldDelegate {
    private var winShotCheckbox: NSButton?
    private var winShotHintLabel: NSTextField?
    private var autoSaveLabel: NSTextField?
    private var autoSavePopup: NSPopUpButton?
    private var autoSaveHintLabel: NSTextField?
    private var settleDelayLabel: NSTextField?
    private var settleDelayTextField: NSTextField?
    private var settleDelayStepper: NSStepper?
    private var settleDelaySuffixLabel: NSTextField?
    private var settleDelayHintLabel: NSTextField?
    private var maxSnapshotsLabel: NSTextField?
    private var maxSnapshotsTextField: NSTextField?
    private var maxSnapshotsStepper: NSStepper?
    private var maxSnapshotsHintLabel: NSTextField?

    private static func title(for mode: WinShotAutoSaveMode) -> String {
        switch mode {
        case .off: return "Off"
        case .onClearReset: return "On Clear/Reset Zones"
        case .onEveryOccupancyChange: return "On every zone occupancy change"
        }
    }

    private static func hint(for mode: WinShotAutoSaveMode) -> String {
        switch mode {
        case .off:
            return "Snapshots are saved only with the Control-Command-/ shortcut."
        case .onClearReset:
            return "Capture the current arrangement right before Clear/Reset Zones, when managed windows are present."
        case .onEveryOccupancyChange:
            return "Also save any arrangement that stays put for the delay below. The pre-clear capture still applies too."
        }
    }

    override func loadView() {
        let containerView = NSView(frame: NSRect(x: 0, y: 0, width: 580, height: 440))

        let titleLabel = NSTextField(labelWithString: "WinShot Snapshots")
        titleLabel.font = NSFont.systemFont(ofSize: 16, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(titleLabel)

        let winShotCheckbox = NSButton(checkboxWithTitle: "Enable WinShot", target: self, action: #selector(winShotToggled(_:)))
        winShotCheckbox.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(winShotCheckbox)
        self.winShotCheckbox = winShotCheckbox

        let winShotHintLabel = NSTextField(
            wrappingLabelWithString: "Save and restore window arrangement snapshots with Control-Cmd-Tab. (Requires Screen Recording permission.)"
        )
        winShotHintLabel.font = NSFont.systemFont(ofSize: 12)
        winShotHintLabel.textColor = .secondaryLabelColor
        winShotHintLabel.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(winShotHintLabel)
        self.winShotHintLabel = winShotHintLabel

        let autoSaveLabel = NSTextField(labelWithString: "Auto-save snapshots:")
        autoSaveLabel.font = NSFont.systemFont(ofSize: 13)
        autoSaveLabel.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(autoSaveLabel)
        self.autoSaveLabel = autoSaveLabel

        let autoSavePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        autoSavePopup.translatesAutoresizingMaskIntoConstraints = false
        autoSavePopup.target = self
        autoSavePopup.action = #selector(autoSaveModeChanged(_:))
        for mode in WinShotAutoSaveMode.allCases {
            autoSavePopup.addItem(withTitle: Self.title(for: mode))
            autoSavePopup.lastItem?.tag = mode.rawValue
        }
        containerView.addSubview(autoSavePopup)
        self.autoSavePopup = autoSavePopup

        let autoSaveHintLabel = NSTextField(wrappingLabelWithString: "")
        autoSaveHintLabel.font = NSFont.systemFont(ofSize: 12)
        autoSaveHintLabel.textColor = .secondaryLabelColor
        autoSaveHintLabel.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(autoSaveHintLabel)
        self.autoSaveHintLabel = autoSaveHintLabel

        let delayFormatter = NumberFormatter()
        delayFormatter.numberStyle = .none
        delayFormatter.minimum = NSNumber(value: WinShotPreferencesStore.minOccupancySettleDelaySeconds)
        delayFormatter.maximum = NSNumber(value: WinShotPreferencesStore.maxOccupancySettleDelaySeconds)
        delayFormatter.allowsFloats = false

        let settleDelayLabel = NSTextField(labelWithString: "Save arrangements lasting at least:")
        settleDelayLabel.font = NSFont.systemFont(ofSize: 13)
        settleDelayLabel.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(settleDelayLabel)
        self.settleDelayLabel = settleDelayLabel

        let settleDelayTextField = NSTextField(string: "")
        settleDelayTextField.alignment = .right
        settleDelayTextField.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        settleDelayTextField.formatter = delayFormatter
        settleDelayTextField.delegate = self
        settleDelayTextField.target = self
        settleDelayTextField.action = #selector(settleDelayFieldSubmitted(_:))
        settleDelayTextField.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(settleDelayTextField)
        self.settleDelayTextField = settleDelayTextField

        let settleDelayStepper = NSStepper()
        settleDelayStepper.minValue = Double(WinShotPreferencesStore.minOccupancySettleDelaySeconds)
        settleDelayStepper.maxValue = Double(WinShotPreferencesStore.maxOccupancySettleDelaySeconds)
        settleDelayStepper.increment = 1
        settleDelayStepper.valueWraps = false
        settleDelayStepper.target = self
        settleDelayStepper.action = #selector(settleDelayStepperChanged(_:))
        settleDelayStepper.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(settleDelayStepper)
        self.settleDelayStepper = settleDelayStepper

        let settleDelaySuffixLabel = NSTextField(labelWithString: "seconds")
        settleDelaySuffixLabel.font = NSFont.systemFont(ofSize: 13)
        settleDelaySuffixLabel.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(settleDelaySuffixLabel)
        self.settleDelaySuffixLabel = settleDelaySuffixLabel

        let settleDelayHintLabel = NSTextField(
            wrappingLabelWithString: "How long an arrangement must persist before it's saved (also the backup-capture delay), \(WinShotPreferencesStore.minOccupancySettleDelaySeconds)-\(WinShotPreferencesStore.maxOccupancySettleDelaySeconds) seconds."
        )
        settleDelayHintLabel.font = NSFont.systemFont(ofSize: 12)
        settleDelayHintLabel.textColor = .secondaryLabelColor
        settleDelayHintLabel.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(settleDelayHintLabel)
        self.settleDelayHintLabel = settleDelayHintLabel

        let maxFormatter = NumberFormatter()
        maxFormatter.numberStyle = .none
        maxFormatter.minimum = NSNumber(value: WinShotPreferencesStore.minSnapshotsStored)
        maxFormatter.maximum = NSNumber(value: WinShotPreferencesStore.maxSnapshotsStored)
        maxFormatter.allowsFloats = false

        let maxSnapshotsLabel = NSTextField(labelWithString: "Max snapshots per screen:")
        maxSnapshotsLabel.font = NSFont.systemFont(ofSize: 13)
        maxSnapshotsLabel.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(maxSnapshotsLabel)
        self.maxSnapshotsLabel = maxSnapshotsLabel

        let maxSnapshotsTextField = NSTextField(string: "")
        maxSnapshotsTextField.alignment = .right
        maxSnapshotsTextField.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        maxSnapshotsTextField.formatter = maxFormatter
        maxSnapshotsTextField.delegate = self
        maxSnapshotsTextField.target = self
        maxSnapshotsTextField.action = #selector(maxSnapshotsFieldSubmitted(_:))
        maxSnapshotsTextField.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(maxSnapshotsTextField)
        self.maxSnapshotsTextField = maxSnapshotsTextField

        let maxSnapshotsStepper = NSStepper()
        maxSnapshotsStepper.minValue = Double(WinShotPreferencesStore.minSnapshotsStored)
        maxSnapshotsStepper.maxValue = Double(WinShotPreferencesStore.maxSnapshotsStored)
        maxSnapshotsStepper.increment = 1
        maxSnapshotsStepper.valueWraps = false
        maxSnapshotsStepper.target = self
        maxSnapshotsStepper.action = #selector(maxSnapshotsStepperChanged(_:))
        maxSnapshotsStepper.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(maxSnapshotsStepper)
        self.maxSnapshotsStepper = maxSnapshotsStepper

        let maxSnapshotsHintLabel = NSTextField(
            wrappingLabelWithString: "Choose how many snapshots to keep per screen (\(WinShotPreferencesStore.minSnapshotsStored)-\(WinShotPreferencesStore.maxSnapshotsStored))."
        )
        maxSnapshotsHintLabel.font = NSFont.systemFont(ofSize: 12)
        maxSnapshotsHintLabel.textColor = .secondaryLabelColor
        maxSnapshotsHintLabel.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(maxSnapshotsHintLabel)
        self.maxSnapshotsHintLabel = maxSnapshotsHintLabel

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 20),
            titleLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),

            winShotCheckbox.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 18),
            winShotCheckbox.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),

            winShotHintLabel.topAnchor.constraint(equalTo: winShotCheckbox.bottomAnchor, constant: 6),
            winShotHintLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 40),
            winShotHintLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -20),

            autoSavePopup.topAnchor.constraint(equalTo: winShotHintLabel.bottomAnchor, constant: 14),
            autoSavePopup.leadingAnchor.constraint(equalTo: autoSaveLabel.trailingAnchor, constant: 8),
            autoSaveLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 40),
            autoSaveLabel.centerYAnchor.constraint(equalTo: autoSavePopup.centerYAnchor),

            autoSaveHintLabel.topAnchor.constraint(equalTo: autoSavePopup.bottomAnchor, constant: 6),
            autoSaveHintLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 40),
            autoSaveHintLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -20),

            settleDelayLabel.topAnchor.constraint(equalTo: autoSaveHintLabel.bottomAnchor, constant: 16),
            settleDelayLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 60),

            settleDelayTextField.firstBaselineAnchor.constraint(equalTo: settleDelayLabel.firstBaselineAnchor),
            settleDelayTextField.leadingAnchor.constraint(equalTo: settleDelayLabel.trailingAnchor, constant: 10),
            settleDelayTextField.widthAnchor.constraint(equalToConstant: 56),

            settleDelayStepper.centerYAnchor.constraint(equalTo: settleDelayTextField.centerYAnchor),
            settleDelayStepper.leadingAnchor.constraint(equalTo: settleDelayTextField.trailingAnchor, constant: 8),

            settleDelaySuffixLabel.firstBaselineAnchor.constraint(equalTo: settleDelayLabel.firstBaselineAnchor),
            settleDelaySuffixLabel.leadingAnchor.constraint(equalTo: settleDelayStepper.trailingAnchor, constant: 8),

            settleDelayHintLabel.topAnchor.constraint(equalTo: settleDelayLabel.bottomAnchor, constant: 6),
            settleDelayHintLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 60),
            settleDelayHintLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -20),

            maxSnapshotsLabel.topAnchor.constraint(equalTo: settleDelayHintLabel.bottomAnchor, constant: 18),
            maxSnapshotsLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 40),

            maxSnapshotsTextField.firstBaselineAnchor.constraint(equalTo: maxSnapshotsLabel.firstBaselineAnchor),
            maxSnapshotsTextField.leadingAnchor.constraint(equalTo: maxSnapshotsLabel.trailingAnchor, constant: 10),
            maxSnapshotsTextField.widthAnchor.constraint(equalToConstant: 56),

            maxSnapshotsStepper.centerYAnchor.constraint(equalTo: maxSnapshotsTextField.centerYAnchor),
            maxSnapshotsStepper.leadingAnchor.constraint(equalTo: maxSnapshotsTextField.trailingAnchor, constant: 8),

            maxSnapshotsHintLabel.topAnchor.constraint(equalTo: maxSnapshotsLabel.bottomAnchor, constant: 6),
            maxSnapshotsHintLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 60),
            maxSnapshotsHintLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -20),
        ])

        self.view = containerView
        self.preferredContentSize = NSSize(width: 580, height: 440)
        syncControls()
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
        if textField == maxSnapshotsTextField {
            applyMaxSnapshotsStored(textField.integerValue)
        } else if textField == settleDelayTextField {
            applySettleDelay(textField.integerValue)
        }
    }

    private func applySettleDelay(_ rawValue: Int) {
        AppController.shared.setWinShotOccupancySettleDelayFromSettings(rawValue)
        syncControls()
    }

    private func applyMaxSnapshotsStored(_ rawValue: Int) {
        AppController.shared.setWinShotMaxSnapshotsStoredFromSettings(rawValue)
        syncControls()
    }

    private func syncControls() {
        let winShotEnabled = AppController.shared.isWinShotEnabled
        winShotCheckbox?.state = winShotEnabled ? .on : .off

        let mode = AppController.shared.winShotAutoSaveMode
        autoSavePopup?.selectItem(withTag: mode.rawValue)
        autoSavePopup?.isEnabled = winShotEnabled
        autoSaveLabel?.textColor = winShotEnabled ? .labelColor : .secondaryLabelColor
        autoSaveHintLabel?.stringValue = Self.hint(for: mode)
        autoSaveHintLabel?.textColor = winShotEnabled ? .secondaryLabelColor : .tertiaryLabelColor

        let settleEnabled = winShotEnabled && mode == .onEveryOccupancyChange
        let settleDelay = AppController.shared.winShotOccupancySettleDelaySeconds
        settleDelayTextField?.integerValue = settleDelay
        settleDelayStepper?.integerValue = settleDelay
        settleDelayTextField?.isEnabled = settleEnabled
        settleDelayStepper?.isEnabled = settleEnabled
        settleDelayLabel?.textColor = settleEnabled ? .labelColor : .secondaryLabelColor
        settleDelaySuffixLabel?.textColor = settleEnabled ? .labelColor : .secondaryLabelColor
        settleDelayHintLabel?.textColor = settleEnabled ? .secondaryLabelColor : .tertiaryLabelColor

        let maxSnapshotsStored = AppController.shared.winShotMaxSnapshotsStoredInSettings
        maxSnapshotsTextField?.integerValue = maxSnapshotsStored
        maxSnapshotsStepper?.integerValue = maxSnapshotsStored
        maxSnapshotsTextField?.isEnabled = winShotEnabled
        maxSnapshotsStepper?.isEnabled = winShotEnabled
        maxSnapshotsLabel?.textColor = winShotEnabled ? .labelColor : .secondaryLabelColor
        maxSnapshotsHintLabel?.textColor = winShotEnabled ? .secondaryLabelColor : .tertiaryLabelColor
    }
}
