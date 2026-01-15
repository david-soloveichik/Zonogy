/// View controller for the General preferences tab
import AppKit
import ApplicationServices

final class GeneralPreferencesViewController: NSViewController {

    private var accessibilityPollingTimer: Timer?
    private var lastKnownAccessibilityState: Bool = false
    private var accessibilityStatusView: NSView?
    private var accessibilityStatusIcon: NSImageView?
    private var accessibilityStatusLabel: NSTextField?
    private var launchAtLoginCheckbox: NSButton?
    private var launchAtLoginHintLabel: NSTextField?
    private var dockMenusCheckbox: NSButton?
    private var dockMenusHintLabel: NSTextField?
    private var winShotCheckbox: NSButton?
    private var winShotHintLabel: NSTextField?
    private var winShotAutoSaveCheckbox: NSButton?
    private var winShotAutoSaveHintLabel: NSTextField?
    private var autoShowLauncherCheckbox: NSButton?
    private var autoShowLauncherHintLabel: NSTextField?
    private var targetingModePopUpButton: NSPopUpButton?
    private var targetingModeHintLabel: NSTextField?

    override func loadView() {
        let containerView = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 580))

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

        let winShotCheckbox = NSButton(checkboxWithTitle: "Enable WinShot", target: self, action: #selector(winShotToggled(_:)))
        winShotCheckbox.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(winShotCheckbox)
        self.winShotCheckbox = winShotCheckbox

        let winShotHintLabel = NSTextField(wrappingLabelWithString: "Save and restore window arrangement snapshots with Control-Cmd-Tab. (Requires Screen Recording permission.)")
        winShotHintLabel.font = NSFont.systemFont(ofSize: 12)
        winShotHintLabel.textColor = .secondaryLabelColor
        winShotHintLabel.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(winShotHintLabel)
        self.winShotHintLabel = winShotHintLabel

        let winShotAutoSaveCheckbox = NSButton(checkboxWithTitle: "Auto-save snapshot on Clear Zones", target: self, action: #selector(winShotAutoSaveToggled(_:)))
        winShotAutoSaveCheckbox.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(winShotAutoSaveCheckbox)
        self.winShotAutoSaveCheckbox = winShotAutoSaveCheckbox

        let winShotAutoSaveHintLabel = NSTextField(wrappingLabelWithString: "Automatically create a snapshot before clearing zones.")
        winShotAutoSaveHintLabel.font = NSFont.systemFont(ofSize: 12)
        winShotAutoSaveHintLabel.textColor = .secondaryLabelColor
        winShotAutoSaveHintLabel.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(winShotAutoSaveHintLabel)
        self.winShotAutoSaveHintLabel = winShotAutoSaveHintLabel

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
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let versionLabel = NSTextField(labelWithString: "Zonogy Window Manager \(version)")
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

            launchAtLoginCheckbox.topAnchor.constraint(equalTo: accessibilityStatusView.bottomAnchor, constant: 18),
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

            winShotCheckbox.topAnchor.constraint(equalTo: dockMenusHintLabel.bottomAnchor, constant: 18),
            winShotCheckbox.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),

            winShotHintLabel.topAnchor.constraint(equalTo: winShotCheckbox.bottomAnchor, constant: 6),
            winShotHintLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 40),
            winShotHintLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -20),

            winShotAutoSaveCheckbox.topAnchor.constraint(equalTo: winShotHintLabel.bottomAnchor, constant: 10),
            winShotAutoSaveCheckbox.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 40),

            winShotAutoSaveHintLabel.topAnchor.constraint(equalTo: winShotAutoSaveCheckbox.bottomAnchor, constant: 6),
            winShotAutoSaveHintLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 60),
            winShotAutoSaveHintLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -20),

            targetingModeLabel.topAnchor.constraint(equalTo: winShotAutoSaveHintLabel.bottomAnchor, constant: 18),
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
        self.preferredContentSize = NSSize(width: 500, height: 580)
        lastKnownAccessibilityState = AXIsProcessTrusted()
        syncAccessibilityStatus()
        syncLaunchAtLoginCheckbox()
        syncDockMenusCheckbox()
        syncWinShotCheckboxes()
        syncAutoShowLauncherCheckbox()
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

    @objc private func winShotToggled(_ sender: NSButton) {
        let enabled = sender.state == .on
        AppController.shared.setWinShotEnabledFromSettings(enabled)
        syncWinShotCheckboxes()
    }

    @objc private func winShotAutoSaveToggled(_ sender: NSButton) {
        let enabled = sender.state == .on
        AppController.shared.setWinShotAutoSaveOnClearZonesEnabledFromSettings(enabled)
        syncWinShotCheckboxes()
    }

    private func syncWinShotCheckboxes() {
        let winShotEnabled = AppController.shared.isWinShotEnabled
        winShotCheckbox?.state = winShotEnabled ? .on : .off

        let autoSaveEnabled = AppController.shared.isWinShotAutoSaveOnClearZonesEnabled
        winShotAutoSaveCheckbox?.state = autoSaveEnabled ? .on : .off
        winShotAutoSaveCheckbox?.isEnabled = winShotEnabled
        winShotAutoSaveHintLabel?.textColor = winShotEnabled ? .secondaryLabelColor : .tertiaryLabelColor
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

    @objc private func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}
