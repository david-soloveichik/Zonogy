/// View controller for the General preferences tab
import AppKit

final class GeneralPreferencesViewController: NSViewController {

    private var launchAtLoginCheckbox: NSButton?
    private var launchAtLoginHintLabel: NSTextField?
    private var dockMenusCheckbox: NSButton?
    private var dockMenusHintLabel: NSTextField?
    private var autoShowLauncherCheckbox: NSButton?
    private var autoShowLauncherHintLabel: NSTextField?
    private var targetingModePopUpButton: NSPopUpButton?
    private var targetingModeHintLabel: NSTextField?

    override func loadView() {
        let containerView = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))

        // Title label
        let titleLabel = NSTextField(labelWithString: "General Settings")
        titleLabel.font = NSFont.systemFont(ofSize: 16, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(titleLabel)

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

            launchAtLoginCheckbox.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 24),
            launchAtLoginCheckbox.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),

            launchAtLoginHintLabel.topAnchor.constraint(equalTo: launchAtLoginCheckbox.bottomAnchor, constant: 6),
            launchAtLoginHintLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 40),
            launchAtLoginHintLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -20),

            dockMenusCheckbox.topAnchor.constraint(equalTo: launchAtLoginHintLabel.bottomAnchor, constant: 18),
            dockMenusCheckbox.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),

            dockMenusHintLabel.topAnchor.constraint(equalTo: dockMenusCheckbox.bottomAnchor, constant: 6),
            dockMenusHintLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 40),
            dockMenusHintLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -20),

            autoShowLauncherCheckbox.topAnchor.constraint(equalTo: dockMenusHintLabel.bottomAnchor, constant: 18),
            autoShowLauncherCheckbox.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),

            autoShowLauncherHintLabel.topAnchor.constraint(equalTo: autoShowLauncherCheckbox.bottomAnchor, constant: 6),
            autoShowLauncherHintLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 40),
            autoShowLauncherHintLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -20),

            targetingModeLabel.topAnchor.constraint(equalTo: autoShowLauncherHintLabel.bottomAnchor, constant: 18),
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
        syncLaunchAtLoginCheckbox()
        syncDockMenusCheckbox()
        syncAutoShowLauncherCheckbox()
        syncTargetingModeControl()
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
}
