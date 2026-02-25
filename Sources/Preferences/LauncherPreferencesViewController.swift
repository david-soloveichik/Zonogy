/// View controller for the Launcher preferences tab - manages custom files/folders and aliases
import AppKit

final class LauncherPreferencesViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {

    private var tableView: NSTableView!
    private var scrollView: NSScrollView!
    private var addButton: NSButton!
    private var removeButton: NSButton!
    private var explanationLabel: NSTextField!

    private var items: [LauncherConfigurationItem] = []

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
        explanationLabel = NSTextField(wrappingLabelWithString:
            "The Launcher automatically includes apps from /Applications, /System/Applications, and ~/Applications. Use the list below to add additional items.")
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

        // Path column
        let pathColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("path"))
        pathColumn.title = "Path"
        pathColumn.width = 300
        pathColumn.minWidth = 200
        tableView.addTableColumn(pathColumn)

        // Alias column
        let aliasColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("alias"))
        aliasColumn.title = "Alias"
        aliasColumn.width = 150
        aliasColumn.minWidth = 80
        tableView.addTableColumn(aliasColumn)

        scrollView.documentView = tableView
        container.addSubview(scrollView)

        // Register for drag-and-drop
        tableView.registerForDraggedTypes([.fileURL])
        tableView.setDraggingSourceOperationMask(.copy, forLocal: false)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: explanationLabel.bottomAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -70),
        ])
    }

    private func setupButtons(in container: NSView) {
        // Add button
        addButton = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: "Add")!, target: self, action: #selector(addItem))
        addButton.translatesAutoresizingMaskIntoConstraints = false
        addButton.bezelStyle = .rounded
        addButton.toolTip = "Add file or folder"
        container.addSubview(addButton)

        // Remove button
        removeButton = NSButton(image: NSImage(systemSymbolName: "minus", accessibilityDescription: "Remove")!, target: self, action: #selector(removeSelectedItems))
        removeButton.translatesAutoresizingMaskIntoConstraints = false
        removeButton.bezelStyle = .rounded
        removeButton.toolTip = "Remove selected items"
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
        let hint = NSTextField(labelWithString: "Drag files or folders to the table to add them")
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
        let config = LauncherConfigurationStore.loadConfiguration()
        items = config.items
        tableView.reloadData()
    }

    private func saveConfiguration() {
        let config = LauncherConfiguration(items: items)
        LauncherConfigurationStore.saveConfiguration(config)
        Task {
            await LauncherAppCache.shared.reload()
        }
    }

    // MARK: - Actions

    @objc private func addItem() {
        guard let window = view.window else { return }

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = "Select files or folders to add to the Launcher"

        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self = self else { return }

            for url in panel.urls {
                let path = self.abbreviatePath(url.path)
                if !self.items.contains(where: { $0.path == path }) {
                    self.items.append(LauncherConfigurationItem(path: path, alias: nil))
                }
            }

            self.tableView.reloadData()
            self.saveConfiguration()
        }
    }

    @objc private func removeSelectedItems() {
        let selectedRows = tableView.selectedRowIndexes
        guard !selectedRows.isEmpty else { return }

        // Remove in reverse order to maintain indices
        for index in selectedRows.reversed() {
            items.remove(at: index)
        }

        tableView.reloadData()
        saveConfiguration()
    }

    @objc private func openConfigFile() {
        let configURL = LauncherConfigurationStore.configurationFileURL()
        NSWorkspace.shared.activateFileViewerSelecting([configURL])
        view.window?.close()
    }

    private func abbreviatePath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    private func expandPath(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        items.count
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = items[row]

        switch tableColumn?.identifier.rawValue {
        case "path":
            return makePathCell(for: item, row: row)
        case "alias":
            return makeAliasCell(for: item, row: row)
        default:
            return nil
        }
    }

    private func makePathCell(for item: LauncherConfigurationItem, row: Int) -> NSView {
        let cell = NSTableCellView()

        let expandedPath = expandPath(item.path)
        let icon = NSWorkspace.shared.icon(forFile: expandedPath)
        icon.size = NSSize(width: 16, height: 16)

        let imageView = NSImageView(image: icon)
        imageView.translatesAutoresizingMaskIntoConstraints = false

        let textField = NSTextField(labelWithString: item.path)
        textField.font = NSFont.systemFont(ofSize: 12)
        textField.lineBreakMode = .byTruncatingMiddle
        textField.translatesAutoresizingMaskIntoConstraints = false

        // Check if path exists
        let exists = FileManager.default.fileExists(atPath: expandedPath)
        textField.textColor = exists ? .labelColor : .systemRed

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

    private func makeAliasCell(for item: LauncherConfigurationItem, row: Int) -> NSView {
        let cell = NSTableCellView()

        let textField = EditableAliasTextField()
        textField.stringValue = item.alias ?? ""
        textField.placeholderString = "Optional alias"
        textField.font = NSFont.systemFont(ofSize: 12)
        textField.isBordered = false
        textField.backgroundColor = .clear
        textField.focusRingType = .none
        textField.isEditable = true
        textField.row = row
        textField.delegate = self
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

    // MARK: - Drag and Drop

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        // Highlight entire table (row -1) since position doesn't matter
        tableView.setDropRow(-1, dropOperation: .on)
        return .copy
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] else {
            return false
        }

        var added = false
        for url in urls {
            let path = abbreviatePath(url.path)
            if !items.contains(where: { $0.path == path }) {
                items.append(LauncherConfigurationItem(path: path, alias: nil))
                added = true
            }
        }

        if added {
            tableView.reloadData()
            saveConfiguration()
        }

        return added
    }
}

// MARK: - NSTextFieldDelegate for alias editing

extension LauncherPreferencesViewController: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ obj: Notification) {
        guard let textField = obj.object as? EditableAliasTextField else { return }
        let row = textField.row
        guard row >= 0, row < items.count else { return }

        let newAlias = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        items[row].alias = newAlias.isEmpty ? nil : newAlias
        saveConfiguration()
    }
}

// MARK: - Helper Classes

private class EditableAliasTextField: NSTextField {
    var row: Int = -1
}
