/// View controller for the Targeting preferences tab.
import AppKit

final class TargetingPreferencesViewController: NSViewController {
    private var launcherShortcutTargetsActiveWindowCheckbox: NSButton?
    private var launcherShortcutTargetsActiveWindowHintLabel: NSTextField?
    private var dockMenusTargetsActiveWindowCheckbox: NSButton?
    private var dockMenusTargetsActiveWindowHintLabel: NSTextField?
    private var cmdTabTargetingPopup: NSPopUpButton?
    private var cmdTabTargetingHintLabel: NSTextField?

    private static func title(for mode: CmdTabActiveWindowTargetingMode) -> String {
        switch mode {
        case .off: return "Off"
        case .currentAppOnly: return "Current app only (⌘`)"
        case .allWindows: return "All windows too (⌘⇥)"
        }
    }

    private static func hint(for mode: CmdTabActiveWindowTargetingMode) -> String {
        switch mode {
        case .off:
            return "CmdTab always opens on Zonogy's separate targeted zone."
        case .currentAppOnly:
            return "Switching within the current app (⌘`) replaces the focused window in its zone. Switching among all windows (⌘⇥) uses the standard target."
        case .allWindows:
            return "Both all-windows (⌘⇥) and current-app (⌘`) switching replace the focused window in its zone."
        }
    }

    override func loadView() {
        let containerView = NSView(frame: NSRect(x: 0, y: 0, width: 580, height: 470))

        let titleLabel = NSTextField(labelWithString: "Replacing focused window")
        titleLabel.font = NSFont.systemFont(ofSize: 16, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(titleLabel)

        let headerDescriptionLabel = NSTextField(
            wrappingLabelWithString: "For some actions, replacing the window you're currently using feels more natural than opening an additional one. With an option below enabled, your choice replaces that window instead of opening into Zonogy's separate targeted zone."
        )
        headerDescriptionLabel.font = NSFont.systemFont(ofSize: 13)
        headerDescriptionLabel.textColor = .secondaryLabelColor
        headerDescriptionLabel.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(headerDescriptionLabel)

        let dockMenusTargetsActiveWindowCheckbox = NSButton(
            checkboxWithTitle: "DockMenus targets zone with focused window",
            target: self,
            action: #selector(dockMenusTargetsActiveWindowToggled(_:))
        )
        dockMenusTargetsActiveWindowCheckbox.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(dockMenusTargetsActiveWindowCheckbox)
        self.dockMenusTargetsActiveWindowCheckbox = dockMenusTargetsActiveWindowCheckbox

        let dockMenusTargetsActiveWindowHintLabel = NSTextField(
            wrappingLabelWithString: "Windows from DockMenus replace the focused window in its zone."
        )
        dockMenusTargetsActiveWindowHintLabel.font = NSFont.systemFont(ofSize: 12)
        dockMenusTargetsActiveWindowHintLabel.textColor = .secondaryLabelColor
        dockMenusTargetsActiveWindowHintLabel.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(dockMenusTargetsActiveWindowHintLabel)
        self.dockMenusTargetsActiveWindowHintLabel = dockMenusTargetsActiveWindowHintLabel

        let cmdTabTargetingLabel = NSTextField(labelWithString: "CmdTab targets zone with focused window:")
        cmdTabTargetingLabel.font = NSFont.systemFont(ofSize: 13)
        cmdTabTargetingLabel.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(cmdTabTargetingLabel)

        let cmdTabTargetingPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        cmdTabTargetingPopup.translatesAutoresizingMaskIntoConstraints = false
        cmdTabTargetingPopup.target = self
        cmdTabTargetingPopup.action = #selector(cmdTabTargetingModeChanged(_:))
        for mode in CmdTabActiveWindowTargetingMode.allCases {
            cmdTabTargetingPopup.addItem(withTitle: Self.title(for: mode))
            cmdTabTargetingPopup.lastItem?.tag = mode.rawValue
        }
        containerView.addSubview(cmdTabTargetingPopup)
        self.cmdTabTargetingPopup = cmdTabTargetingPopup

        let cmdTabTargetingHintLabel = NSTextField(wrappingLabelWithString: "")
        cmdTabTargetingHintLabel.font = NSFont.systemFont(ofSize: 12)
        cmdTabTargetingHintLabel.textColor = .secondaryLabelColor
        cmdTabTargetingHintLabel.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(cmdTabTargetingHintLabel)
        self.cmdTabTargetingHintLabel = cmdTabTargetingHintLabel

        let launcherShortcutTargetsActiveWindowCheckbox = NSButton(
            checkboxWithTitle: "Launcher keyboard shortcut targets zone with focused window",
            target: self,
            action: #selector(launcherShortcutTargetsActiveWindowToggled(_:))
        )
        launcherShortcutTargetsActiveWindowCheckbox.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(launcherShortcutTargetsActiveWindowCheckbox)
        self.launcherShortcutTargetsActiveWindowCheckbox = launcherShortcutTargetsActiveWindowCheckbox

        let launcherShortcutTargetsActiveWindowHintLabel = NSTextField(            wrappingLabelWithString: "The first shortcut press opens the Launcher on the focused window's zone; press again to toggle back to the original target. When off, the first press uses the original target."
        )
        launcherShortcutTargetsActiveWindowHintLabel.font = NSFont.systemFont(ofSize: 12)
        launcherShortcutTargetsActiveWindowHintLabel.textColor = .secondaryLabelColor
        launcherShortcutTargetsActiveWindowHintLabel.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(launcherShortcutTargetsActiveWindowHintLabel)
        self.launcherShortcutTargetsActiveWindowHintLabel = launcherShortcutTargetsActiveWindowHintLabel

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

            cmdTabTargetingPopup.topAnchor.constraint(equalTo: dockMenusTargetsActiveWindowHintLabel.bottomAnchor, constant: 16),
            cmdTabTargetingPopup.leadingAnchor.constraint(equalTo: cmdTabTargetingLabel.trailingAnchor, constant: 8),
            cmdTabTargetingLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),
            cmdTabTargetingLabel.centerYAnchor.constraint(equalTo: cmdTabTargetingPopup.centerYAnchor),

            cmdTabTargetingHintLabel.topAnchor.constraint(equalTo: cmdTabTargetingPopup.bottomAnchor, constant: 6),
            cmdTabTargetingHintLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 40),
            cmdTabTargetingHintLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -20),

            launcherShortcutTargetsActiveWindowCheckbox.topAnchor.constraint(equalTo: cmdTabTargetingHintLabel.bottomAnchor, constant: 18),
            launcherShortcutTargetsActiveWindowCheckbox.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),

            launcherShortcutTargetsActiveWindowHintLabel.topAnchor.constraint(equalTo: launcherShortcutTargetsActiveWindowCheckbox.bottomAnchor, constant: 6),
            launcherShortcutTargetsActiveWindowHintLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 40),
            launcherShortcutTargetsActiveWindowHintLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -20),

            draggingNoteLabel.topAnchor.constraint(equalTo: launcherShortcutTargetsActiveWindowHintLabel.bottomAnchor, constant: 20),
            draggingNoteLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),
            draggingNoteLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -20),
        ])

        self.view = containerView
        self.preferredContentSize = NSSize(width: 580, height: 470)
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

    @objc private func cmdTabTargetingModeChanged(_ sender: NSPopUpButton) {
        let mode = CmdTabActiveWindowTargetingMode(rawValue: sender.selectedTag()) ?? CmdTabBehaviorPreferencesStore.defaultTargetingMode
        AppController.shared.setCmdTabActiveWindowTargetingModeFromSettings(mode)
        syncCmdTabTargetingControls()
    }

    private func syncControls() {
        syncLauncherShortcutTargetsActiveWindowCheckbox()
        syncDockMenusTargetsActiveWindowCheckbox()
        syncCmdTabTargetingControls()
    }

    private func syncLauncherShortcutTargetsActiveWindowCheckbox() {
        let enabled = AppController.shared.isLauncherShortcutTargetsZoneWithActiveWindowEnabledInSettings
        launcherShortcutTargetsActiveWindowCheckbox?.state = enabled ? .on : .off
    }

    private func syncDockMenusTargetsActiveWindowCheckbox() {
        let enabled = AppController.shared.isDockMenusTargetsZoneWithActiveWindowEnabledInSettings
        dockMenusTargetsActiveWindowCheckbox?.state = enabled ? .on : .off
    }

    private func syncCmdTabTargetingControls() {
        let mode = AppController.shared.cmdTabActiveWindowTargetingModeInSettings
        cmdTabTargetingPopup?.selectItem(withTag: mode.rawValue)
        cmdTabTargetingHintLabel?.stringValue = Self.hint(for: mode)
    }
}
