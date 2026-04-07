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
    private var dockMenusCheckbox: NSButton?
    private var dockMenusHintLabel: NSTextField?
    private var autoShowLauncherCheckbox: NSButton?
    private var autoShowLauncherHintLabel: NSTextField?
    private var stickyResizeCheckbox: NSButton?
    private var stickyResizeHintLabel: NSTextField?
    private var targetingModePopUpButton: NSPopUpButton?
    private var targetingModeHintLabel: NSTextField?

    override func loadView() {
        let containerView = NSView(frame: NSRect(x: 0, y: 0, width: 580, height: 700))

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

        let autoShowLauncherCheckbox = NSButton(checkboxWithTitle: "Automatically show Launcher for empty tiling zones", target: self, action: #selector(autoShowLauncherToggled(_:)))
        autoShowLauncherCheckbox.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(autoShowLauncherCheckbox)
        self.autoShowLauncherCheckbox = autoShowLauncherCheckbox

        let autoShowLauncherHintLabel = NSTextField(wrappingLabelWithString: "When a tiling zone becomes empty, Zonogy can open the Launcher automatically.")
        autoShowLauncherHintLabel.font = NSFont.systemFont(ofSize: 12)
        autoShowLauncherHintLabel.textColor = .secondaryLabelColor
        autoShowLauncherHintLabel.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(autoShowLauncherHintLabel)
        self.autoShowLauncherHintLabel = autoShowLauncherHintLabel

        let stickyResizeCheckbox = NSButton(
            checkboxWithTitle: "Sticky Resize for tiled windows",
            target: self,
            action: #selector(stickyResizeToggled(_:))
        )
        stickyResizeCheckbox.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(stickyResizeCheckbox)
        self.stickyResizeCheckbox = stickyResizeCheckbox

        let stickyResizeHintLabel = NSTextField(
            wrappingLabelWithString: "When enabled, manually resized tiled windows return to the zone frame when inactive, then restore their remembered size when reactivated until that screen's tiling geometry changes."
        )
        stickyResizeHintLabel.font = NSFont.systemFont(ofSize: 12)
        stickyResizeHintLabel.textColor = .secondaryLabelColor
        stickyResizeHintLabel.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(stickyResizeHintLabel)
        self.stickyResizeHintLabel = stickyResizeHintLabel

        let targetingModeLabel = NSTextField(labelWithString: "Targeting mode:")
        targetingModeLabel.font = NSFont.systemFont(ofSize: 13)
        targetingModeLabel.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(targetingModeLabel)

        let targetingModePopUpButton = NSPopUpButton(frame: .zero, pullsDown: false)
        targetingModePopUpButton.addItems(withTitles: TargetingMode.allCases.map(\.displayName))
        targetingModePopUpButton.target = self
        targetingModePopUpButton.action = #selector(targetingModeChanged(_:))
        targetingModePopUpButton.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(targetingModePopUpButton)
        self.targetingModePopUpButton = targetingModePopUpButton

        let targetingModeHintLabel = NSTextField(wrappingLabelWithString: "In follow-focus mode, the zone containing the active window becomes targeted. In independent mode, targeting follows priority rules.")
        targetingModeHintLabel.font = NSFont.systemFont(ofSize: 12)
        targetingModeHintLabel.textColor = .secondaryLabelColor
        targetingModeHintLabel.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(targetingModeHintLabel)
        self.targetingModeHintLabel = targetingModeHintLabel

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

            autoShowLauncherCheckbox.topAnchor.constraint(equalTo: launchAtLoginHintLabel.bottomAnchor, constant: 18),
            autoShowLauncherCheckbox.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),

            autoShowLauncherHintLabel.topAnchor.constraint(equalTo: autoShowLauncherCheckbox.bottomAnchor, constant: 6),
            autoShowLauncherHintLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 40),
            autoShowLauncherHintLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -20),

            dockMenusCheckbox.topAnchor.constraint(equalTo: autoShowLauncherHintLabel.bottomAnchor, constant: 18),
            dockMenusCheckbox.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),

            dockMenusHintLabel.topAnchor.constraint(equalTo: dockMenusCheckbox.bottomAnchor, constant: 6),
            dockMenusHintLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 40),
            dockMenusHintLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -20),

            stickyResizeCheckbox.topAnchor.constraint(equalTo: dockMenusHintLabel.bottomAnchor, constant: 18),
            stickyResizeCheckbox.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),

            stickyResizeHintLabel.topAnchor.constraint(equalTo: stickyResizeCheckbox.bottomAnchor, constant: 6),
            stickyResizeHintLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 40),
            stickyResizeHintLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -20),

            targetingModeLabel.topAnchor.constraint(equalTo: stickyResizeHintLabel.bottomAnchor, constant: 18),
            targetingModeLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),

            targetingModePopUpButton.centerYAnchor.constraint(equalTo: targetingModeLabel.centerYAnchor),
            targetingModePopUpButton.leadingAnchor.constraint(equalTo: targetingModeLabel.trailingAnchor, constant: 8),
            targetingModePopUpButton.trailingAnchor.constraint(lessThanOrEqualTo: containerView.trailingAnchor, constant: -20),

            targetingModeHintLabel.topAnchor.constraint(equalTo: targetingModeLabel.bottomAnchor, constant: 6),
            targetingModeHintLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 40),
            targetingModeHintLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -20),

            versionLabel.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -20),
            versionLabel.centerXAnchor.constraint(equalTo: containerView.centerXAnchor),
        ])

        self.view = containerView
        self.preferredContentSize = NSSize(width: 580, height: 590)
        lastKnownAccessibilityState = AXIsProcessTrusted()
        syncAccessibilityStatus()
        syncScreenRecordingStatus()
        syncLaunchAtLoginCheckbox()
        syncDockMenusCheckbox()
        syncAutoShowLauncherCheckbox()
        syncStickyResizeCheckbox()
        syncTargetingModeControl()
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
        accessibilityPollingTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.syncAccessibilityStatus()
            self?.syncScreenRecordingStatus()
        }
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

    @objc private func dockMenusToggled(_ sender: NSButton) {
        let enabled = sender.state == .on
        AppController.shared.setDockMenusEnabledFromSettings(enabled)
        syncDockMenusCheckbox()
    }

    private func syncDockMenusCheckbox() {
        let enabled = AppController.shared.isDockMenusEnabledInSettings
        dockMenusCheckbox?.state = enabled ? .on : .off
    }

    @objc private func autoShowLauncherToggled(_ sender: NSButton) {
        let enabled = sender.state == .on
        AppController.shared.setAutoShowLauncherForEmptyTilingZonesEnabledFromSettings(enabled)
        syncAutoShowLauncherCheckbox()
    }

    private func syncAutoShowLauncherCheckbox() {
        let enabled = AppController.shared.isAutoShowLauncherForEmptyTilingZonesEnabledInSettings
        autoShowLauncherCheckbox?.state = enabled ? .on : .off
    }

    @objc private func stickyResizeToggled(_ sender: NSButton) {
        let enabled = sender.state == .on
        AppController.shared.setStickyResizeEnabledFromSettings(enabled)
        syncStickyResizeCheckbox()
    }

    private func syncStickyResizeCheckbox() {
        let enabled = AppController.shared.isStickyResizeEnabledInSettings
        stickyResizeCheckbox?.state = enabled ? .on : .off
    }

    @objc private func targetingModeChanged(_ sender: NSPopUpButton) {
        let index = max(0, min(sender.indexOfSelectedItem, TargetingMode.allCases.count - 1))
        let selected = TargetingMode.allCases[index]
        AppController.shared.setTargetingModeFromSettings(selected)
        syncTargetingModeControl()
    }

    private func syncTargetingModeControl() {
        let mode = AppController.shared.targetingModeInSettings
        let index = TargetingMode.allCases.firstIndex(of: mode) ?? 0
        targetingModePopUpButton?.selectItem(at: index)
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
            screenRecordingStatusLabel?.stringValue = "Screen Recording permission granted (only used for WinShot feature)"
            screenRecordingStatusLabel?.textColor = .labelColor
        } else {
            screenRecordingStatusView?.layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.15).cgColor
            screenRecordingStatusView?.layer?.cornerRadius = 6
            screenRecordingStatusIcon?.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Required")
            screenRecordingStatusIcon?.contentTintColor = .systemOrange
            screenRecordingStatusLabel?.stringValue = "Screen Recording permission not granted (only used for WinShot feature)"
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
