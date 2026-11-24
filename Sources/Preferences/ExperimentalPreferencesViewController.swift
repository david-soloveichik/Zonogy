/// Presents experimental features, their setup requirements, and current activation status.
import AppKit

final class ExperimentalPreferencesViewController: NSViewController {
    private var instantMinimizeCheckbox: NSButton?
    private var keepAfterQuitCheckbox: NSButton?
    private var instantMinimizeStatus: PreferenceStatusBadge?
    private var instantMinimizeStatusDetail: NSTextField?

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 580, height: 540))
        let title = NSTextField(labelWithString: "Experimental Settings")
        title.font = .systemFont(ofSize: 16, weight: .semibold)

        let checkbox = NSButton(checkboxWithTitle: "Disable minimize and restore animations system-wide",
                                target: self, action: #selector(instantMinimizeToggled(_:)))
        instantMinimizeCheckbox = checkbox
        let description = makeHint("Turning animations back on restarts Dock.")
        let keepAfterQuit = NSButton(checkboxWithTitle: "Keep animations disabled after quitting (until Dock restarts)",
                                     target: self, action: #selector(keepAfterQuitToggled(_:)))
        keepAfterQuitCheckbox = keepAfterQuit
        let status = PreferenceStatusBadge()
        instantMinimizeStatus = status
        let statusDetail = makeHint("")
        instantMinimizeStatusDetail = statusDetail
        let controls = NSStackView(views: [description, keepAfterQuit, status, statusDetail])
        controls.orientation = .vertical
        controls.alignment = .leading
        controls.spacing = 8
        controls.edgeInsets.left = 20
        controls.setCustomSpacing(12, after: keepAfterQuit)

        // A section of their own, so the requirements read as covering the sub-option too.
        let requirementsTitle = NSTextField(labelWithString: "Requirements")
        requirementsTitle.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        let requirements = makeHint("")
        requirements.attributedStringValue = .bulletList([
            "An Apple Silicon Mac running a compatible macOS 27 build",
            "System Integrity Protection (SIP) partially disabled, with the same setup as yabai",
            "Administrator approval when turning this on; expect a “Developer Tools Access” prompt after restarting your Mac",
        ], font: .systemFont(ofSize: NSFont.smallSystemFontSize), color: .secondaryLabelColor)
        let instructions = NSButton(title: "yabai SIP setup instructions", target: self, action: #selector(openSIPInstructions))
        instructions.isBordered = false
        instructions.alignment = .left
        instructions.attributedTitle = NSAttributedString(string: instructions.title, attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ])
        instructions.toolTip = AppLinks.yabaiSIPInstructions.absoluteString

        let page = NSStackView(views: [title, checkbox, controls, requirementsTitle, requirements, instructions])
        page.orientation = .vertical
        page.alignment = .leading
        page.spacing = 6
        page.setCustomSpacing(18, after: title)
        page.setCustomSpacing(26, after: controls)
        page.setCustomSpacing(8, after: requirementsTitle)
        page.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(page)
        for label in [description, statusDetail, requirements] {
            label.trailingAnchor.constraint(equalTo: page.trailingAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            page.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            page.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            page.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
        ])
        view = container
        NotificationCenter.default.addObserver(self, selector: #selector(syncControls),
                                               name: .instantMinimizeStatusChanged, object: nil)
        syncControls()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        syncControls()
    }

    private func makeHint(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    @objc private func instantMinimizeToggled(_ sender: NSButton) {
        AppController.shared.setInstantMinimizeEnabledFromSettings(sender.state == .on)
        syncControls()
    }

    @objc private func keepAfterQuitToggled(_ sender: NSButton) {
        AppController.shared.setInstantMinimizeKeepAfterQuitFromSettings(sender.state == .on)
    }

    @objc private func openSIPInstructions() {
        AppLinks.open(AppLinks.yabaiSIPInstructions)
    }

    @objc private func syncControls() {
        let controller = AppController.shared.instantMinimizeController
        instantMinimizeCheckbox?.state = controller.isEnabled ? .on : .off
        keepAfterQuitCheckbox?.state = ExperimentalPreferencesStore.loadInstantMinimizeKeepAfterQuit() ? .on : .off
        keepAfterQuitCheckbox?.isEnabled = controller.isEnabled
        if controller.hasError {
            instantMinimizeStatus?.update(title: "Needs attention", symbol: "exclamationmark.triangle.fill", color: .systemRed)
        } else if controller.isActive {
            instantMinimizeStatus?.update(title: "Active", symbol: "checkmark.circle.fill", color: .systemGreen)
        } else if controller.isEnabled {
            instantMinimizeStatus?.update(title: "Enabling", symbol: "hourglass", color: .controlAccentColor)
        } else {
            instantMinimizeStatus?.update(title: "Off", symbol: "circle", color: .secondaryLabelColor)
        }
        instantMinimizeStatusDetail?.stringValue = controller.status
        instantMinimizeStatusDetail?.isHidden = !controller.hasError && (!controller.isEnabled || controller.isActive)
        instantMinimizeStatusDetail?.textColor = controller.hasError ? .labelColor : .secondaryLabelColor
        // The status detail comes and goes with the feature's state.
        fitPreferredContentSizeToContent()
    }
}
