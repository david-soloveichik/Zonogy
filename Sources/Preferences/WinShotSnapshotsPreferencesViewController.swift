/// View controller for the WinShot Snapshots preferences tab
import AppKit

final class WinShotSnapshotsPreferencesViewController: NSViewController, NSTextFieldDelegate {
    private var winShotCheckbox: NSButton?
    private var winShotHintLabel: NSTextField?
    private var winShotAutoSaveCheckbox: NSButton?
    private var winShotAutoSaveHintLabel: NSTextField?
    private var maxSnapshotsLabel: NSTextField?
    private var maxSnapshotsTextField: NSTextField?
    private var maxSnapshotsStepper: NSStepper?
    private var maxSnapshotsHintLabel: NSTextField?

    override func loadView() {
        let containerView = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 320))

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

        let winShotAutoSaveCheckbox = NSButton(
            checkboxWithTitle: "Auto-save snapshots on zone occupancy changes",
            target: self,
            action: #selector(winShotAutoSaveToggled(_:))
        )
        winShotAutoSaveCheckbox.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(winShotAutoSaveCheckbox)
        self.winShotAutoSaveCheckbox = winShotAutoSaveCheckbox

        let winShotAutoSaveHintLabel = NSTextField(
            wrappingLabelWithString: "Automatically save when windows are placed, removed, or moved between zones (including Clear/Reset and snapshot recalls)."
        )
        winShotAutoSaveHintLabel.font = NSFont.systemFont(ofSize: 12)
        winShotAutoSaveHintLabel.textColor = .secondaryLabelColor
        winShotAutoSaveHintLabel.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(winShotAutoSaveHintLabel)
        self.winShotAutoSaveHintLabel = winShotAutoSaveHintLabel

        let maxSnapshotsLabel = NSTextField(labelWithString: "Max snapshots per screen:")
        maxSnapshotsLabel.font = NSFont.systemFont(ofSize: 13)
        maxSnapshotsLabel.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(maxSnapshotsLabel)
        self.maxSnapshotsLabel = maxSnapshotsLabel

        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        formatter.minimum = NSNumber(value: WinShotPreferencesStore.minSnapshotsStored)
        formatter.maximum = NSNumber(value: WinShotPreferencesStore.maxSnapshotsStored)
        formatter.allowsFloats = false

        let maxSnapshotsTextField = NSTextField(string: "")
        maxSnapshotsTextField.alignment = .right
        maxSnapshotsTextField.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        maxSnapshotsTextField.formatter = formatter
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

            winShotAutoSaveCheckbox.topAnchor.constraint(equalTo: winShotHintLabel.bottomAnchor, constant: 12),
            winShotAutoSaveCheckbox.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 40),

            winShotAutoSaveHintLabel.topAnchor.constraint(equalTo: winShotAutoSaveCheckbox.bottomAnchor, constant: 6),
            winShotAutoSaveHintLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 60),
            winShotAutoSaveHintLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -20),

            maxSnapshotsLabel.topAnchor.constraint(equalTo: winShotAutoSaveHintLabel.bottomAnchor, constant: 20),
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
        self.preferredContentSize = NSSize(width: 500, height: 320)
        syncControls()
    }

    @objc private func winShotToggled(_ sender: NSButton) {
        let enabled = sender.state == .on
        AppController.shared.setWinShotEnabledFromSettings(enabled)
        syncControls()
    }

    @objc private func winShotAutoSaveToggled(_ sender: NSButton) {
        let enabled = sender.state == .on
        AppController.shared.setWinShotAutoSaveOnZoneOccupancyChangeEnabledFromSettings(enabled)
        syncControls()
    }

    @objc private func maxSnapshotsStepperChanged(_ sender: NSStepper) {
        applyMaxSnapshotsStored(Int(sender.intValue))
    }

    @objc private func maxSnapshotsFieldSubmitted(_ sender: NSTextField) {
        applyMaxSnapshotsStored(sender.integerValue)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let textField = obj.object as? NSTextField, textField == maxSnapshotsTextField else {
            return
        }
        applyMaxSnapshotsStored(textField.integerValue)
    }

    private func applyMaxSnapshotsStored(_ rawValue: Int) {
        AppController.shared.setWinShotMaxSnapshotsStoredFromSettings(rawValue)
        syncControls()
    }

    private func syncControls() {
        let winShotEnabled = AppController.shared.isWinShotEnabled
        winShotCheckbox?.state = winShotEnabled ? .on : .off

        let autoSaveEnabled = AppController.shared.isWinShotAutoSaveOnZoneOccupancyChangeEnabled
        winShotAutoSaveCheckbox?.state = autoSaveEnabled ? .on : .off
        winShotAutoSaveCheckbox?.isEnabled = winShotEnabled
        winShotAutoSaveHintLabel?.textColor = winShotEnabled ? .secondaryLabelColor : .tertiaryLabelColor

        let maxSnapshotsStored = AppController.shared.winShotMaxSnapshotsStoredInSettings
        maxSnapshotsTextField?.integerValue = maxSnapshotsStored
        maxSnapshotsStepper?.integerValue = maxSnapshotsStored
        maxSnapshotsTextField?.isEnabled = winShotEnabled
        maxSnapshotsStepper?.isEnabled = winShotEnabled
        maxSnapshotsLabel?.textColor = winShotEnabled ? .labelColor : .secondaryLabelColor
        maxSnapshotsHintLabel?.textColor = winShotEnabled ? .secondaryLabelColor : .tertiaryLabelColor
    }
}
