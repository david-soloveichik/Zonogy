/// View controller for selecting a running app to add an exception for

import AppKit

final class AddAppViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {

    /// Bundle IDs that already have exceptions (to exclude from list)
    var existingBundleIds: Set<String> = []

    /// Called when user selects an app
    var onAppSelected: ((String) -> Void)?

    private var tableView: NSTableView!
    private var scrollView: NSScrollView!
    private var runningApps: [(bundleId: String, name: String, icon: NSImage)] = []

    override func loadView() {
        let containerView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 350))

        setupExplanationLabel(in: containerView)
        setupTableView(in: containerView)
        setupButtons(in: containerView)

        self.view = containerView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        loadRunningApps()
    }

    private func setupExplanationLabel(in container: NSView) {
        let label = NSTextField(wrappingLabelWithString:
            "Select a running app to add an exception for. Only apps eligible for Zonogy management are shown.")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = NSFont.systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        container.addSubview(label)

        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
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
        tableView.allowsMultipleSelection = false
        tableView.target = self
        tableView.doubleAction = #selector(selectApp)

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

        // Get the explanation label's bottom anchor
        guard let explanationLabel = container.subviews.first as? NSTextField else { return }

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: explanationLabel.bottomAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -60),
        ])
    }

    private func setupButtons(in container: NSView) {
        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelAction))
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.keyEquivalent = "\u{1B}" // Escape
        container.addSubview(cancelButton)

        let selectButton = NSButton(title: "Add", target: self, action: #selector(selectApp))
        selectButton.translatesAutoresizingMaskIntoConstraints = false
        selectButton.keyEquivalent = "\r" // Enter
        selectButton.bezelColor = .controlAccentColor
        container.addSubview(selectButton)

        NSLayoutConstraint.activate([
            selectButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -20),
            selectButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),

            cancelButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -20),
            cancelButton.trailingAnchor.constraint(equalTo: selectButton.leadingAnchor, constant: -12),
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

    @objc private func selectApp() {
        let selectedRow = tableView.selectedRow
        guard selectedRow >= 0, selectedRow < runningApps.count else { return }

        let bundleId = runningApps[selectedRow].bundleId
        onAppSelected?(bundleId)
        view.window?.sheetParent?.endSheet(view.window!, returnCode: .OK)
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
