/// View controller for the General preferences tab
import AppKit
import ApplicationServices

final class GeneralPreferencesViewController: NSViewController {

    private var accessibilityPollingTimer: Timer?
    private var lastKnownAccessibilityState: Bool = false
    private var accessibilityStatusView: NSView?
    private var accessibilityStatusIcon: NSImageView?
    private var accessibilityStatusLabel: NSTextField?
    private var screenRecordingStatusView: NSView?
    private var screenRecordingStatusIcon: NSImageView?
    private var screenRecordingStatusLabel: NSTextField?
    private var launchAtLoginCheckbox: NSButton?
    private var launchAtLoginHintLabel: NSTextField?
    private var updateCheckCheckbox: NSButton?
    private var updateCheckHintLabel: NSTextField?
    private var dockMenusCheckbox: NSButton?
    private var dockMenusHintLabel: NSTextField?

    override func loadView() {
        let containerView = NSView(frame: NSRect(x: 0, y: 0, width: 580, height: 420))

        // Title label
        let titleLabel = NSTextField(labelWithString: "General Settings")
        titleLabel.font = NSFont.systemFont(ofSize: 16, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(titleLabel)

        // Accessibility status banner
        let accessibilityStatusView = NSView()
        accessibilityStatusView.wantsLayer = true
        accessibilityStatusView.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(accessibilityStatusView)
        self.accessibilityStatusView = accessibilityStatusView

        let accessibilityStatusIcon = NSImageView()
        accessibilityStatusIcon.translatesAutoresizingMaskIntoConstraints = false
        accessibilityStatusIcon.imageScaling = .scaleProportionallyUpOrDown
        accessibilityStatusView.addSubview(accessibilityStatusIcon)
        self.accessibilityStatusIcon = accessibilityStatusIcon

        let accessibilityStatusLabel = NSTextField(wrappingLabelWithString: "")
        accessibilityStatusLabel.font = NSFont.systemFont(ofSize: 12)
        accessibilityStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        accessibilityStatusView.addSubview(accessibilityStatusLabel)
        self.accessibilityStatusLabel = accessibilityStatusLabel

        let accessibilityOpenSettingsButton = NSButton(title: "Open Settings…", target: self, action: #selector(openAccessibilitySettings))
        accessibilityOpenSettingsButton.bezelStyle = NSButton.BezelStyle.recessed
        accessibilityOpenSettingsButton.controlSize = NSControl.ControlSize.small
        accessibilityOpenSettingsButton.translatesAutoresizingMaskIntoConstraints = false
        accessibilityStatusView.addSubview(accessibilityOpenSettingsButton)

        NSLayoutConstraint.activate([
            accessibilityStatusIcon.leadingAnchor.constraint(equalTo: accessibilityStatusView.leadingAnchor, constant: 12),
            accessibilityStatusIcon.centerYAnchor.constraint(equalTo: accessibilityStatusView.centerYAnchor),
            accessibilityStatusIcon.widthAnchor.constraint(equalToConstant: 16),
            accessibilityStatusIcon.heightAnchor.constraint(equalToConstant: 16),

            accessibilityStatusLabel.leadingAnchor.constraint(equalTo: accessibilityStatusIcon.trailingAnchor, constant: 8),
            accessibilityStatusLabel.centerYAnchor.constraint(equalTo: accessibilityStatusView.centerYAnchor),
            accessibilityStatusLabel.trailingAnchor.constraint(lessThanOrEqualTo: accessibilityOpenSettingsButton.leadingAnchor, constant: -8),

            accessibilityOpenSettingsButton.trailingAnchor.constraint(equalTo: accessibilityStatusView.trailingAnchor, constant: -12),
            accessibilityOpenSettingsButton.centerYAnchor.constraint(equalTo: accessibilityStatusView.centerYAnchor),
        ])

        // Screen Recording status banner
        let screenRecordingStatusView = NSView()
        screenRecordingStatusView.wantsLayer = true
        screenRecordingStatusView.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(screenRecordingStatusView)
        self.screenRecordingStatusView = screenRecordingStatusView

        let screenRecordingStatusIcon = NSImageView()
        screenRecordingStatusIcon.translatesAutoresizingMaskIntoConstraints = false
        screenRecordingStatusIcon.imageScaling = .scaleProportionallyUpOrDown
        screenRecordingStatusView.addSubview(screenRecordingStatusIcon)
        self.screenRecordingStatusIcon = screenRecordingStatusIcon

        let screenRecordingStatusLabel = NSTextField(wrappingLabelWithString: "")
        screenRecordingStatusLabel.font = NSFont.systemFont(ofSize: 12)
        screenRecordingStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        screenRecordingStatusView.addSubview(screenRecordingStatusLabel)
        self.screenRecordingStatusLabel = screenRecordingStatusLabel

        let screenRecordingOpenSettingsButton = NSButton(title: "Open Settings…", target: self, action: #selector(openScreenRecordingSettings))
        screenRecordingOpenSettingsButton.bezelStyle = NSButton.BezelStyle.recessed
        screenRecordingOpenSettingsButton.controlSize = NSControl.ControlSize.small
        screenRecordingOpenSettingsButton.translatesAutoresizingMaskIntoConstraints = false
        screenRecordingStatusView.addSubview(screenRecordingOpenSettingsButton)

        NSLayoutConstraint.activate([
            screenRecordingStatusIcon.leadingAnchor.constraint(equalTo: screenRecordingStatusView.leadingAnchor, constant: 12),
            screenRecordingStatusIcon.centerYAnchor.constraint(equalTo: screenRecordingStatusView.centerYAnchor),
            screenRecordingStatusIcon.widthAnchor.constraint(equalToConstant: 16),
            screenRecordingStatusIcon.heightAnchor.constraint(equalToConstant: 16),

            screenRecordingStatusLabel.leadingAnchor.constraint(equalTo: screenRecordingStatusIcon.trailingAnchor, constant: 8),
            screenRecordingStatusLabel.centerYAnchor.constraint(equalTo: screenRecordingStatusView.centerYAnchor),
            screenRecordingStatusLabel.trailingAnchor.constraint(lessThanOrEqualTo: screenRecordingOpenSettingsButton.leadingAnchor, constant: -8),

            screenRecordingOpenSettingsButton.trailingAnchor.constraint(equalTo: screenRecordingStatusView.trailingAnchor, constant: -12),
            screenRecordingOpenSettingsButton.centerYAnchor.constraint(equalTo: screenRecordingStatusView.centerYAnchor),
        ])

        let launchAtLoginCheckbox = NSButton(checkboxWithTitle: "Launch Zonogy at login", target: self, action: #selector(launchAtLoginToggled(_:)))
        launchAtLoginCheckbox.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(launchAtLoginCheckbox)
        self.launchAtLoginCheckbox = launchAtLoginCheckbox

        let launchAtLoginHintLabel = NSTextField(wrappingLabelWithString: "Automatically start Zonogy when you log in to your Mac.")
        launchAtLoginHintLabel.font = NSFont.systemFont(ofSize: 12)
        launchAtLoginHintLabel.textColor = .secondaryLabelColor
        launchAtLoginHintLabel.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(launchAtLoginHintLabel)
        self.launchAtLoginHintLabel = launchAtLoginHintLabel

        let updateCheckCheckbox = NSButton(checkboxWithTitle: "Automatically check for updates", target: self, action: #selector(updateCheckToggled(_:)))
        updateCheckCheckbox.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(updateCheckCheckbox)
        self.updateCheckCheckbox = updateCheckCheckbox

        let updateCheckHintLabel = NSTextField(wrappingLabelWithString: "Once a day, Zonogy checks GitHub for a newer release.")
        updateCheckHintLabel.font = NSFont.systemFont(ofSize: 12)
        updateCheckHintLabel.textColor = .secondaryLabelColor
        updateCheckHintLabel.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(updateCheckHintLabel)
        self.updateCheckHintLabel = updateCheckHintLabel

        let dockMenusCheckbox = NSButton(checkboxWithTitle: "Enable DockMenus", target: self, action: #selector(dockMenusToggled(_:)))
        dockMenusCheckbox.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(dockMenusCheckbox)
        self.dockMenusCheckbox = dockMenusCheckbox

        let dockMenusHintLabel = NSTextField(wrappingLabelWithString: "Hovering over a Dock app shows a window list. Clicking a Dock app uses Zonogy's window selection instead of the default Dock behavior. Shift-click to bypass.")
        dockMenusHintLabel.font = NSFont.systemFont(ofSize: 12)
        dockMenusHintLabel.textColor = .secondaryLabelColor
        dockMenusHintLabel.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(dockMenusHintLabel)
        self.dockMenusHintLabel = dockMenusHintLabel

        // Version info
        let versionLabel = NSTextField(labelWithString: AppVersion.preferencesDisplayString)
        versionLabel.font = NSFont.systemFont(ofSize: 11)
        versionLabel.textColor = .tertiaryLabelColor
        versionLabel.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(versionLabel)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 20),
            titleLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),

            accessibilityStatusView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 16),
            accessibilityStatusView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),
            accessibilityStatusView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -20),
            accessibilityStatusView.heightAnchor.constraint(equalToConstant: 36),

            screenRecordingStatusView.topAnchor.constraint(equalTo: accessibilityStatusView.bottomAnchor, constant: 10),
            screenRecordingStatusView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),
            screenRecordingStatusView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -20),
            screenRecordingStatusView.heightAnchor.constraint(equalToConstant: 36),

            launchAtLoginCheckbox.topAnchor.constraint(equalTo: screenRecordingStatusView.bottomAnchor, constant: 18),
            launchAtLoginCheckbox.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),

            launchAtLoginHintLabel.topAnchor.constraint(equalTo: launchAtLoginCheckbox.bottomAnchor, constant: 6),
            launchAtLoginHintLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 40),
            launchAtLoginHintLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -20),

            updateCheckCheckbox.topAnchor.constraint(equalTo: launchAtLoginHintLabel.bottomAnchor, constant: 18),
            updateCheckCheckbox.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),

            updateCheckHintLabel.topAnchor.constraint(equalTo: updateCheckCheckbox.bottomAnchor, constant: 6),
            updateCheckHintLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 40),
            updateCheckHintLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -20),

            dockMenusCheckbox.topAnchor.constraint(equalTo: updateCheckHintLabel.bottomAnchor, constant: 18),
            dockMenusCheckbox.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),

            dockMenusHintLabel.topAnchor.constraint(equalTo: dockMenusCheckbox.bottomAnchor, constant: 6),
            dockMenusHintLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 40),
            dockMenusHintLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -20),

            versionLabel.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -20),
            versionLabel.centerXAnchor.constraint(equalTo: containerView.centerXAnchor),
        ])

        self.view = containerView
        self.preferredContentSize = NSSize(width: 580, height: 420)
        lastKnownAccessibilityState = AXIsProcessTrusted()
        syncAccessibilityStatus()
        syncScreenRecordingStatus()
        syncLaunchAtLoginCheckbox()
        syncUpdateCheckCheckbox()
        syncDockMenusCheckbox()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        startAccessibilityPolling()
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        stopAccessibilityPolling()
    }

    private func startAccessibilityPolling() {
        stopAccessibilityPolling()
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.syncAccessibilityStatus()
            self?.syncScreenRecordingStatus()
        }
        timer.tolerance = 0.5
        accessibilityPollingTimer = timer
    }

    private func stopAccessibilityPolling() {
        accessibilityPollingTimer?.invalidate()
        accessibilityPollingTimer = nil
    }

    @objc private func launchAtLoginToggled(_ sender: NSButton) {
        let enabled = sender.state == .on
        AppController.shared.setLaunchAtLoginEnabledFromSettings(enabled)
        syncLaunchAtLoginCheckbox()
    }

    private func syncLaunchAtLoginCheckbox() {
        let enabled = AppController.shared.isLaunchAtLoginEnabledInSettings
        launchAtLoginCheckbox?.state = enabled ? .on : .off
    }

    @objc private func updateCheckToggled(_ sender: NSButton) {
        let enabled = sender.state == .on
        AppController.shared.setAutomaticUpdateCheckEnabledFromSettings(enabled)
        syncUpdateCheckCheckbox()
    }

    private func syncUpdateCheckCheckbox() {
        let enabled = AppController.shared.isAutomaticUpdateCheckEnabledInSettings
        updateCheckCheckbox?.state = enabled ? .on : .off
    }

    @objc private func dockMenusToggled(_ sender: NSButton) {
        let enabled = sender.state == .on
        AppController.shared.setDockMenusEnabledFromSettings(enabled)
        syncDockMenusCheckbox()
    }

    private func syncDockMenusCheckbox() {
        let enabled = AppController.shared.isDockMenusEnabledInSettings
        dockMenusCheckbox?.state = enabled ? .on : .off
    }

    private func syncAccessibilityStatus() {
        let hasAccess = AXIsProcessTrusted()

        // Detect transition from no access to access granted
        if hasAccess && !lastKnownAccessibilityState {
            lastKnownAccessibilityState = true
            AppController.shared.restartAfterAccessibilityGranted()
            return  // App is restarting, skip UI update
        } else {
            lastKnownAccessibilityState = hasAccess
        }

        if hasAccess {
            accessibilityStatusView?.layer?.backgroundColor = NSColor.systemGreen.withAlphaComponent(0.15).cgColor
            accessibilityStatusView?.layer?.cornerRadius = 6
            accessibilityStatusIcon?.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Granted")
            accessibilityStatusIcon?.contentTintColor = .systemGreen
            accessibilityStatusLabel?.stringValue = "Accessibility permission granted"
            accessibilityStatusLabel?.textColor = .labelColor
        } else {
            accessibilityStatusView?.layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.15).cgColor
            accessibilityStatusView?.layer?.cornerRadius = 6
            accessibilityStatusIcon?.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Required")
            accessibilityStatusIcon?.contentTintColor = .systemOrange
            accessibilityStatusLabel?.stringValue = "Accessibility permission required for window management"
            accessibilityStatusLabel?.textColor = .labelColor
        }
    }

    private func syncScreenRecordingStatus() {
        let hasAccess = CGPreflightScreenCaptureAccess()

        if hasAccess {
            screenRecordingStatusView?.layer?.backgroundColor = NSColor.systemGreen.withAlphaComponent(0.15).cgColor
            screenRecordingStatusView?.layer?.cornerRadius = 6
            screenRecordingStatusIcon?.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Granted")
            screenRecordingStatusIcon?.contentTintColor = .systemGreen
            screenRecordingStatusLabel?.stringValue = "Screen Recording permission granted (only used for WinShot snapshots feature)"
            screenRecordingStatusLabel?.textColor = .labelColor
        } else {
            screenRecordingStatusView?.layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.15).cgColor
            screenRecordingStatusView?.layer?.cornerRadius = 6
            screenRecordingStatusIcon?.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Required")
            screenRecordingStatusIcon?.contentTintColor = .systemOrange
            screenRecordingStatusLabel?.stringValue = "Screen Recording permission not granted (only used for WinShot snapshots feature)"
            screenRecordingStatusLabel?.textColor = .labelColor
        }
    }

    @objc private func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    @objc private func openScreenRecordingSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }
}
