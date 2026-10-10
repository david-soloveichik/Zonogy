/// Presents experimental features, their setup requirements, and current activation status.
import AppKit

final class ExperimentalPreferencesViewController: NSViewController {
    private var instantMinimizeCheckbox: NSButton?
    private var instantMinimizeStatus: PreferenceStatusBadge?
    private var instantMinimizeStatusDetail: NSTextField?

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 580, height: 540))
        let title = NSTextField(labelWithString: "Experimental Settings")
        title.font = .systemFont(ofSize: 16, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(title)

        let checkbox = NSButton(checkboxWithTitle: "Disable minimize and restore animations",
                                target: self, action: #selector(instantMinimizeToggled(_:)))
        checkbox.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(checkbox)
        instantMinimizeCheckbox = checkbox

        let description = makeHint(
            "Applies to all applications while Zonogy is running. Turning this off or quitting Zonogy restarts Dock."
        )
        let compatibility = makeHint("Requires an Apple Silicon Mac running a compatible macOS 27 build.")
        let sipRequirement = makeHint("System Integrity Protection (SIP) must be partially disabled.")
        sipRequirement.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        sipRequirement.textColor = .labelColor
        let setup = makeHint(
            "Use the same SIP setup as yabai. Administrator approval is required to enable this feature. Expect a “Developer Tools Access” prompt after restarting your Mac."
        )
        let instructions = NSButton(title: "yabai SIP setup instructions", target: self, action: #selector(openSIPInstructions))
        instructions.isBordered = false
        instructions.alignment = .left
        instructions.attributedTitle = NSAttributedString(string: instructions.title, attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ])
        instructions.toolTip = AppLinks.yabaiSIPInstructions.absoluteString
        let status = PreferenceStatusBadge()
        instantMinimizeStatus = status
        let statusDetail = makeHint("")
        instantMinimizeStatusDetail = statusDetail

        let details = NSStackView(views: [description, compatibility, sipRequirement, setup, instructions, status, statusDetail])
        details.orientation = .vertical
        details.alignment = .leading
        details.spacing = 8
        details.setCustomSpacing(16, after: instructions)
        details.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(details)
        for label in [description, compatibility, sipRequirement, setup, statusDetail] {
            label.widthAnchor.constraint(equalTo: details.widthAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            title.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            checkbox.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 18),
            checkbox.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            details.topAnchor.constraint(equalTo: checkbox.bottomAnchor, constant: 6),
            details.leadingAnchor.constraint(equalTo: checkbox.leadingAnchor, constant: 20),
            details.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            details.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -20),
        ])
        view = container
        preferredContentSize = NSSize(width: 580, height: 540)
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

    @objc private func openSIPInstructions() {
        AppLinks.open(AppLinks.yabaiSIPInstructions)
    }

    @objc private func syncControls() {
        let controller = AppController.shared.instantMinimizeController
        instantMinimizeCheckbox?.state = controller.isEnabled ? .on : .off
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
    }
}
