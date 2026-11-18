/// View controller for editing a single app's exception rules. Each exception's title ends with the
/// gray short name that stands for it in the Exceptions table.

import AppKit

final class ExceptionRuleEditViewController: NSViewController {

    private let originalEntry: ExceptionsPreferencesEntry
    var onSave: ((ExceptionsPreferencesEntry) -> Void)?

    private var ignoreApplicationCheckbox: NSButton!
    private var optionCheckboxes: [(option: ExceptionOption, checkbox: NSButton)] = []
    private var excludedTitlesLabel: NSTextField!
    private var excludedTitlesField: NSTextField!

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
            iconView.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            iconView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            iconView.widthAnchor.constraint(equalToConstant: 32),
            iconView.heightAnchor.constraint(equalToConstant: 32),

            bundleIdLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            bundleIdLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 12),

            bundleIdValue.topAnchor.constraint(equalTo: bundleIdLabel.bottomAnchor, constant: 2),
            bundleIdValue.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 12),
            bundleIdValue.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
        ])

        // Everything below the icon stacks in full-width rows
        var previousBottom = iconView.bottomAnchor
        func addRow(_ row: NSView, spacing: CGFloat) {
            row.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(row)
            NSLayoutConstraint.activate([
                row.topAnchor.constraint(equalTo: previousBottom, constant: spacing),
                row.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
                row.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            ])
            previousBottom = row.bottomAnchor
        }

        let separator = NSBox()
        separator.boxType = .separator
        addRow(separator, spacing: 12)

        // Hint: every checkbox's tooltip explains it in full
        let hoverHintLabel = NSTextField(labelWithString: "Hover over an exception for more information.")
        hoverHintLabel.font = NSFont.systemFont(ofSize: 11)
        hoverHintLabel.textColor = .secondaryLabelColor
        addRow(hoverHintLabel, spacing: 12)

        ignoreApplicationCheckbox = makeCheckbox(
            title: "Ignore this application altogether",
            shortName: ExceptionOption.ignoredShortName,
            tooltip: "Windows from this app are never captured or managed by Zonogy",
            action: #selector(ignoreApplicationChanged)
        )
        addRow(ignoreApplicationCheckbox, spacing: 12)

        optionCheckboxes = ExceptionOption.all.map { option in
            (option, makeCheckbox(title: option.title, shortName: option.shortName, tooltip: option.tooltip))
        }
        for (index, item) in optionCheckboxes.enumerated() {
            addRow(item.checkbox, spacing: index == 0 ? 12 : 8)
        }

        // Excluded window titles; updateExceptionControlsEnabledState() sets the label's text
        excludedTitlesLabel = NSTextField(labelWithString: "")
        addRow(excludedTitlesLabel, spacing: 16)

        excludedTitlesField = NSTextField()
        excludedTitlesField.placeholderString = "e.g., Preferences, Settings"
        excludedTitlesField.font = NSFont.systemFont(ofSize: 12)
        addRow(excludedTitlesField, spacing: 4)

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

    private func makeCheckbox(title: String, shortName: String, tooltip: String, action: Selector? = nil) -> NSButton {
        let checkbox = NSButton(checkboxWithTitle: title, target: self, action: action)
        checkbox.attributedTitle = Self.titleWithShortName(title, shortName)
        checkbox.toolTip = tooltip
        return checkbox
    }

    /// `title` followed by the gray `(shortName)` the Exceptions table shows for it. A disabled checkbox
    /// dims its whole title by itself; a label doesn't, so a disabled label passes `enabled: false`.
    private static func titleWithShortName(_ title: String, _ shortName: String, enabled: Bool = true) -> NSAttributedString {
        let text = NSMutableAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: enabled ? NSColor.labelColor : .disabledControlTextColor,
        ])
        text.append(NSAttributedString(string: " (\(shortName))", attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: enabled ? NSColor.secondaryLabelColor : .disabledControlTextColor,
        ]))
        return text
    }

    private func populateFields() {
        ignoreApplicationCheckbox.state = originalEntry.isIgnored ? .on : .off
        for (option, checkbox) in optionCheckboxes {
            checkbox.state = originalEntry.rule[keyPath: option.setting] == true ? .on : .off
        }

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
        for (_, checkbox) in optionCheckboxes {
            checkbox.isEnabled = exceptionsEnabled
        }
        excludedTitlesField.isEnabled = exceptionsEnabled
        excludedTitlesLabel.attributedStringValue = Self.titleWithShortName(
            "Excluded window titles, comma-separated",
            "\(ExceptionOption.excludedTitlesShortName):N",
            enabled: exceptionsEnabled
        )
    }

    @objc private func cancelAction() {
        view.window?.sheetParent?.endSheet(view.window!, returnCode: .cancel)
    }

    @objc private func saveAction() {
        // Unchecked settings are stored as nil to keep the JSON clean
        var updatedRule = originalEntry.rule
        for (option, checkbox) in optionCheckboxes {
            updatedRule[keyPath: option.setting] = checkbox.state == .on ? true : nil
        }

        let excludedTitlesText = excludedTitlesField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        updatedRule.excludedWindowTitles = excludedTitlesText.isEmpty ? nil :
            excludedTitlesText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }

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
