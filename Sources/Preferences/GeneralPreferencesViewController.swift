/// View controller for the General preferences tab
import AppKit

final class GeneralPreferencesViewController: NSViewController {

    override func loadView() {
        let containerView = NSView(frame: NSRect(x: 0, y: 0, width: 450, height: 300))

        // Title label
        let titleLabel = NSTextField(labelWithString: "General Settings")
        titleLabel.font = NSFont.systemFont(ofSize: 16, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(titleLabel)

        // Placeholder message for future settings
        let placeholderLabel = NSTextField(wrappingLabelWithString: "General preferences will be available in a future update.\n\nFor now, you can configure keyboard shortcuts in the Keyboard Shortcuts tab.")
        placeholderLabel.font = NSFont.systemFont(ofSize: 13)
        placeholderLabel.textColor = .secondaryLabelColor
        placeholderLabel.alignment = .center
        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(placeholderLabel)

        // Version info
        let versionLabel = NSTextField(labelWithString: "Zonogy Window Manager")
        versionLabel.font = NSFont.systemFont(ofSize: 11)
        versionLabel.textColor = .tertiaryLabelColor
        versionLabel.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(versionLabel)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 30),
            titleLabel.centerXAnchor.constraint(equalTo: containerView.centerXAnchor),

            placeholderLabel.centerXAnchor.constraint(equalTo: containerView.centerXAnchor),
            placeholderLabel.centerYAnchor.constraint(equalTo: containerView.centerYAnchor),
            placeholderLabel.leadingAnchor.constraint(greaterThanOrEqualTo: containerView.leadingAnchor, constant: 40),
            placeholderLabel.trailingAnchor.constraint(lessThanOrEqualTo: containerView.trailingAnchor, constant: -40),

            versionLabel.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -20),
            versionLabel.centerXAnchor.constraint(equalTo: containerView.centerXAnchor),
        ])

        self.view = containerView
    }
}
