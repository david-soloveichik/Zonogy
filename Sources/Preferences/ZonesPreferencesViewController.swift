/// View controller for the Zones preferences tab
import AppKit

final class ZonesPreferencesViewController: NSViewController {

    private var autoShowLauncherCheckbox: NSButton?
    private var stickyResizeCheckbox: NSButton?
    private var zoneLayoutOptionViews: [ZoneLayoutStyleOptionView] = []

    override func loadView() {
        let containerView = NSView(frame: NSRect(x: 0, y: 0, width: 580, height: 420))

        // Zone layout picker
        let zoneLayoutTitleLabel = NSTextField(labelWithString: "Zone Layout")
        zoneLayoutTitleLabel.font = NSFont.systemFont(ofSize: 16, weight: .semibold)
        zoneLayoutTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(zoneLayoutTitleLabel)

        let zoneLayoutOptions: [(ZoneLayoutStyle, String)] = [
            (.rightBar, "Add bar on right"),
            (.leftBar, "Add bar on left"),
            (.dualBar, "Add bars on both sides")
        ]
        let optionsStack = NSStackView()
        optionsStack.orientation = .horizontal
        optionsStack.spacing = 16
        optionsStack.alignment = .top
        optionsStack.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(optionsStack)

        zoneLayoutOptionViews = []
        for (style, caption) in zoneLayoutOptions {
            let optionView = ZoneLayoutStyleOptionView(style: style)
            optionView.onSelect = { [weak self] selectedStyle in
                self?.zoneLayoutStyleSelected(selectedStyle)
            }
            optionView.setAccessibilityLabel(caption)
            zoneLayoutOptionViews.append(optionView)

            let captionLabel = NSTextField(labelWithString: caption)
            captionLabel.font = NSFont.systemFont(ofSize: 11)
            captionLabel.textColor = .secondaryLabelColor
            captionLabel.alignment = .center

            let optionStack = NSStackView(views: [optionView, captionLabel])
            optionStack.orientation = .vertical
            optionStack.spacing = 5
            optionStack.alignment = .centerX
            optionsStack.addArrangedSubview(optionStack)
        }

        let zoneLayoutHintLabel = NSTextField(
            wrappingLabelWithString: "Clicking an add-zone bar creates a new zone on that side of the screen. Single-bar layouts tile up to 3 zones; bars on both sides allow up to 4."
        )
        zoneLayoutHintLabel.font = NSFont.systemFont(ofSize: 12)
        zoneLayoutHintLabel.textColor = .secondaryLabelColor
        zoneLayoutHintLabel.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(zoneLayoutHintLabel)

        let zoneLayoutSeparator = NSBox()
        zoneLayoutSeparator.boxType = .separator
        zoneLayoutSeparator.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(zoneLayoutSeparator)

        let autoShowLauncherCheckbox = NSButton(checkboxWithTitle: "Automatically show Launcher for empty tiling zones", target: self, action: #selector(autoShowLauncherToggled(_:)))
        autoShowLauncherCheckbox.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(autoShowLauncherCheckbox)
        self.autoShowLauncherCheckbox = autoShowLauncherCheckbox

        let autoShowLauncherHintLabel = NSTextField(wrappingLabelWithString: "When a tiling zone becomes empty, Launcher opens automatically.")
        autoShowLauncherHintLabel.font = NSFont.systemFont(ofSize: 12)
        autoShowLauncherHintLabel.textColor = .secondaryLabelColor
        autoShowLauncherHintLabel.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(autoShowLauncherHintLabel)

        let stickyResizeCheckbox = NSButton(
            checkboxWithTitle: "Sticky Resize for tiled windows",
            target: self,
            action: #selector(stickyResizeToggled(_:))
        )
        stickyResizeCheckbox.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(stickyResizeCheckbox)
        self.stickyResizeCheckbox = stickyResizeCheckbox

        let stickyResizeHintLabel = NSTextField(
            wrappingLabelWithString: "Manually resized tiled windows return to the zone frame when inactive, then restore their remembered size when reactivated until that screen's tiling geometry changes."
        )
        stickyResizeHintLabel.font = NSFont.systemFont(ofSize: 12)
        stickyResizeHintLabel.textColor = .secondaryLabelColor
        stickyResizeHintLabel.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(stickyResizeHintLabel)

        NSLayoutConstraint.activate([
            zoneLayoutTitleLabel.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 20),
            zoneLayoutTitleLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),

            optionsStack.topAnchor.constraint(equalTo: zoneLayoutTitleLabel.bottomAnchor, constant: 12),
            optionsStack.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),

            zoneLayoutHintLabel.topAnchor.constraint(equalTo: optionsStack.bottomAnchor, constant: 8),
            zoneLayoutHintLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),
            zoneLayoutHintLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -20),

            zoneLayoutSeparator.topAnchor.constraint(equalTo: zoneLayoutHintLabel.bottomAnchor, constant: 20),
            zoneLayoutSeparator.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),
            zoneLayoutSeparator.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -20),

            autoShowLauncherCheckbox.topAnchor.constraint(equalTo: zoneLayoutSeparator.bottomAnchor, constant: 14),
            autoShowLauncherCheckbox.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),

            autoShowLauncherHintLabel.topAnchor.constraint(equalTo: autoShowLauncherCheckbox.bottomAnchor, constant: 6),
            autoShowLauncherHintLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 40),
            autoShowLauncherHintLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -20),

            stickyResizeCheckbox.topAnchor.constraint(equalTo: autoShowLauncherHintLabel.bottomAnchor, constant: 18),
            stickyResizeCheckbox.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),

            stickyResizeHintLabel.topAnchor.constraint(equalTo: stickyResizeCheckbox.bottomAnchor, constant: 6),
            stickyResizeHintLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 40),
            stickyResizeHintLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -20),
        ])

        self.view = containerView
        self.preferredContentSize = NSSize(width: 580, height: 420)
        syncAutoShowLauncherCheckbox()
        syncStickyResizeCheckbox()
        syncZoneLayoutSelection()
    }

    private func zoneLayoutStyleSelected(_ style: ZoneLayoutStyle) {
        AppController.shared.setZoneLayoutStyleFromSettings(style)
        syncZoneLayoutSelection()
    }

    private func syncZoneLayoutSelection() {
        let current = AppController.shared.zoneLayoutStyleInSettings
        for optionView in zoneLayoutOptionViews {
            optionView.isSelected = (optionView.style == current)
        }
    }

    @objc private func autoShowLauncherToggled(_ sender: NSButton) {
        let enabled = sender.state == .on
        AppController.shared.setAutoShowLauncherForEmptyTilingZonesEnabledFromSettings(enabled)
        syncAutoShowLauncherCheckbox()
    }

    private func syncAutoShowLauncherCheckbox() {
        let enabled = AppController.shared.isAutoShowLauncherForEmptyTilingZonesEnabledInSettings
        autoShowLauncherCheckbox?.state = enabled ? .on : .off
    }

    @objc private func stickyResizeToggled(_ sender: NSButton) {
        let enabled = sender.state == .on
        AppController.shared.setStickyResizeEnabledFromSettings(enabled)
        syncStickyResizeCheckbox()
    }

    private func syncStickyResizeCheckbox() {
        let enabled = AppController.shared.isStickyResizeEnabledInSettings
        stickyResizeCheckbox?.state = enabled ? .on : .off
    }
}
