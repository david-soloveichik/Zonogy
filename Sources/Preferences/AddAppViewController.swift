/// View controller for adding an exception: the user selects a running app, which fills in its bundle
/// identifier, or types a bundle identifier (or pattern) directly.

import AppKit

final class AddAppViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {

    /// Bundle IDs that already have exceptions (to exclude from list)
    var existingBundleIds: Set<String> = []

    /// Called with the bundle identifier to add
    var onAdd: ((String) -> Void)?

    private var explanationLabel: NSTextField!
    private var tableView: NSTableView!
    private var scrollView: NSScrollView!
    private var bundleIdField: NSTextField!
    private var addButton: NSButton!
    private var runningApps: [(bundleId: String, name: String, icon: NSImage)] = []

    override func loadView() {
        let containerView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 390))

        setupExplanationLabel(in: containerView)
        let bundleIdRow = setupBundleIdRow(in: containerView)
        setupTableView(in: containerView, above: bundleIdRow)
        setupButtons(in: containerView)

        self.view = containerView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        loadRunningApps()
    }

    private func setupExplanationLabel(in container: NSView) {
        explanationLabel = NSTextField(wrappingLabelWithString:
            "Select a running app to add an exception for, or type a bundle identifier. Only apps eligible for Zonogy management are listed.")
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

    /// The bundle identifier to add: filled in by selecting an app, or typed.
    private func setupBundleIdRow(in container: NSView) -> NSView {
        let label = NSTextField(labelWithString: "Bundle Identifier:")
        label.font = NSFont.systemFont(ofSize: 12)

        bundleIdField = NSTextField()
        bundleIdField.font = NSFont.systemFont(ofSize: 12)
        bundleIdField.placeholderString = "e.g., com.adobe.PremierePro*"
        bundleIdField.delegate = self

        let row = NSStackView(views: [label, bundleIdField])
        row.translatesAutoresizingMaskIntoConstraints = false
        row.alignment = .firstBaseline
        row.distribution = .fill
        row.spacing = 8
        container.addSubview(row)

        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            row.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            row.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -60),
        ])
        return row
    }

    private func setupTableView(in container: NSView, above bundleIdRow: NSView) {
        scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        tableView = NSTableView()
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = 28
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = false
        tableView.target = self
        tableView.doubleAction = #selector(tableViewDoubleClicked)

        // App name column
        let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        nameColumn.title = "Application"
        nameColumn.width = 180
        nameColumn.minWidth = 100
        tableView.addTableColumn(nameColumn)

        // Bundle ID column
        let bundleColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("bundleId"))
        bundleColumn.title = "Bundle Identifier"
        bundleColumn.width = 180
        bundleColumn.minWidth = 100
        tableView.addTableColumn(bundleColumn)

        scrollView.documentView = tableView
        container.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: explanationLabel.bottomAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            scrollView.bottomAnchor.constraint(equalTo: bundleIdRow.topAnchor, constant: -12),
        ])
    }

    private func setupButtons(in container: NSView) {
        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelAction))
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.keyEquivalent = "\u{1B}" // Escape
        container.addSubview(cancelButton)

        addButton = NSButton(title: "Add", target: self, action: #selector(addAction))
        addButton.translatesAutoresizingMaskIntoConstraints = false
        addButton.keyEquivalent = "\r" // Enter
        addButton.bezelColor = .controlAccentColor
        addButton.isEnabled = false
        container.addSubview(addButton)

        NSLayoutConstraint.activate([
            addButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -20),
            addButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),

            cancelButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -20),
            cancelButton.trailingAnchor.constraint(equalTo: addButton.leadingAnchor, constant: -12),
        ])
    }

    private func loadRunningApps() {
        runningApps = []

        // Get all running apps with .regular activation policy (standard GUI apps)
        let workspace = NSWorkspace.shared
        for app in workspace.runningApplications {
            guard app.activationPolicy == .regular,
                  let bundleId = app.bundleIdentifier,
                  !existingBundleIds.contains(bundleId),
                  bundleId != Bundle.main.bundleIdentifier else {
                continue
            }

            let name = app.localizedName ?? bundleId
            let icon = app.icon ?? NSImage(systemSymbolName: "app", accessibilityDescription: "App") ?? NSImage()
            icon.size = NSSize(width: 16, height: 16)

            runningApps.append((bundleId: bundleId, name: name, icon: icon))
        }

        // Sort by app name
        runningApps.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        tableView.reloadData()
    }

    @objc private func cancelAction() {
        view.window?.sheetParent?.endSheet(view.window!, returnCode: .cancel)
    }

    private var enteredBundleIdentifier: String {
        bundleIdField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @objc private func addAction() {
        let bundleId = enteredBundleIdentifier
        guard !bundleId.isEmpty else { return }

        onAdd?(bundleId)
        view.window?.sheetParent?.endSheet(view.window!, returnCode: .OK)
    }

    /// Double-clicking an app adds it right away, even if its bundle identifier was edited meanwhile.
    @objc private func tableViewDoubleClicked() {
        let row = tableView.clickedRow
        guard row >= 0 else { return }
        bundleIdField.stringValue = runningApps[row].bundleId
        addAction()
    }

    func controlTextDidChange(_ obj: Notification) {
        addButton.isEnabled = !enteredBundleIdentifier.isEmpty
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let selectedRow = tableView.selectedRow
        guard selectedRow >= 0 else { return }
        bundleIdField.stringValue = runningApps[selectedRow].bundleId
        addButton.isEnabled = true
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        runningApps.count
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let app = runningApps[row]

        switch tableColumn?.identifier.rawValue {
        case "name":
            return makeNameCell(name: app.name, icon: app.icon)
        case "bundleId":
            return makeBundleIdCell(bundleId: app.bundleId)
        default:
            return nil
        }
    }

    private func makeNameCell(name: String, icon: NSImage) -> NSView {
        let cell = NSTableCellView()

        let imageView = NSImageView(image: icon)
        imageView.translatesAutoresizingMaskIntoConstraints = false

        let textField = NSTextField(labelWithString: name)
        textField.font = NSFont.systemFont(ofSize: 12)
        textField.lineBreakMode = .byTruncatingTail
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

    private func makeBundleIdCell(bundleId: String) -> NSView {
        let cell = NSTableCellView()

        let textField = NSTextField(labelWithString: bundleId)
        textField.font = NSFont.systemFont(ofSize: 11)
        textField.textColor = .secondaryLabelColor
        textField.lineBreakMode = .byTruncatingMiddle
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
}
