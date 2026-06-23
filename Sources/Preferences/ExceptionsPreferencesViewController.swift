/// View controller for the Exceptions preferences tab - manages per-app exceptions and ignored apps.

import AppKit

final class ExceptionsPreferencesViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {

    private var tableView: NSTableView!
    private var scrollView: NSScrollView!
    private var addButton: NSButton!
    private var removeButton: NSButton!
    private var explanationLabel: NSTextField!

    /// Exception entries loaded from config.json
    private var entries: [ExceptionsPreferencesEntry] = []

    override func loadView() {
        let containerView = NSView(frame: NSRect(x: 0, y: 0, width: 580, height: 400))

        setupExplanationLabel(in: containerView)
        setupTableView(in: containerView)
        setupButtons(in: containerView)
        setupHintLabel(in: containerView)

        self.view = containerView
        self.preferredContentSize = NSSize(width: 580, height: 525)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        loadConfiguration()
    }

    // MARK: - Setup

    private func setupExplanationLabel(in container: NSView) {
        let explanationText = """
        Zonogy manages windows that have: a standard window role, a zoom button, \
        height ≥ 250px, and are movable. Use this list to create exceptions for \
        specific apps that need different management, different mouse-gesture \
        behavior, or should be ignored entirely.
        """
        explanationLabel = NSTextField(wrappingLabelWithString: explanationText)
        explanationLabel.translatesAutoresizingMaskIntoConstraints = false
        explanationLabel.font = NSFont.systemFont(ofSize: 11)
        explanationLabel.textColor = .secondaryLabelColor
        container.addSubview(explanationLabel)

        NSLayoutConstraint.activate([
            explanationLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            explanationLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            explanationLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
        ])
    }

    private func setupTableView(in container: NSView) {
        scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        tableView = NSTableView()
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = 28
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true

        // Bundle ID column
        let bundleColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("bundleId"))
        bundleColumn.title = "Bundle Identifier"
        bundleColumn.width = 280
        bundleColumn.minWidth = 150
        tableView.addTableColumn(bundleColumn)

        // Exceptions summary column
        let exceptionsColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("exceptions"))
        exceptionsColumn.title = "Exceptions"
        exceptionsColumn.width = 160
        exceptionsColumn.minWidth = 80
        tableView.addTableColumn(exceptionsColumn)

        scrollView.documentView = tableView
        container.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: explanationLabel.bottomAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -70),
        ])
    }

    private func setupButtons(in container: NSView) {
        // Add button
        addButton = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: "Add")!, target: self, action: #selector(addException))
        addButton.translatesAutoresizingMaskIntoConstraints = false
        addButton.bezelStyle = .rounded
        addButton.toolTip = "Add exception for an app"
        container.addSubview(addButton)

        // Remove button
        removeButton = NSButton(image: NSImage(systemSymbolName: "minus", accessibilityDescription: "Remove")!, target: self, action: #selector(removeSelectedExceptions))
        removeButton.translatesAutoresizingMaskIntoConstraints = false
        removeButton.bezelStyle = .rounded
        removeButton.toolTip = "Remove selected exceptions"
        container.addSubview(removeButton)

        // Reveal config file button
        let openConfigButton = NSButton(image: NSImage(systemSymbolName: "doc.text", accessibilityDescription: "Reveal Config File")!, target: self, action: #selector(openConfigFile))
        openConfigButton.translatesAutoresizingMaskIntoConstraints = false
        openConfigButton.bezelStyle = .rounded
        openConfigButton.toolTip = "Reveal configuration file in Finder"
        container.addSubview(openConfigButton)

        NSLayoutConstraint.activate([
            addButton.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            addButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -20),

            removeButton.leadingAnchor.constraint(equalTo: addButton.trailingAnchor, constant: 8),
            removeButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -20),

            openConfigButton.leadingAnchor.constraint(equalTo: removeButton.trailingAnchor, constant: 8),
            openConfigButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -20),
        ])
    }

    private func setupHintLabel(in container: NSView) {
        let hint = NSTextField(labelWithString: "Double-click an app to edit its exceptions")
        hint.translatesAutoresizingMaskIntoConstraints = false
        hint.font = NSFont.systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        container.addSubview(hint)

        NSLayoutConstraint.activate([
            hint.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            hint.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -24),
        ])
    }

    // MARK: - Data Management

    private func loadConfiguration() {
        entries = ExceptionsConfigurationStore.loadEntries()
        tableView.reloadData()
    }

    private func saveConfiguration() {
        ExceptionsConfigurationStore.saveEntries(entries)
    }

    private func pruneTransientEntries() {
        entries.removeAll { !$0.isIgnored && $0.persistedRule == nil }
    }

    // MARK: - Actions

    @objc private func addException() {
        guard let window = view.window else { return }

        let addAppVC = AddAppViewController()
        addAppVC.existingBundleIds = Set(entries.map { $0.bundleIdentifier })
        addAppVC.onAppSelected = { [weak self] bundleId in
            guard let self = self else { return }

            let newEntry = ExceptionsPreferencesEntry(
                rule: ApplicationExceptionRule(bundleIdentifier: bundleId)
            )
            self.entries.append(newEntry)
            self.entries = ExceptionsPreferencesEntry.sortedForDisplay(self.entries)
            self.tableView.reloadData()
            self.saveConfiguration()

            // Select the new row and open edit dialog
            if let index = self.entries.firstIndex(where: { $0.bundleIdentifier == bundleId }) {
                self.tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
                self.editException(at: index)
            }
        }

        let sheet = NSWindow(contentViewController: addAppVC)
        sheet.styleMask = [.titled, .closable, .resizable]
        sheet.title = "Add App Exception"
        sheet.setContentSize(NSSize(width: 400, height: 350))

        window.beginSheet(sheet) { _ in }
    }

    @objc private func removeSelectedExceptions() {
        let selectedRows = tableView.selectedRowIndexes
        guard !selectedRows.isEmpty else { return }

        // Remove in reverse order to maintain indices
        for index in selectedRows.reversed() {
            entries.remove(at: index)
        }

        tableView.reloadData()
        saveConfiguration()
    }

    @objc private func openConfigFile() {
        // Ensure config.json exists (seeded from defaults if needed)
        ExceptionsConfigurationStore.ensureConfigExists()

        let configURL = ExceptionsConfigurationStore.configurationFileURL()
        NSWorkspace.shared.activateFileViewerSelecting([configURL])
        view.window?.close()
    }

    private func editException(at row: Int) {
        guard row >= 0, row < entries.count, let window = view.window else { return }

        let entry = entries[row]
        let editVC = ExceptionRuleEditViewController(entry: entry)
        editVC.onSave = { [weak self] updatedEntry in
            guard let self = self else { return }
            self.entries[row] = updatedEntry
            self.pruneTransientEntries()
            self.tableView.reloadData()
            self.saveConfiguration()
        }

        let sheet = NSWindow(contentViewController: editVC)
        sheet.styleMask = [.titled, .closable]
        sheet.title = "Edit Exception: \(entry.bundleIdentifier)"
        sheet.setContentSize(NSSize(width: 450, height: 490))

        window.beginSheet(sheet) { _ in }
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        entries.count
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = entries[row]

        switch tableColumn?.identifier.rawValue {
        case "bundleId":
            return makeBundleIdCell(for: entry)
        case "exceptions":
            return makeExceptionsCell(for: entry)
        default:
            return nil
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        true
    }

    func tableViewDoubleClick(_ notification: Notification) {
        // Handle double-click by tableView action
    }

    private func makeBundleIdCell(for entry: ExceptionsPreferencesEntry) -> NSView {
        let cell = NSTableCellView()

        // Get app icon if available
        let icon: NSImage
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: entry.bundleIdentifier) {
            icon = NSWorkspace.shared.icon(forFile: appURL.path)
        } else {
            icon = NSImage(systemSymbolName: "app", accessibilityDescription: "App") ?? NSImage()
        }
        icon.size = NSSize(width: 16, height: 16)

        let imageView = NSImageView(image: icon)
        imageView.translatesAutoresizingMaskIntoConstraints = false

        let textField = NSTextField(labelWithString: entry.bundleIdentifier)
        textField.font = NSFont.systemFont(ofSize: 12)
        textField.lineBreakMode = .byTruncatingMiddle
        textField.translatesAutoresizingMaskIntoConstraints = false

        cell.addSubview(imageView)
        cell.addSubview(textField)
        cell.imageView = imageView
        cell.textField = textField

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 16),
            imageView.heightAnchor.constraint(equalToConstant: 16),

            textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 6),
            textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])

        return cell
    }

    private func makeExceptionsCell(for entry: ExceptionsPreferencesEntry) -> NSView {
        let cell = NSTableCellView()

        let textField = NSTextField(labelWithString: entry.summary)
        textField.font = NSFont.systemFont(ofSize: 11)
        textField.textColor = .secondaryLabelColor
        textField.lineBreakMode = .byTruncatingTail
        textField.translatesAutoresizingMaskIntoConstraints = false

        cell.addSubview(textField)
        cell.textField = textField

        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])

        return cell
    }
    // Handle double-click
    override func viewDidAppear() {
        super.viewDidAppear()
        tableView.target = self
        tableView.doubleAction = #selector(tableViewDoubleClicked)
    }

    @objc private func tableViewDoubleClicked() {
        let row = tableView.clickedRow
        guard row >= 0 else { return }
        editException(at: row)
    }
}
