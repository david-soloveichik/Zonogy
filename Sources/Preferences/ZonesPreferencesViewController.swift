/// View controller for the Zones preferences tab; also the way into the sheet for replacing the
/// focused window (`TargetingSheetViewController`).
import AppKit

final class ZonesPreferencesViewController: NSViewController {

    private var autoShowLauncherCheckbox: NSButton?
    private var stickyResizeCheckbox: NSButton?
    private var zoneLayoutOptionViews: [ZoneLayoutStyleOptionView] = []
    private var zoneLayoutHintLabel: NSTextField?

    private static func caption(for style: ZoneLayoutStyle) -> String {
        switch style {
        case .rightBar: return "Add bar on right"
        case .leftBar: return "Add bar on left"
        case .dualBar: return "Add bars on both sides"
        }
    }

    /// Describes the selected layout: where its add-zone bar sits and how its zones tile when full.
    private static func hint(for style: ZoneLayoutStyle) -> String {
        switch style {
        case .rightBar:
            return "Clicking the add-zone bar on the right edge of the display adds a zone. Up to 3 zones: one on the left, two stacked on the right."
        case .leftBar:
            return "Clicking the add-zone bar on the left edge of the display adds a zone. Up to 3 zones: one on the right, two stacked on the left."
        case .dualBar:
            return "Clicking an add-zone bar adds a zone on that side of the display. Up to 4 zones: two stacked on each side."
        }
    }

    override func loadView() {
        let containerView = NSView(frame: NSRect(x: 0, y: 0, width: 580, height: 420))

        // Zone layout picker
        let zoneLayoutTitleLabel = NSTextField(labelWithString: "Zone Layout")
        zoneLayoutTitleLabel.font = NSFont.systemFont(ofSize: 16, weight: .semibold)
        zoneLayoutTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(zoneLayoutTitleLabel)

        let optionsStack = NSStackView()
        optionsStack.orientation = .horizontal
        optionsStack.spacing = 16
        optionsStack.alignment = .top
        optionsStack.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(optionsStack)

        zoneLayoutOptionViews = []
        for style in ZoneLayoutStyle.allCases {
            let caption = Self.caption(for: style)
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

        // The hint follows the selection (filled in by syncZoneLayoutSelection).
        let zoneLayoutHintLabel = NSTextField(wrappingLabelWithString: "")
        zoneLayoutHintLabel.font = NSFont.systemFont(ofSize: 12)
        zoneLayoutHintLabel.textColor = .secondaryLabelColor
        zoneLayoutHintLabel.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(zoneLayoutHintLabel)
        self.zoneLayoutHintLabel = zoneLayoutHintLabel

        let zoneLayoutSeparator = NSBox()
        zoneLayoutSeparator.boxType = .separator
        zoneLayoutSeparator.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(zoneLayoutSeparator)

        let autoShowLauncherCheckbox = NSButton(checkboxWithTitle: "Automatically show Launcher for empty zones", target: self, action: #selector(autoShowLauncherToggled(_:)))
        autoShowLauncherCheckbox.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(autoShowLauncherCheckbox)
        self.autoShowLauncherCheckbox = autoShowLauncherCheckbox

        let autoShowLauncherHintLabel = NSTextField(wrappingLabelWithString: "When a tiling zone becomes empty, or Zone Navigation selects an empty zone, Launcher opens automatically.")
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
            wrappingLabelWithString: "Manually resized tiled windows return to the zone frame when inactive, then restore their remembered size when reactivated until that display's tiling geometry changes."
        )
        stickyResizeHintLabel.font = NSFont.systemFont(ofSize: 12)
        stickyResizeHintLabel.textColor = .secondaryLabelColor
        stickyResizeHintLabel.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(stickyResizeHintLabel)

        // Destination zone: the rule first, for readers new to Zonogy, then how dragging sidesteps
        // it. The exception — replacing the focused window — lives in a sheet: its options are
        // rarely visited, so a single button names it here without giving it the pane's weight.
        let destinationSeparator = NSBox()
        destinationSeparator.boxType = .separator
        destinationSeparator.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(destinationSeparator)

        let destinationTitleLabel = NSTextField(labelWithString: "Destination Zone")
        destinationTitleLabel.font = NSFont.systemFont(ofSize: 16, weight: .semibold)
        destinationTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(destinationTitleLabel)

        let destinationDescriptionLabel = NSTextField(
            wrappingLabelWithString: "Windows open into the current destination zone, marked with the glowing indicator. When no zone is the destination, new windows go into the floating zone of the display you are working on. Emptying a zone (for example, by minimizing or closing its window) makes that zone the destination; you can also change the destination by mouse or keyboard (see Shortcuts)."
        )
        destinationDescriptionLabel.font = NSFont.systemFont(ofSize: 12)
        destinationDescriptionLabel.textColor = .secondaryLabelColor
        destinationDescriptionLabel.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(destinationDescriptionLabel)

        let destinationDraggingLabel = NSTextField(
            wrappingLabelWithString: "Dragging an app or window from the Dock (with DockMenus enabled) always places it directly into the zone you want."
        )
        destinationDraggingLabel.font = NSFont.systemFont(ofSize: 12)
        destinationDraggingLabel.textColor = .secondaryLabelColor
        destinationDraggingLabel.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(destinationDraggingLabel)

        let targetingButton = NSButton(
            title: "Replacing Focused Window…", target: self, action: #selector(editTargeting))
        targetingButton.bezelStyle = .rounded
        targetingButton.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(targetingButton)

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

            destinationSeparator.topAnchor.constraint(equalTo: stickyResizeHintLabel.bottomAnchor, constant: 20),
            destinationSeparator.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),
            destinationSeparator.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -20),

            destinationTitleLabel.topAnchor.constraint(equalTo: destinationSeparator.bottomAnchor, constant: 16),
            destinationTitleLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),

            destinationDescriptionLabel.topAnchor.constraint(equalTo: destinationTitleLabel.bottomAnchor, constant: 6),
            destinationDescriptionLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),
            destinationDescriptionLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -20),

            destinationDraggingLabel.topAnchor.constraint(equalTo: destinationDescriptionLabel.bottomAnchor, constant: 8),
            destinationDraggingLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),
            destinationDraggingLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -20),

            targetingButton.topAnchor.constraint(equalTo: destinationDraggingLabel.bottomAnchor, constant: 16),
            targetingButton.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),
        ])

        self.view = containerView
        self.preferredContentSize = NSSize(width: 580, height: 600)
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
        zoneLayoutHintLabel?.stringValue = Self.hint(for: current)
    }

    @objc private func autoShowLauncherToggled(_ sender: NSButton) {
        let enabled = sender.state == .on
        AppController.shared.setAutoShowLauncherForEmptyZonesEnabledFromSettings(enabled)
        syncAutoShowLauncherCheckbox()
    }

    private func syncAutoShowLauncherCheckbox() {
        let enabled = AppController.shared.isAutoShowLauncherForEmptyZonesEnabledInSettings
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

    @objc private func editTargeting() {
        presentAsSheet(TargetingSheetViewController())
    }
}
