/// The sheet, opened from the Zones tab, choosing which actions replace the focused window
/// instead of opening into the destination zone: CmdTab, the Launcher shortcut, and DockMenus.
/// Everything is staged in the sheet and stored on Save.
import AppKit

final class TargetingSheetViewController: NSViewController {
    private static let sheetWidth: CGFloat = 540
    private static let edgeInset: CGFloat = 20
    /// A hint sits under its control, level with the control's title rather than its checkbox.
    private static let hintIndent: CGFloat = 20
    private static var contentWidth: CGFloat { sheetWidth - edgeInset * 2 }

    private var cmdTabModePopup: NSPopUpButton!
    private var cmdTabModeHintLabel: NSTextField!
    private var launcherShortcutCheckbox: NSButton!
    private var dockMenusCheckbox: NSButton!

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
            return "CmdTab always opens on the destination zone."
        case .currentAppOnly:
            return "Switching within the current app (⌘`) replaces the focused window in its zone. Switching among all windows (⌘⇥) uses the standard destination."
        case .allWindows:
            return "Both all-windows (⌘⇥) and current-app (⌘`) switching replace the focused window in its zone."
        }
    }

    override func loadView() {
        let title = NSTextField(labelWithString: "Replacing focused window")
        title.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        let subtitle = Self.makeSecondaryLabel(
            "For some actions, replacing the window you're currently using may feel more natural than opening an additional one in the destination zone. With an option below enabled, your choice replaces the focused window instead of opening into the destination zone.",
            width: Self.contentWidth
        )
        let header = NSStackView(views: [title, subtitle])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 4

        let cmdTabLabel = NSTextField(labelWithString: "CmdTab replaces focused window:")
        cmdTabModePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        cmdTabModePopup.target = self
        cmdTabModePopup.action = #selector(updateCmdTabModeHint)
        // The label beside the popup isn't tied to it, so name the setting for assistive clients.
        cmdTabModePopup.setAccessibilityLabel("CmdTab replaces focused window")
        for mode in CmdTabActiveWindowTargetingMode.allCases {
            cmdTabModePopup.addItem(withTitle: Self.title(for: mode))
            cmdTabModePopup.lastItem?.tag = mode.rawValue
        }
        cmdTabModePopup.selectItem(withTag: AppController.shared.cmdTabActiveWindowTargetingModeInSettings.rawValue)
        let cmdTabRow = NSStackView(views: [cmdTabLabel, cmdTabModePopup])
        cmdTabRow.orientation = .horizontal
        cmdTabRow.alignment = .firstBaseline
        cmdTabRow.spacing = 8
        cmdTabModeHintLabel = Self.makeHintLabel("")

        launcherShortcutCheckbox = NSButton(
            checkboxWithTitle: "Launcher keyboard shortcut replaces focused window", target: nil, action: nil)
        launcherShortcutCheckbox.state =
            AppController.shared.isLauncherShortcutTargetsZoneWithActiveWindowEnabledInSettings ? .on : .off
        let launcherShortcutHint = Self.makeHintLabel(
            "The first shortcut press opens the Launcher on the focused window's zone; press again to toggle back to the original destination. When off, the first press uses the original destination."
        )

        dockMenusCheckbox = NSButton(checkboxWithTitle: "DockMenus replaces focused window", target: nil, action: nil)
        dockMenusCheckbox.state = AppController.shared.isDockMenusTargetsZoneWithActiveWindowEnabledInSettings ? .on : .off
        let dockMenusHint = Self.makeHintLabel("Windows from DockMenus replace the focused window in its zone.")

        let stack = NSStackView(views: [
            header,
            Self.makeSetting(cmdTabRow, hint: cmdTabModeHintLabel),
            Self.makeSetting(launcherShortcutCheckbox, hint: launcherShortcutHint),
            Self.makeSetting(dockMenusCheckbox, hint: dockMenusHint),
            makeButtonRow(),
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.edgeInsets = NSEdgeInsets(
            top: Self.edgeInset, left: Self.edgeInset, bottom: Self.edgeInset, right: Self.edgeInset)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView(frame: NSRect(x: 0, y: 0, width: Self.sheetWidth, height: 10))
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            container.widthAnchor.constraint(equalToConstant: Self.sheetWidth),
        ])
        self.view = container

        updateCmdTabModeHint()
    }

    // MARK: - Building blocks

    /// A control above the hint explaining it.
    private static func makeSetting(_ control: NSView, hint: NSTextField) -> NSView {
        let hintRow = NSStackView(views: [hint])
        hintRow.edgeInsets = NSEdgeInsets(top: 0, left: hintIndent, bottom: 0, right: 0)
        let setting = NSStackView(views: [control, hintRow])
        setting.orientation = .vertical
        setting.alignment = .leading
        setting.spacing = 6
        return setting
    }

    private static func makeHintLabel(_ text: String) -> NSTextField {
        makeSecondaryLabel(text, width: contentWidth - hintIndent)
    }

    /// Small secondary print, wrapping at `width`.
    private static func makeSecondaryLabel(_ text: String, width: CGFloat) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = NSFont.systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = width
        return label
    }

    private func makeButtonRow() -> NSView {
        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}" // Escape
        let saveButton = NSButton(title: "Save", target: self, action: #selector(save))
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r" // Return

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [spacer, cancelButton, saveButton])
        row.orientation = .horizontal
        row.spacing = 10
        row.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
        return row
    }

    // MARK: - Actions

    private var selectedCmdTabMode: CmdTabActiveWindowTargetingMode {
        CmdTabActiveWindowTargetingMode(rawValue: cmdTabModePopup.selectedTag())
            ?? CmdTabBehaviorPreferencesStore.defaultTargetingMode
    }

    /// The hint follows the selection; it doubles as the popup's help so it travels with the control.
    @objc private func updateCmdTabModeHint() {
        let hint = Self.hint(for: selectedCmdTabMode)
        cmdTabModeHintLabel.stringValue = hint
        cmdTabModePopup.setAccessibilityHelp(hint)
    }

    @objc private func cancel() {
        dismiss(self)
    }

    @objc private func save() {
        AppController.shared.setCmdTabActiveWindowTargetingModeFromSettings(selectedCmdTabMode)
        AppController.shared.setLauncherShortcutTargetsZoneWithActiveWindowEnabledFromSettings(
            launcherShortcutCheckbox.state == .on)
        AppController.shared.setDockMenusTargetsZoneWithActiveWindowEnabledFromSettings(dockMenusCheckbox.state == .on)
        dismiss(self)
    }
}
