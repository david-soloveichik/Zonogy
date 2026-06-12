/// View controller for editing a single app's exception rules

import AppKit

final class ExceptionRuleEditViewController: NSViewController {

    private let originalEntry: ExceptionsPreferencesEntry
    var onSave: ((ExceptionsPreferencesEntry) -> Void)?

    // Checkbox controls for each exception type
    private var ignoreApplicationCheckbox: NSButton!
    private var hasMainWindowCheckbox: NSButton!
    private var ignoreActivationPolicyCheckbox: NSButton!
    private var ignoreZoomButtonCheckbox: NSButton!
    private var requireActiveZoomButtonCheckbox: NSButton!
    private var ignoreHeightCheckbox: NSButton!
    private var manageNonStandardWindowsCheckbox: NSButton!
    private var disallowEmptyTitleCheckbox: NSButton!
    private var snapToZoneCheckbox: NSButton!
    private var doNotResizeWidthCheckbox: NSButton!
    private var disableControlCommandMouseGesturesCheckbox: NSButton!
    private var treatAXUnknownFullWidthAsFullScreenCheckbox: NSButton!
    private var excludedTitlesLabel: NSTextField!
    private var excludedTitlesField: NSTextField!
    private var exceptionControls: [NSControl] = []

    init(entry: ExceptionsPreferencesEntry) {
        self.originalEntry = entry
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let containerView = NSView(frame: NSRect(x: 0, y: 0, width: 450, height: 550))
        containerView.translatesAutoresizingMaskIntoConstraints = false

        setupUI(in: containerView)
        populateFields()

        self.view = containerView
    }

    private func setupUI(in container: NSView) {
        var topAnchor = container.topAnchor

        // App icon
        let icon: NSImage
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: originalEntry.bundleIdentifier) {
            icon = NSWorkspace.shared.icon(forFile: appURL.path)
        } else {
            icon = NSImage(systemSymbolName: "app", accessibilityDescription: "App") ?? NSImage()
        }
        icon.size = NSSize(width: 32, height: 32)

        let iconView = NSImageView(image: icon)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(iconView)

        // Bundle ID label (read-only)
        let bundleIdLabel = NSTextField(labelWithString: "Bundle Identifier:")
        bundleIdLabel.translatesAutoresizingMaskIntoConstraints = false
        bundleIdLabel.font = NSFont.boldSystemFont(ofSize: 12)
        container.addSubview(bundleIdLabel)

        let bundleIdValue = NSTextField(labelWithString: originalEntry.bundleIdentifier)
        bundleIdValue.translatesAutoresizingMaskIntoConstraints = false
        bundleIdValue.font = NSFont.systemFont(ofSize: 12)
        bundleIdValue.textColor = .secondaryLabelColor
        bundleIdValue.lineBreakMode = .byTruncatingMiddle
        container.addSubview(bundleIdValue)

        NSLayoutConstraint.activate([
            iconView.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            iconView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            iconView.widthAnchor.constraint(equalToConstant: 32),
            iconView.heightAnchor.constraint(equalToConstant: 32),

            bundleIdLabel.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            bundleIdLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 12),

            bundleIdValue.topAnchor.constraint(equalTo: bundleIdLabel.bottomAnchor, constant: 2),
            bundleIdValue.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 12),
            bundleIdValue.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
        ])

        topAnchor = iconView.bottomAnchor

        // Separator
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(separator)

        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            separator.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            separator.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
        ])

        topAnchor = separator.bottomAnchor

        ignoreApplicationCheckbox = makeCheckbox(
            title: "Ignore this application altogether",
            tooltip: "Windows from this app are never captured or managed by Zonogy",
            target: self,
            action: #selector(ignoreApplicationChanged)
        )
        container.addSubview(ignoreApplicationCheckbox)

        NSLayoutConstraint.activate([
            ignoreApplicationCheckbox.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            ignoreApplicationCheckbox.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            ignoreApplicationCheckbox.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
        ])
        topAnchor = ignoreApplicationCheckbox.bottomAnchor

        // Exception checkboxes - "Has main window" first
        hasMainWindowCheckbox = makeCheckbox(
            title: "Prefer app's main window",
            tooltip: "For Launcher and DockMenus, treat the window with the lowest CGWindowID as this app's main window and prefer it when choosing a window."
        )
        container.addSubview(hasMainWindowCheckbox)
        exceptionControls.append(hasMainWindowCheckbox)

        NSLayoutConstraint.activate([
            hasMainWindowCheckbox.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            hasMainWindowCheckbox.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            hasMainWindowCheckbox.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
        ])
        topAnchor = hasMainWindowCheckbox.bottomAnchor

        snapToZoneCheckbox = makeCheckbox(
            title: "Snap to zone on self-resize",
            tooltip: "Immediately snap window back when the app resizes it internally"
        )
        container.addSubview(snapToZoneCheckbox)
        exceptionControls.append(snapToZoneCheckbox)

        NSLayoutConstraint.activate([
            snapToZoneCheckbox.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            snapToZoneCheckbox.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            snapToZoneCheckbox.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
        ])
        topAnchor = snapToZoneCheckbox.bottomAnchor

        doNotResizeWidthCheckbox = makeCheckbox(
            title: "Don't resize width",
            tooltip: "Preserve the window's current width when Zonogy moves it into a zone; only the position and height are adjusted"
        )
        container.addSubview(doNotResizeWidthCheckbox)
        exceptionControls.append(doNotResizeWidthCheckbox)

        NSLayoutConstraint.activate([
            doNotResizeWidthCheckbox.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            doNotResizeWidthCheckbox.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            doNotResizeWidthCheckbox.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
        ])
        topAnchor = doNotResizeWidthCheckbox.bottomAnchor

        disableControlCommandMouseGesturesCheckbox = makeCheckbox(
            title: "Disable Control-Command mouse gestures",
            tooltip: "Let this app receive Control-Command clicks and drags instead of Zonogy's mouse-gesture overrides"
        )
        container.addSubview(disableControlCommandMouseGesturesCheckbox)
        exceptionControls.append(disableControlCommandMouseGesturesCheckbox)

        NSLayoutConstraint.activate([
            disableControlCommandMouseGesturesCheckbox.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            disableControlCommandMouseGesturesCheckbox.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            disableControlCommandMouseGesturesCheckbox.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
        ])
        topAnchor = disableControlCommandMouseGesturesCheckbox.bottomAnchor

        disallowEmptyTitleCheckbox = makeCheckbox(
            title: "Disallow empty title windows",
            tooltip: "Don't manage windows with empty titles from this app"
        )
        container.addSubview(disallowEmptyTitleCheckbox)
        exceptionControls.append(disallowEmptyTitleCheckbox)

        NSLayoutConstraint.activate([
            disallowEmptyTitleCheckbox.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            disallowEmptyTitleCheckbox.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            disallowEmptyTitleCheckbox.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
        ])
        topAnchor = disallowEmptyTitleCheckbox.bottomAnchor

        ignoreActivationPolicyCheckbox = makeCheckbox(
            title: "Ignore activation policy",
            tooltip: "Manage windows from helper/accessory apps that aren't .regular activation policy"
        )
        container.addSubview(ignoreActivationPolicyCheckbox)
        exceptionControls.append(ignoreActivationPolicyCheckbox)

        NSLayoutConstraint.activate([
            ignoreActivationPolicyCheckbox.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            ignoreActivationPolicyCheckbox.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            ignoreActivationPolicyCheckbox.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
        ])
        topAnchor = ignoreActivationPolicyCheckbox.bottomAnchor

        ignoreZoomButtonCheckbox = makeCheckbox(
            title: "Ignore zoom button requirement",
            tooltip: "Manage windows that don't have a zoom button"
        )
        container.addSubview(ignoreZoomButtonCheckbox)
        exceptionControls.append(ignoreZoomButtonCheckbox)

        NSLayoutConstraint.activate([
            ignoreZoomButtonCheckbox.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            ignoreZoomButtonCheckbox.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            ignoreZoomButtonCheckbox.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
        ])
        topAnchor = ignoreZoomButtonCheckbox.bottomAnchor

        requireActiveZoomButtonCheckbox = makeCheckbox(
            title: "Require active zoom button",
            tooltip: "Only manage windows whose zoom button is enabled (not grayed out)"
        )
        container.addSubview(requireActiveZoomButtonCheckbox)
        exceptionControls.append(requireActiveZoomButtonCheckbox)

        NSLayoutConstraint.activate([
            requireActiveZoomButtonCheckbox.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            requireActiveZoomButtonCheckbox.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            requireActiveZoomButtonCheckbox.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
        ])
        topAnchor = requireActiveZoomButtonCheckbox.bottomAnchor

        ignoreHeightCheckbox = makeCheckbox(
            title: "Ignore height requirement",
            tooltip: "Manage windows shorter than 250px"
        )
        container.addSubview(ignoreHeightCheckbox)
        exceptionControls.append(ignoreHeightCheckbox)

        NSLayoutConstraint.activate([
            ignoreHeightCheckbox.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            ignoreHeightCheckbox.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            ignoreHeightCheckbox.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
        ])
        topAnchor = ignoreHeightCheckbox.bottomAnchor

        manageNonStandardWindowsCheckbox = makeCheckbox(
            title: "Manage non-standard windows",
            tooltip: "Manage windows even if they report a non-standard accessibility role or subrole (e.g., AXUnknown / AXDialog, as some Adobe apps do)"
        )
        container.addSubview(manageNonStandardWindowsCheckbox)
        exceptionControls.append(manageNonStandardWindowsCheckbox)

        NSLayoutConstraint.activate([
            manageNonStandardWindowsCheckbox.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            manageNonStandardWindowsCheckbox.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            manageNonStandardWindowsCheckbox.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
        ])
        topAnchor = manageNonStandardWindowsCheckbox.bottomAnchor

        treatAXUnknownFullWidthAsFullScreenCheckbox = makeCheckbox(
            title: "Treat AXUnknown full-width windows as full-screen",
            tooltip: "Only enable for apps where AXFullScreen is missing/unreliable (e.g., some presentation windows)"
        )
        container.addSubview(treatAXUnknownFullWidthAsFullScreenCheckbox)
        exceptionControls.append(treatAXUnknownFullWidthAsFullScreenCheckbox)

        NSLayoutConstraint.activate([
            treatAXUnknownFullWidthAsFullScreenCheckbox.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            treatAXUnknownFullWidthAsFullScreenCheckbox.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            treatAXUnknownFullWidthAsFullScreenCheckbox.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
        ])
        topAnchor = treatAXUnknownFullWidthAsFullScreenCheckbox.bottomAnchor

        // Excluded window titles
        excludedTitlesLabel = NSTextField(labelWithString: "Excluded window titles (comma-separated):")
        excludedTitlesLabel.translatesAutoresizingMaskIntoConstraints = false
        excludedTitlesLabel.font = NSFont.systemFont(ofSize: 12)
        container.addSubview(excludedTitlesLabel)

        excludedTitlesField = NSTextField()
        excludedTitlesField.translatesAutoresizingMaskIntoConstraints = false
        excludedTitlesField.placeholderString = "e.g., Preferences, Settings"
        excludedTitlesField.font = NSFont.systemFont(ofSize: 12)
        container.addSubview(excludedTitlesField)
        exceptionControls.append(excludedTitlesField)

        NSLayoutConstraint.activate([
            excludedTitlesLabel.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            excludedTitlesLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            excludedTitlesLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),

            excludedTitlesField.topAnchor.constraint(equalTo: excludedTitlesLabel.bottomAnchor, constant: 4),
            excludedTitlesField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            excludedTitlesField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
        ])

        // Buttons
        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelAction))
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.keyEquivalent = "\u{1B}" // Escape
        container.addSubview(cancelButton)

        let saveButton = NSButton(title: "Save", target: self, action: #selector(saveAction))
        saveButton.translatesAutoresizingMaskIntoConstraints = false
        saveButton.keyEquivalent = "\r" // Enter
        saveButton.bezelColor = .controlAccentColor
        container.addSubview(saveButton)

        NSLayoutConstraint.activate([
            saveButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -20),
            saveButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),

            cancelButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -20),
            cancelButton.trailingAnchor.constraint(equalTo: saveButton.leadingAnchor, constant: -12),
        ])
    }

    private func makeCheckbox(
        title: String,
        tooltip: String,
        target: AnyObject? = nil,
        action: Selector? = nil
    ) -> NSButton {
        let checkbox = NSButton(checkboxWithTitle: title, target: target, action: action)
        checkbox.translatesAutoresizingMaskIntoConstraints = false
        checkbox.toolTip = tooltip
        checkbox.font = NSFont.systemFont(ofSize: 12)
        return checkbox
    }

    private func populateFields() {
        ignoreApplicationCheckbox.state = originalEntry.isIgnored ? .on : .off
        hasMainWindowCheckbox.state = (originalEntry.rule.hasMainWindow == true) ? .on : .off
        snapToZoneCheckbox.state = (originalEntry.rule.snapToZoneOnSelfResize == true) ? .on : .off
        doNotResizeWidthCheckbox.state = (originalEntry.rule.doNotResizeWidth == true) ? .on : .off
        disableControlCommandMouseGesturesCheckbox.state = (originalEntry.rule.disableControlCommandMouseGestures == true) ? .on : .off
        treatAXUnknownFullWidthAsFullScreenCheckbox.state = (originalEntry.rule.treatAXUnknownFullWidthAsFullScreen == true) ? .on : .off
        disallowEmptyTitleCheckbox.state = (originalEntry.rule.disallowEmptyTitleWindows == true) ? .on : .off
        ignoreActivationPolicyCheckbox.state = (originalEntry.rule.ignoreActivationPolicy == true) ? .on : .off
        ignoreZoomButtonCheckbox.state = (originalEntry.rule.ignoreZoomButtonRequirement == true) ? .on : .off
        requireActiveZoomButtonCheckbox.state = (originalEntry.rule.requireActiveZoomButton == true) ? .on : .off
        ignoreHeightCheckbox.state = (originalEntry.rule.ignoreHeightRequirement == true) ? .on : .off
        manageNonStandardWindowsCheckbox.state = (originalEntry.rule.manageNonStandardWindows == true) ? .on : .off

        if let titles = originalEntry.rule.excludedWindowTitles, !titles.isEmpty {
            excludedTitlesField.stringValue = titles.joined(separator: ", ")
        }

        updateExceptionControlsEnabledState()
    }

    @objc private func ignoreApplicationChanged() {
        updateExceptionControlsEnabledState()
    }

    private func updateExceptionControlsEnabledState() {
        let exceptionsEnabled = ignoreApplicationCheckbox.state != .on
        for control in exceptionControls {
            control.isEnabled = exceptionsEnabled
        }
        excludedTitlesLabel.textColor = exceptionsEnabled ? .labelColor : .disabledControlTextColor
    }

    @objc private func cancelAction() {
        view.window?.sheetParent?.endSheet(view.window!, returnCode: .cancel)
    }

    @objc private func saveAction() {
        // Parse excluded titles
        let excludedTitlesText = excludedTitlesField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let excludedTitles: [String]? = excludedTitlesText.isEmpty ? nil :
            excludedTitlesText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }

        // Build the updated rule - use nil for false values to keep JSON clean
        let updatedRule = ApplicationExceptionRule(
            bundleIdentifier: originalEntry.bundleIdentifier,
            ignoreActivationPolicy: ignoreActivationPolicyCheckbox.state == .on ? true : nil,
            ignoreZoomButtonRequirement: ignoreZoomButtonCheckbox.state == .on ? true : nil,
            ignoreHeightRequirement: ignoreHeightCheckbox.state == .on ? true : nil,
            disallowEmptyTitleWindows: disallowEmptyTitleCheckbox.state == .on ? true : nil,
            hasMainWindow: hasMainWindowCheckbox.state == .on ? true : nil,
            snapToZoneOnSelfResize: snapToZoneCheckbox.state == .on ? true : nil,
            doNotResizeWidth: doNotResizeWidthCheckbox.state == .on ? true : nil,
            disableControlCommandMouseGestures: disableControlCommandMouseGesturesCheckbox.state == .on ? true : nil,
            treatAXUnknownFullWidthAsFullScreen: treatAXUnknownFullWidthAsFullScreenCheckbox.state == .on ? true : nil,
            requireActiveZoomButton: requireActiveZoomButtonCheckbox.state == .on ? true : nil,
            manageNonStandardWindows: manageNonStandardWindowsCheckbox.state == .on ? true : nil,
            excludedWindowTitles: excludedTitles
        )

        onSave?(
            ExceptionsPreferencesEntry(
                rule: updatedRule,
                isIgnored: ignoreApplicationCheckbox.state == .on,
                persistsRuleWithoutMeaningfulSettings: originalEntry.persistsRuleWithoutMeaningfulSettings
            )
        )
        view.window?.sheetParent?.endSheet(view.window!, returnCode: .OK)
    }
}
