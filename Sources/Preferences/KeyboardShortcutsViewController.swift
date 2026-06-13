/// View controller for the Keyboard Shortcuts preferences tab
import AppKit
import Carbon

final class KeyboardShortcutsViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, ShortcutRecordingInterceptorDelegate {

    private var tableView: NSTableView!
    private var scrollView: NSScrollView!
    private var resetAllButton: NSButton!
    private let actions = KeyboardShortcutPreferences.ShortcutAction.allCases
    private var recordingRow: Int?
    private var recordingInterceptor: ShortcutRecordingInterceptor?
    private var globalClickMonitor: Any?
    private var appDeactivationObserver: NSObjectProtocol?

    private var recordingAction: KeyboardShortcutPreferences.ShortcutAction? {
        guard let row = recordingRow, row < actions.count else { return nil }
        return actions[row]
    }

    override func loadView() {
        let containerView = NSView(frame: NSRect(x: 0, y: 0, width: 580, height: 400))

        setupTableView(in: containerView)
        setupResetButton(in: containerView)

        self.view = containerView
        self.preferredContentSize = NSSize(width: 580, height: 525)
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
        // Let the Action column absorb extra table width so the compact Shortcut column
        // (which holds the chip + clear/reset buttons) doesn't stretch and leave a void on the right.
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle

        // Action column
        let actionColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("action"))
        actionColumn.title = "Action"
        actionColumn.width = 250
        actionColumn.minWidth = 150
        tableView.addTableColumn(actionColumn)

        // Shortcut column (also hosts the inline clear and reset buttons). Kept compact so it
        // hugs its content; the Action column takes any extra width (see columnAutoresizingStyle).
        let shortcutColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("shortcut"))
        shortcutColumn.title = "Shortcut"
        shortcutColumn.width = 160
        shortcutColumn.minWidth = 160
        tableView.addTableColumn(shortcutColumn)

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
        button.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        // Yield before the accessory buttons: if a very wide shortcut can't fit alongside them,
        // the chip compresses rather than pushing × / ↺ out of the cell.
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let shortcut = prefs.shortcut(for: action)
        let isRecording = recordingRow == row
        let isCleared = prefs.isCleared(action)
        let isAtDefault = shortcut == action.defaultShortcut

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
            button.contentTintColor = isAtDefault ? .secondaryLabelColor : .labelColor
        }

        cell.addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            button.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])

        // Clear (×) and reset (↺) sit at fixed x slots so they line up into columns across
        // every row, regardless of each shortcut chip's width. Reset always sits right of ×.
        // Clear appears only when a shortcut is set; reset only when it differs from its default.
        // Places an accessory at a fixed slot, with a breakable pin so an unusually wide
        // shortcut chip pushes it right (past `leftNeighbor`) instead of overlapping.
        func placeAccessory(_ accessory: NSView, slotX: CGFloat, after leftNeighbor: NSLayoutXAxisAnchor, gap: CGFloat) {
            cell.addSubview(accessory)
            let slotPin = accessory.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: slotX)
            slotPin.priority = .defaultHigh
            NSLayoutConstraint.activate([
                slotPin,
                accessory.leadingAnchor.constraint(greaterThanOrEqualTo: leftNeighbor, constant: gap),
                accessory.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -6),
                accessory.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                accessory.widthAnchor.constraint(equalToConstant: 20),
            ])
        }

        if !isRecording {
            var resetLeftNeighbor = button.trailingAnchor
            var resetGap: CGFloat = 6

            if !isCleared && shortcut != nil {
                let clearButton = makeAccessoryButton(
                    symbol: "xmark.circle.fill",
                    accessibilityDescription: "Clear",
                    tint: .tertiaryLabelColor,
                    action: action,
                    selector: #selector(clearShortcut(_:))
                )
                placeAccessory(clearButton, slotX: Self.clearSlotX, after: button.trailingAnchor, gap: 6)
                resetLeftNeighbor = clearButton.trailingAnchor
                resetGap = 2
            }

            if !isAtDefault {
                let resetButton = makeAccessoryButton(
                    symbol: "arrow.counterclockwise",
                    accessibilityDescription: "Reset to Default",
                    tint: .secondaryLabelColor,
                    action: action,
                    selector: #selector(resetSingleShortcut(_:))
                )
                placeAccessory(resetButton, slotX: Self.resetSlotX, after: resetLeftNeighbor, gap: resetGap)
            }
        }

        return cell
    }

    /// Fixed x offsets (from the cell's leading edge) where the inline clear/reset buttons align.
    /// Sized to clear the widest *default* shortcut chip (Show Launcher's ⌃⌘Space) so every default
    /// row lines up exactly; a wider custom shortcut nudges its buttons right (kept inside the cell
    /// by the trailing clamp in placeAccessory).
    private static let clearSlotX: CGFloat = 100
    private static let resetSlotX: CGFloat = 122

    private func makeAccessoryButton(
        symbol: String,
        accessibilityDescription: String,
        tint: NSColor,
        action: KeyboardShortcutPreferences.ShortcutAction,
        selector: Selector
    ) -> ShortcutAccessoryButton {
        let button = ShortcutAccessoryButton()
        button.translatesAutoresizingMaskIntoConstraints = false
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: accessibilityDescription)
        button.bezelStyle = .recessed
        button.isBordered = false
        button.target = self
        button.shortcutAction = action
        button.buttonAction = selector
        button.contentTintColor = tint
        return button
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

        // Start the CGEventTap-based interceptor to capture system shortcuts
        recordingInterceptor = ShortcutRecordingInterceptor()
        recordingInterceptor?.start(delegate: self)
        guard recordingInterceptor?.isRunning == true else {
            recordingInterceptor = nil
            AppController.shared.hotkeyService.resume()
            recordingRow = nil
            showInputMonitoringAlert()
            tableView.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 1))
            return
        }

        // Monitor for clicks outside the button to cancel recording
        globalClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            self?.handleClickEvent(event)
            return event
        }

        appDeactivationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.stopRecording()
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

    // MARK: - ShortcutRecordingInterceptorDelegate

    func shortcutRecordingInterceptor(
        _ interceptor: ShortcutRecordingInterceptor,
        didCapture keyCode: CGKeyCode,
        modifiers: CGEventFlags
    ) {
        guard let action = recordingAction else { return }

        // Convert CGEventFlags to Carbon modifiers
        var carbonModifiers: UInt32 = 0
        if modifiers.contains(.maskCommand) { carbonModifiers |= UInt32(cmdKey) }
        if modifiers.contains(.maskControl) { carbonModifiers |= UInt32(controlKey) }
        if modifiers.contains(.maskAlternate) { carbonModifiers |= UInt32(optionKey) }
        if modifiers.contains(.maskShift) { carbonModifiers |= UInt32(shiftKey) }

        // Require at least one modifier (except for function keys)
        let functionKeyCodes: Set<Int> = [
            kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6,
            kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12
        ]
        let isFunctionKey = functionKeyCodes.contains(Int(keyCode))
        if carbonModifiers == 0 && !isFunctionKey {
            return
        }

        let shortcut = KeyboardShortcut(keyCode: UInt32(keyCode), modifiers: carbonModifiers)

        // Clear any existing assignment of this shortcut to another action
        if let conflictingAction = KeyboardShortcutPreferences.shared.action(for: shortcut),
           conflictingAction != action {
            KeyboardShortcutPreferences.shared.clearShortcut(for: conflictingAction)
        }

        KeyboardShortcutPreferences.shared.setShortcut(shortcut, for: action)

        stopRecording()
    }

    func shortcutRecordingInterceptorDidCancel(_ interceptor: ShortcutRecordingInterceptor) {
        stopRecording()
    }

    private func stopRecordingWithoutReload() {
        recordingInterceptor?.stop()
        recordingInterceptor = nil

        if let monitor = globalClickMonitor {
            NSEvent.removeMonitor(monitor)
            globalClickMonitor = nil
        }

        if let observer = appDeactivationObserver {
            NotificationCenter.default.removeObserver(observer)
            appDeactivationObserver = nil
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

    @objc private func clearShortcut(_ sender: ShortcutAccessoryButton) {
        KeyboardShortcutPreferences.shared.clearShortcut(for: sender.shortcutAction)
        tableView.reloadData()
    }

    @objc private func resetSingleShortcut(_ sender: ShortcutAccessoryButton) {
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

    private func showInputMonitoringAlert() {
        let alert = NSAlert()
        alert.messageText = "Input Monitoring permission is required"
        alert.informativeText = "Zonogy needs Input Monitoring permission to record system shortcuts like ⌘⇥ (Cmd-Tab). Enable it in System Settings ▸ Privacy & Security ▸ Input Monitoring, then try again."
        alert.addButton(withTitle: "OK")
        alert.alertStyle = .warning
        alert.runModal()
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

/// Small borderless icon button (clear/reset) hosted inline in a shortcut row.
private class ShortcutAccessoryButton: NSButton {
    var shortcutAction: KeyboardShortcutPreferences.ShortcutAction!
    var buttonAction: Selector?

    override func sendAction(_ action: Selector?, to target: Any?) -> Bool {
        if let buttonAction = buttonAction {
            return super.sendAction(buttonAction, to: target)
        }
        return super.sendAction(action, to: target)
    }
}
