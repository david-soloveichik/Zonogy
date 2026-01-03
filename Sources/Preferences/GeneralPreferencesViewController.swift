/// View controller for the General preferences tab
import AppKit

final class GeneralPreferencesViewController: NSViewController {

    private var dockMenusCheckbox: NSButton?
    private var dockMenusHintLabel: NSTextField?
    private var autoShowLauncherCheckbox: NSButton?
    private var autoShowLauncherHintLabel: NSTextField?

    override func loadView() {
        let containerView = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))

        // Title label
        let titleLabel = NSTextField(labelWithString: "General Settings")
        titleLabel.font = NSFont.systemFont(ofSize: 16, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(titleLabel)

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

        // Version info
        let versionLabel = NSTextField(labelWithString: "Zonogy Window Manager")
        versionLabel.font = NSFont.systemFont(ofSize: 11)
        versionLabel.textColor = .tertiaryLabelColor
        versionLabel.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(versionLabel)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 20),
            titleLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),

            dockMenusCheckbox.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 24),
            dockMenusCheckbox.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),

            dockMenusHintLabel.topAnchor.constraint(equalTo: dockMenusCheckbox.bottomAnchor, constant: 6),
            dockMenusHintLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 40),
            dockMenusHintLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -20),

            autoShowLauncherCheckbox.topAnchor.constraint(equalTo: dockMenusHintLabel.bottomAnchor, constant: 18),
            autoShowLauncherCheckbox.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),

            autoShowLauncherHintLabel.topAnchor.constraint(equalTo: autoShowLauncherCheckbox.bottomAnchor, constant: 6),
            autoShowLauncherHintLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 40),
            autoShowLauncherHintLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -20),

            versionLabel.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -20),
            versionLabel.centerXAnchor.constraint(equalTo: containerView.centerXAnchor),
        ])

        self.view = containerView
        syncDockMenusCheckbox()
        syncAutoShowLauncherCheckbox()
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
}
