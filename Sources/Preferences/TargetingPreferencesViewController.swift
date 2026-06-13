/// View controller for the Targeting preferences tab.
import AppKit

final class TargetingPreferencesViewController: NSViewController {
    private var launcherShortcutTargetsActiveWindowCheckbox: NSButton?
    private var launcherShortcutTargetsActiveWindowHintLabel: NSTextField?
    private var dockMenusTargetsActiveWindowCheckbox: NSButton?
    private var dockMenusTargetsActiveWindowHintLabel: NSTextField?
    private var cmdTabTargetsActiveWindowCheckbox: NSButton?
    private var cmdTabTargetsActiveWindowHintLabel: NSTextField?

    override func loadView() {
        let containerView = NSView(frame: NSRect(x: 0, y: 0, width: 580, height: 440))

        let titleLabel = NSTextField(labelWithString: "Replacing active window")
        titleLabel.font = NSFont.systemFont(ofSize: 16, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(titleLabel)

        let headerDescriptionLabel = NSTextField(
            wrappingLabelWithString: "For some actions, replacing the window you're currently using feels more natural than opening an additional one. With an option below on, your choice replaces that window instead of opening into Zonogy's separate targeted zone. While the Launcher is open, choices always open in its zone instead."
        )
        headerDescriptionLabel.font = NSFont.systemFont(ofSize: 13)
        headerDescriptionLabel.textColor = .secondaryLabelColor
        headerDescriptionLabel.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(headerDescriptionLabel)

        let dockMenusTargetsActiveWindowCheckbox = NSButton(
            checkboxWithTitle: "DockMenus targets zone with active window",
            target: self,
            action: #selector(dockMenusTargetsActiveWindowToggled(_:))
        )
        dockMenusTargetsActiveWindowCheckbox.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(dockMenusTargetsActiveWindowCheckbox)
        self.dockMenusTargetsActiveWindowCheckbox = dockMenusTargetsActiveWindowCheckbox

        let dockMenusTargetsActiveWindowHintLabel = NSTextField(
            wrappingLabelWithString: "Windows from DockMenus replace the active window in its zone."
        )
        dockMenusTargetsActiveWindowHintLabel.font = NSFont.systemFont(ofSize: 12)
        dockMenusTargetsActiveWindowHintLabel.textColor = .secondaryLabelColor
        dockMenusTargetsActiveWindowHintLabel.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(dockMenusTargetsActiveWindowHintLabel)
        self.dockMenusTargetsActiveWindowHintLabel = dockMenusTargetsActiveWindowHintLabel

        let launcherShortcutTargetsActiveWindowCheckbox = NSButton(
            checkboxWithTitle: "Launcher keyboard shortcut targets zone with active window",
            target: self,
            action: #selector(launcherShortcutTargetsActiveWindowToggled(_:))
        )
        launcherShortcutTargetsActiveWindowCheckbox.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(launcherShortcutTargetsActiveWindowCheckbox)
        self.launcherShortcutTargetsActiveWindowCheckbox = launcherShortcutTargetsActiveWindowCheckbox

        let launcherShortcutTargetsActiveWindowHintLabel = NSTextField(            wrappingLabelWithString: "The first shortcut press opens the Launcher on the active window's zone; press again to toggle back to the original target. When off, the first press uses the original target."
        )
        launcherShortcutTargetsActiveWindowHintLabel.font = NSFont.systemFont(ofSize: 12)
        launcherShortcutTargetsActiveWindowHintLabel.textColor = .secondaryLabelColor
        launcherShortcutTargetsActiveWindowHintLabel.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(launcherShortcutTargetsActiveWindowHintLabel)
        self.launcherShortcutTargetsActiveWindowHintLabel = launcherShortcutTargetsActiveWindowHintLabel

        let cmdTabTargetsActiveWindowCheckbox = NSButton(
            checkboxWithTitle: "CmdTab targets zone with active window",
            target: self,
            action: #selector(cmdTabTargetsActiveWindowToggled(_:))
        )
        cmdTabTargetsActiveWindowCheckbox.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(cmdTabTargetsActiveWindowCheckbox)
        self.cmdTabTargetsActiveWindowCheckbox = cmdTabTargetsActiveWindowCheckbox

        let cmdTabTargetsActiveWindowHintLabel = NSTextField(
            wrappingLabelWithString: "Windows from CmdTab replace the active window in its zone."
        )
        cmdTabTargetsActiveWindowHintLabel.font = NSFont.systemFont(ofSize: 12)
        cmdTabTargetsActiveWindowHintLabel.textColor = .secondaryLabelColor
        cmdTabTargetsActiveWindowHintLabel.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(cmdTabTargetsActiveWindowHintLabel)
        self.cmdTabTargetsActiveWindowHintLabel = cmdTabTargetsActiveWindowHintLabel

        let draggingNoteLabel = NSTextField(
            wrappingLabelWithString: "Dragging a window from DockMenus, CmdTab, or the Launcher always lets you place it into the zone you want."
        )
        draggingNoteLabel.font = NSFont.systemFont(ofSize: 13)
        draggingNoteLabel.textColor = .secondaryLabelColor
        draggingNoteLabel.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(draggingNoteLabel)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 20),
            titleLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),

            headerDescriptionLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            headerDescriptionLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),
            headerDescriptionLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -20),

            dockMenusTargetsActiveWindowCheckbox.topAnchor.constraint(equalTo: headerDescriptionLabel.bottomAnchor, constant: 18),
            dockMenusTargetsActiveWindowCheckbox.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),

            dockMenusTargetsActiveWindowHintLabel.topAnchor.constraint(equalTo: dockMenusTargetsActiveWindowCheckbox.bottomAnchor, constant: 6),
            dockMenusTargetsActiveWindowHintLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 40),
            dockMenusTargetsActiveWindowHintLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -20),

            cmdTabTargetsActiveWindowCheckbox.topAnchor.constraint(equalTo: dockMenusTargetsActiveWindowHintLabel.bottomAnchor, constant: 18),
            cmdTabTargetsActiveWindowCheckbox.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),

            cmdTabTargetsActiveWindowHintLabel.topAnchor.constraint(equalTo: cmdTabTargetsActiveWindowCheckbox.bottomAnchor, constant: 6),
            cmdTabTargetsActiveWindowHintLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 40),
            cmdTabTargetsActiveWindowHintLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -20),

            launcherShortcutTargetsActiveWindowCheckbox.topAnchor.constraint(equalTo: cmdTabTargetsActiveWindowHintLabel.bottomAnchor, constant: 18),
            launcherShortcutTargetsActiveWindowCheckbox.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),

            launcherShortcutTargetsActiveWindowHintLabel.topAnchor.constraint(equalTo: launcherShortcutTargetsActiveWindowCheckbox.bottomAnchor, constant: 6),
            launcherShortcutTargetsActiveWindowHintLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 40),
            launcherShortcutTargetsActiveWindowHintLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -20),

            draggingNoteLabel.topAnchor.constraint(equalTo: launcherShortcutTargetsActiveWindowHintLabel.bottomAnchor, constant: 20),
            draggingNoteLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),
            draggingNoteLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -20),
        ])

        self.view = containerView
        self.preferredContentSize = NSSize(width: 580, height: 440)
        syncControls()
    }

    @objc private func launcherShortcutTargetsActiveWindowToggled(_ sender: NSButton) {
        let enabled = sender.state == .on
        AppController.shared.setLauncherShortcutTargetsZoneWithActiveWindowEnabledFromSettings(enabled)
        syncLauncherShortcutTargetsActiveWindowCheckbox()
    }

    @objc private func dockMenusTargetsActiveWindowToggled(_ sender: NSButton) {
        let enabled = sender.state == .on
        AppController.shared.setDockMenusTargetsZoneWithActiveWindowEnabledFromSettings(enabled)
        syncDockMenusTargetsActiveWindowCheckbox()
    }

    @objc private func cmdTabTargetsActiveWindowToggled(_ sender: NSButton) {
        let enabled = sender.state == .on
        AppController.shared.setCmdTabTargetsZoneWithActiveWindowEnabledFromSettings(enabled)
        syncCmdTabTargetsActiveWindowCheckbox()
    }

    private func syncControls() {
        syncLauncherShortcutTargetsActiveWindowCheckbox()
        syncDockMenusTargetsActiveWindowCheckbox()
        syncCmdTabTargetsActiveWindowCheckbox()
    }

    private func syncLauncherShortcutTargetsActiveWindowCheckbox() {
        let enabled = AppController.shared.isLauncherShortcutTargetsZoneWithActiveWindowEnabledInSettings
        launcherShortcutTargetsActiveWindowCheckbox?.state = enabled ? .on : .off
    }

    private func syncDockMenusTargetsActiveWindowCheckbox() {
        let enabled = AppController.shared.isDockMenusTargetsZoneWithActiveWindowEnabledInSettings
        dockMenusTargetsActiveWindowCheckbox?.state = enabled ? .on : .off
    }

    private func syncCmdTabTargetsActiveWindowCheckbox() {
        let enabled = AppController.shared.isCmdTabTargetsZoneWithActiveWindowEnabledInSettings
        cmdTabTargetsActiveWindowCheckbox?.state = enabled ? .on : .off
    }
}
