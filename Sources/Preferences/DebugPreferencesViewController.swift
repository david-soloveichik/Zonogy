/// View controller for the Debug preferences tab.
import AppKit

final class DebugPreferencesViewController: NSViewController {
    private var saveLogCheckbox: NSButton?
    private var dockOverlayCheckbox: NSButton?
    private var fullScreenOverlayCheckbox: NSButton?
    private var disablePrePositionCheckbox: NSButton?
    private var disableNativeTabsCheckbox: NSButton?

    override func loadView() {
        let containerView = NSView(frame: NSRect(x: 0, y: 0, width: 580, height: 500))

        let titleLabel = NSTextField(labelWithString: "Debug Settings")
        titleLabel.font = NSFont.systemFont(ofSize: 16, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(titleLabel)

        let saveLogCheckbox = NSButton(
            checkboxWithTitle: "Save debug log to file",
            target: self,
            action: #selector(saveLogToggled(_:))
        )
        saveLogCheckbox.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(saveLogCheckbox)
        self.saveLogCheckbox = saveLogCheckbox

        let saveLogHintLabel = NSTextField(
            wrappingLabelWithString: "When enabled, Zonogy writes /tmp/zonogy-debug.log. Turning this on clears that file."
        )
        saveLogHintLabel.font = NSFont.systemFont(ofSize: 12)
        saveLogHintLabel.textColor = .secondaryLabelColor
        saveLogHintLabel.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(saveLogHintLabel)

        let dockOverlayCheckbox = NSButton(
            checkboxWithTitle: "Show Dock debug rectangle",
            target: self,
            action: #selector(dockOverlayToggled(_:))
        )
        dockOverlayCheckbox.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(dockOverlayCheckbox)
        self.dockOverlayCheckbox = dockOverlayCheckbox

        let dockOverlayHintLabel = NSTextField(
            wrappingLabelWithString: "Shows a blue rectangle around the Dock frame used by DockMenus."
        )
        dockOverlayHintLabel.font = NSFont.systemFont(ofSize: 12)
        dockOverlayHintLabel.textColor = .secondaryLabelColor
        dockOverlayHintLabel.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(dockOverlayHintLabel)

        let fullScreenOverlayCheckbox = NSButton(
            checkboxWithTitle: "Show full-screen debug rectangles",
            target: self,
            action: #selector(fullScreenOverlayToggled(_:))
        )
        fullScreenOverlayCheckbox.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(fullScreenOverlayCheckbox)
        self.fullScreenOverlayCheckbox = fullScreenOverlayCheckbox

        let fullScreenOverlayHintLabel = NSTextField(
            wrappingLabelWithString: "Shows orange rectangles around displays detected as native macOS full-screen."
        )
        fullScreenOverlayHintLabel.font = NSFont.systemFont(ofSize: 12)
        fullScreenOverlayHintLabel.textColor = .secondaryLabelColor
        fullScreenOverlayHintLabel.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(fullScreenOverlayHintLabel)

        let disablePrePositionCheckbox = NSButton(
            checkboxWithTitle: "Disable pre-position of minimized windows prior to unminimize",
            target: self,
            action: #selector(disablePrePositionToggled(_:))
        )
        disablePrePositionCheckbox.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(disablePrePositionCheckbox)
        self.disablePrePositionCheckbox = disablePrePositionCheckbox

        let disablePrePositionHintLabel = NSTextField(
            wrappingLabelWithString: "When on, Zonogy skips moving a minimized window to its destination frame before unminimizing; the window is positioned only after it is restored."
        )
        disablePrePositionHintLabel.font = NSFont.systemFont(ofSize: 12)
        disablePrePositionHintLabel.textColor = .secondaryLabelColor
        disablePrePositionHintLabel.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(disablePrePositionHintLabel)

        let disableNativeTabsCheckbox = NSButton(
            checkboxWithTitle: "Disable native macOS tab handling",
            target: self,
            action: #selector(disableNativeTabsToggled(_:))
        )
        disableNativeTabsCheckbox.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(disableNativeTabsCheckbox)
        self.disableNativeTabsCheckbox = disableNativeTabsCheckbox

        let disableNativeTabsHintLabel = NSTextField(
            wrappingLabelWithString: "When on, disables Zonogy's special handling of native macOS tabs."
        )
        disableNativeTabsHintLabel.font = NSFont.systemFont(ofSize: 12)
        disableNativeTabsHintLabel.textColor = .secondaryLabelColor
        disableNativeTabsHintLabel.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(disableNativeTabsHintLabel)

        let filesHeaderLabel = NSTextField(labelWithString: "Debug File Locations")
        filesHeaderLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        filesHeaderLabel.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(filesHeaderLabel)

        let debugLogPathLabel = NSTextField(
            wrappingLabelWithString: "Debug log: \(Logger.logPath)"
        )
        debugLogPathLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        debugLogPathLabel.textColor = .secondaryLabelColor
        debugLogPathLabel.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(debugLogPathLabel)

        let timeTravelLogPathLabel = NSTextField(
            wrappingLabelWithString: "Time-travel log: \(Logger.timeTravelLogPath)"
        )
        timeTravelLogPathLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        timeTravelLogPathLabel.textColor = .secondaryLabelColor
        timeTravelLogPathLabel.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(timeTravelLogPathLabel)

        let timeTravelHintLabel = NSTextField(
            wrappingLabelWithString: "Time-travel log capture uses the keyboard shortcut (default: Control-Command-Z) and does not depend on these toggles."
        )
        timeTravelHintLabel.font = NSFont.systemFont(ofSize: 12)
        timeTravelHintLabel.textColor = .secondaryLabelColor
        timeTravelHintLabel.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(timeTravelHintLabel)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 20),
            titleLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),

            saveLogCheckbox.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 18),
            saveLogCheckbox.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),

            saveLogHintLabel.topAnchor.constraint(equalTo: saveLogCheckbox.bottomAnchor, constant: 6),
            saveLogHintLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 40),
            saveLogHintLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -20),

            dockOverlayCheckbox.topAnchor.constraint(equalTo: saveLogHintLabel.bottomAnchor, constant: 14),
            dockOverlayCheckbox.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),

            dockOverlayHintLabel.topAnchor.constraint(equalTo: dockOverlayCheckbox.bottomAnchor, constant: 6),
            dockOverlayHintLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 40),
            dockOverlayHintLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -20),

            fullScreenOverlayCheckbox.topAnchor.constraint(equalTo: dockOverlayHintLabel.bottomAnchor, constant: 14),
            fullScreenOverlayCheckbox.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),

            fullScreenOverlayHintLabel.topAnchor.constraint(equalTo: fullScreenOverlayCheckbox.bottomAnchor, constant: 6),
            fullScreenOverlayHintLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 40),
            fullScreenOverlayHintLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -20),

            disablePrePositionCheckbox.topAnchor.constraint(equalTo: fullScreenOverlayHintLabel.bottomAnchor, constant: 14),
            disablePrePositionCheckbox.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),

            disablePrePositionHintLabel.topAnchor.constraint(equalTo: disablePrePositionCheckbox.bottomAnchor, constant: 6),
            disablePrePositionHintLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 40),
            disablePrePositionHintLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -20),

            disableNativeTabsCheckbox.topAnchor.constraint(equalTo: disablePrePositionHintLabel.bottomAnchor, constant: 14),
            disableNativeTabsCheckbox.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),

            disableNativeTabsHintLabel.topAnchor.constraint(equalTo: disableNativeTabsCheckbox.bottomAnchor, constant: 6),
            disableNativeTabsHintLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 40),
            disableNativeTabsHintLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -20),

            filesHeaderLabel.topAnchor.constraint(equalTo: disableNativeTabsHintLabel.bottomAnchor, constant: 20),
            filesHeaderLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),

            debugLogPathLabel.topAnchor.constraint(equalTo: filesHeaderLabel.bottomAnchor, constant: 8),
            debugLogPathLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),
            debugLogPathLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -20),

            timeTravelLogPathLabel.topAnchor.constraint(equalTo: debugLogPathLabel.bottomAnchor, constant: 4),
            timeTravelLogPathLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),
            timeTravelLogPathLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -20),

            timeTravelHintLabel.topAnchor.constraint(equalTo: timeTravelLogPathLabel.bottomAnchor, constant: 10),
            timeTravelHintLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),
            timeTravelHintLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -20),
        ])

        self.view = containerView
        self.preferredContentSize = NSSize(width: 580, height: 500)
        syncControls()
    }

    @objc private func saveLogToggled(_ sender: NSButton) {
        let enabled = sender.state == .on
        AppController.shared.setDebugLogToFileEnabledFromSettings(enabled)
        syncControls()
    }

    @objc private func dockOverlayToggled(_ sender: NSButton) {
        let enabled = sender.state == .on
        AppController.shared.setDockMenusDebugOverlayEnabledFromSettings(enabled)
        syncControls()
    }

    @objc private func fullScreenOverlayToggled(_ sender: NSButton) {
        let enabled = sender.state == .on
        AppController.shared.setFullScreenDebugOverlayEnabledFromSettings(enabled)
        syncControls()
    }

    @objc private func disablePrePositionToggled(_ sender: NSButton) {
        let enabled = sender.state == .on
        AppController.shared.setDisablePrePositionBeforeUnminimizeFromSettings(enabled)
        syncControls()
    }

    @objc private func disableNativeTabsToggled(_ sender: NSButton) {
        let disabled = sender.state == .on
        AppController.shared.setNativeTabHandlingDisabledFromSettings(disabled)
        syncControls()
    }

    private func syncControls() {
        saveLogCheckbox?.state = AppController.shared.isDebugLogToFileEnabledInSettings ? .on : .off
        dockOverlayCheckbox?.state = AppController.shared.isDockMenusDebugOverlayEnabledInSettings ? .on : .off
        fullScreenOverlayCheckbox?.state = AppController.shared.isFullScreenDebugOverlayEnabledInSettings ? .on : .off
        disablePrePositionCheckbox?.state = AppController.shared.isDisablePrePositionBeforeUnminimizeInSettings ? .on : .off
        disableNativeTabsCheckbox?.state = AppController.shared.isNativeTabHandlingDisabledInSettings ? .on : .off
    }
}
