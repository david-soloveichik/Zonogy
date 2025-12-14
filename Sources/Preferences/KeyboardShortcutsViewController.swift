/// View controller for the Keyboard Shortcuts preferences tab
import AppKit
import Carbon

final class KeyboardShortcutsViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {

    private var tableView: NSTableView!
    private var scrollView: NSScrollView!
    private var resetAllButton: NSButton!
    private let actions = KeyboardShortcutPreferences.ShortcutAction.allCases
    private var recordingRow: Int?
    private var localEventMonitor: Any?
    private var globalClickMonitor: Any?

    private var recordingAction: KeyboardShortcutPreferences.ShortcutAction? {
        guard let row = recordingRow, row < actions.count else { return nil }
        return actions[row]
    }

    override func loadView() {
        let containerView = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))

        setupTableView(in: containerView)
        setupResetButton(in: containerView)

        self.view = containerView
    }

    private func setupTableView(in container: NSView) {
        scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        tableView = NSTableView()
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = 36
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.selectionHighlightStyle = .none

        // Action column
        let actionColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("action"))
        actionColumn.title = "Action"
        actionColumn.width = 250
        actionColumn.minWidth = 150
        tableView.addTableColumn(actionColumn)

        // Shortcut column
        let shortcutColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("shortcut"))
        shortcutColumn.title = "Shortcut"
        shortcutColumn.width = 150
        shortcutColumn.minWidth = 100
        tableView.addTableColumn(shortcutColumn)

        // Reset column
        let resetColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("reset"))
        resetColumn.title = ""
        resetColumn.width = 60
        resetColumn.minWidth = 60
        resetColumn.maxWidth = 60
        tableView.addTableColumn(resetColumn)

        scrollView.documentView = tableView
        container.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -60),
        ])
    }

    private func setupResetButton(in container: NSView) {
        resetAllButton = NSButton(title: "Reset All to Defaults", target: self, action: #selector(resetAllShortcuts))
        resetAllButton.translatesAutoresizingMaskIntoConstraints = false
        resetAllButton.bezelStyle = .rounded
        container.addSubview(resetAllButton)

        NSLayoutConstraint.activate([
            resetAllButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -20),
            resetAllButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
        ])
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        actions.count
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let action = actions[row]

        switch tableColumn?.identifier.rawValue {
        case "action":
            return makeActionCell(for: action)
        case "shortcut":
            return makeShortcutCell(for: action, row: row)
        case "reset":
            return makeResetCell(for: action, row: row)
        default:
            return nil
        }
    }

    private func makeActionCell(for action: KeyboardShortcutPreferences.ShortcutAction) -> NSView {
        let cell = NSTableCellView()
        let textField = NSTextField(labelWithString: action.displayName)
        textField.font = NSFont.systemFont(ofSize: 13)
        textField.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(textField)
        cell.textField = textField

        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])

        return cell
    }

    private func makeShortcutCell(for action: KeyboardShortcutPreferences.ShortcutAction, row: Int) -> NSView {
        let cell = NSTableCellView()
        let prefs = KeyboardShortcutPreferences.shared

        let button = ShortcutButton()
        button.translatesAutoresizingMaskIntoConstraints = false
        button.shortcutAction = action
        button.row = row
        button.target = self
        button.buttonAction = #selector(shortcutButtonClicked(_:))

        let shortcut = prefs.shortcut(for: action)
        let isRecording = recordingRow == row
        let isCleared = prefs.isCleared(action)

        if isRecording {
            button.title = "Press shortcut..."
            button.bezelStyle = .rounded
            button.bezelColor = NSColor(calibratedRed: 0.4, green: 0.6, blue: 0.85, alpha: 1.0)
            button.contentTintColor = .white
            button.startPulsingAnimation()
        } else if isCleared {
            button.title = "None"
            button.bezelStyle = .recessed
            button.bezelColor = nil
            button.contentTintColor = .tertiaryLabelColor
        } else {
            button.title = shortcut?.displayString ?? "None"
            button.bezelStyle = .recessed
            button.bezelColor = nil
            let isCustom = prefs.isCustomized(action)
            button.contentTintColor = isCustom ? .labelColor : .secondaryLabelColor
        }

        // Add clear button (x) if shortcut is set
        let hasShortcut = !isCleared && shortcut != nil
        if hasShortcut && !isRecording {
            let clearButton = ClearButton()
            clearButton.translatesAutoresizingMaskIntoConstraints = false
            clearButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Clear")
            clearButton.bezelStyle = .recessed
            clearButton.isBordered = false
            clearButton.target = self
            clearButton.shortcutAction = action
            clearButton.buttonAction = #selector(clearShortcut(_:))
            clearButton.contentTintColor = .tertiaryLabelColor

            cell.addSubview(button)
            cell.addSubview(clearButton)

            NSLayoutConstraint.activate([
                button.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                button.centerYAnchor.constraint(equalTo: cell.centerYAnchor),

                clearButton.leadingAnchor.constraint(equalTo: button.trailingAnchor, constant: 2),
                clearButton.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                clearButton.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                clearButton.widthAnchor.constraint(equalToConstant: 20),
            ])
        } else {
            cell.addSubview(button)

            NSLayoutConstraint.activate([
                button.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                button.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                button.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }

        return cell
    }

    private func makeResetCell(for action: KeyboardShortcutPreferences.ShortcutAction, row: Int) -> NSView {
        let cell = NSTableCellView()
        let prefs = KeyboardShortcutPreferences.shared

        // Show reset button if shortcut is customized or cleared
        let isCustom = prefs.isCustomized(action)
        let isCleared = prefs.isCleared(action)

        if isCustom || isCleared {
            let button = ResetButton()
            button.translatesAutoresizingMaskIntoConstraints = false
            button.image = NSImage(systemSymbolName: "arrow.counterclockwise", accessibilityDescription: "Reset to Default")
            button.bezelStyle = .recessed
            button.isBordered = false
            button.target = self
            button.shortcutAction = action
            button.buttonAction = #selector(resetSingleShortcut(_:))

            cell.addSubview(button)

            NSLayoutConstraint.activate([
                button.centerXAnchor.constraint(equalTo: cell.centerXAnchor),
                button.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }

        return cell
    }

    // MARK: - Actions

    @objc private func shortcutButtonClicked(_ sender: ShortcutButton) {
        if recordingRow == sender.row {
            // Already recording this one - cancel
            stopRecording()
        } else {
            // Start recording for this button
            startRecording(row: sender.row)
        }
    }

    private func startRecording(row: Int) {
        // Cancel any existing recording first
        if recordingRow != nil {
            stopRecordingWithoutReload()
        }

        recordingRow = row

        // Suspend global hotkeys while recording
        AppController.shared.hotkeyService.suspend()

        // Start listening for key events
        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            self?.handleKeyEvent(event)
            return nil // Consume the event
        }

        // Monitor for clicks outside the button to cancel recording
        globalClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            self?.handleClickEvent(event)
            return event
        }

        tableView.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 1))
    }

    private func handleClickEvent(_ event: NSEvent) {
        guard let row = recordingRow else { return }

        // Get the button's frame in window coordinates
        let rowView = tableView.rowView(atRow: row, makeIfNecessary: false)
        guard let cellView = rowView?.view(atColumn: 1) as? NSTableCellView,
              let button = cellView.subviews.first as? NSButton else {
            return
        }

        let buttonFrameInWindow = button.convert(button.bounds, to: nil)
        let clickLocation = event.locationInWindow

        if !buttonFrameInWindow.contains(clickLocation) {
            // Click outside the button - cancel recording
            stopRecording()
        }
    }

    private func handleKeyEvent(_ event: NSEvent) {
        guard let action = recordingAction else { return }

        // Ignore pure modifier key presses
        if event.type == .flagsChanged {
            return
        }

        // Check for Escape to cancel
        if event.keyCode == UInt16(kVK_Escape) {
            stopRecording()
            return
        }

        // Get modifiers - convert from Cocoa to Carbon
        var carbonModifiers: UInt32 = 0
        let flags = event.modifierFlags

        if flags.contains(.command) { carbonModifiers |= UInt32(cmdKey) }
        if flags.contains(.control) { carbonModifiers |= UInt32(controlKey) }
        if flags.contains(.option) { carbonModifiers |= UInt32(optionKey) }
        if flags.contains(.shift) { carbonModifiers |= UInt32(shiftKey) }

        // Require at least one modifier (except for function keys)
        let functionKeyCodes: Set<Int> = [
            kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6,
            kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12
        ]
        let isFunctionKey = functionKeyCodes.contains(Int(event.keyCode))
        if carbonModifiers == 0 && !isFunctionKey {
            return
        }

        let shortcut = KeyboardShortcut(keyCode: UInt32(event.keyCode), modifiers: carbonModifiers)

        // Clear any existing assignment of this shortcut to another action
        if let conflictingAction = KeyboardShortcutPreferences.shared.action(for: shortcut),
           conflictingAction != action {
            KeyboardShortcutPreferences.shared.clearShortcut(for: conflictingAction)
        }

        KeyboardShortcutPreferences.shared.setShortcut(shortcut, for: action)

        stopRecording()
    }

    private func stopRecordingWithoutReload() {
        if let monitor = localEventMonitor {
            NSEvent.removeMonitor(monitor)
            localEventMonitor = nil
        }
        if let monitor = globalClickMonitor {
            NSEvent.removeMonitor(monitor)
            globalClickMonitor = nil
        }

        // Resume global hotkeys
        AppController.shared.hotkeyService.resume()
        recordingRow = nil
    }

    private func stopRecording() {
        guard recordingRow != nil else { return }
        stopRecordingWithoutReload()
        tableView.reloadData()
    }

    @objc private func clearShortcut(_ sender: ClearButton) {
        KeyboardShortcutPreferences.shared.clearShortcut(for: sender.shortcutAction)
        tableView.reloadData()
    }

    @objc private func resetSingleShortcut(_ sender: ResetButton) {
        KeyboardShortcutPreferences.shared.resetToDefault(action: sender.shortcutAction)
        tableView.reloadData()
    }

    @objc private func resetAllShortcuts() {
        let alert = NSAlert()
        alert.messageText = "Reset All Keyboard Shortcuts"
        alert.informativeText = "Are you sure you want to reset all keyboard shortcuts to their defaults?"
        alert.addButton(withTitle: "Reset All")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning

        if alert.runModal() == .alertFirstButtonReturn {
            KeyboardShortcutPreferences.shared.resetAllToDefaults()
            tableView.reloadData()
        }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        stopRecording()
    }
}

// MARK: - Helper Classes

private class ShortcutButton: NSButton {
    var shortcutAction: KeyboardShortcutPreferences.ShortcutAction!
    var row: Int = 0
    var buttonAction: Selector?
    private var isPulsing = false

    private let pulseMinAlpha: CGFloat = 0.55
    private let pulseMaxAlpha: CGFloat = 1.0
    private let pulseDuration: TimeInterval = 0.7

    override func sendAction(_ action: Selector?, to target: Any?) -> Bool {
        if let buttonAction = buttonAction {
            return super.sendAction(buttonAction, to: target)
        }
        return super.sendAction(action, to: target)
    }

    func startPulsingAnimation() {
        guard !isPulsing else { return }
        isPulsing = true

        self.wantsLayer = true
        self.alphaValue = pulseMaxAlpha

        animatePulse(toAlpha: pulseMinAlpha)
    }

    private func animatePulse(toAlpha alpha: CGFloat) {
        guard isPulsing else { return }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = pulseDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            self.animator().alphaValue = alpha
        }, completionHandler: { [weak self] in
            guard let self = self, self.isPulsing else { return }
            let nextAlpha = alpha == self.pulseMinAlpha ? self.pulseMaxAlpha : self.pulseMinAlpha
            self.animatePulse(toAlpha: nextAlpha)
        })
    }

    func stopPulsingAnimation() {
        isPulsing = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            self.animator().alphaValue = 1.0
        }
    }

    override func removeFromSuperview() {
        stopPulsingAnimation()
        super.removeFromSuperview()
    }
}

private class ClearButton: NSButton {
    var shortcutAction: KeyboardShortcutPreferences.ShortcutAction!
    var buttonAction: Selector?

    override func sendAction(_ action: Selector?, to target: Any?) -> Bool {
        if let buttonAction = buttonAction {
            return super.sendAction(buttonAction, to: target)
        }
        return super.sendAction(action, to: target)
    }
}

private class ResetButton: NSButton {
    var shortcutAction: KeyboardShortcutPreferences.ShortcutAction!
    var buttonAction: Selector?

    override func sendAction(_ action: Selector?, to target: Any?) -> Bool {
        if let buttonAction = buttonAction {
            return super.sendAction(buttonAction, to: target)
        }
        return super.sendAction(action, to: target)
    }
}
