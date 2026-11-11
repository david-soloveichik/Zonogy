/// View controller for the General preferences tab
import AppKit

final class GeneralPreferencesViewController: NSViewController {

    private let permissionBanners = PermissionBannersView()
    private var launchAtLoginCheckbox: NSButton?
    private var launchAtLoginHintLabel: NSTextField?
    private var updateCheckCheckbox: NSButton?
    private var updateCheckHintLabel: NSTextField?
    private var highlightColorWell: NSColorWell?
    private var resetHighlightColorButton: NSButton?
    private var opacityValueLabel: NSTextField?
    private var dockMenusCheckbox: NSButton?
    private var dockMenusHintLabel: NSTextField?

    override func loadView() {
        let containerView = NSView(frame: NSRect(x: 0, y: 0, width: 580, height: 420))

        // Title label
        let titleLabel = NSTextField(labelWithString: "General Settings")
        titleLabel.font = NSFont.systemFont(ofSize: 16, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(titleLabel)

        // Permission banners. Granting Accessibility restarts Zonogy.
        permissionBanners.onAccessibilityGranted = {
            AppController.shared.restartAfterAccessibilityGranted()
        }
        permissionBanners.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(permissionBanners)

        let launchAtLoginCheckbox = NSButton(checkboxWithTitle: "Launch Zonogy at login", target: self, action: #selector(launchAtLoginToggled(_:)))
        launchAtLoginCheckbox.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(launchAtLoginCheckbox)
        self.launchAtLoginCheckbox = launchAtLoginCheckbox

        let launchAtLoginHintLabel = NSTextField(wrappingLabelWithString: "Automatically start Zonogy when you log in to your Mac.")
        launchAtLoginHintLabel.font = NSFont.systemFont(ofSize: 12)
        launchAtLoginHintLabel.textColor = .secondaryLabelColor
        launchAtLoginHintLabel.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(launchAtLoginHintLabel)
        self.launchAtLoginHintLabel = launchAtLoginHintLabel

        let updateCheckCheckbox = NSButton(checkboxWithTitle: "Automatically check for updates", target: self, action: #selector(updateCheckToggled(_:)))
        updateCheckCheckbox.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(updateCheckCheckbox)
        self.updateCheckCheckbox = updateCheckCheckbox

        let updateCheckHintLabel = NSTextField(wrappingLabelWithString: "Once a day, Zonogy checks GitHub for a newer release.")
        updateCheckHintLabel.font = NSFont.systemFont(ofSize: 12)
        updateCheckHintLabel.textColor = .secondaryLabelColor
        updateCheckHintLabel.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(updateCheckHintLabel)
        self.updateCheckHintLabel = updateCheckHintLabel

        // Overlay appearance: the highlight color and opacity of everything Zonogy draws on the desktop.
        let appearanceSeparator = NSBox()
        appearanceSeparator.boxType = .separator
        appearanceSeparator.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(appearanceSeparator)

        let highlightColorLabel = NSTextField(labelWithString: "Highlight color:")
        highlightColorLabel.font = NSFont.systemFont(ofSize: 13)
        highlightColorLabel.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(highlightColorLabel)

        let highlightColorWell = NSColorWell(style: .minimal)
        highlightColorWell.supportsAlpha = false
        highlightColorWell.target = self
        highlightColorWell.action = #selector(highlightColorChanged(_:))
        highlightColorWell.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(highlightColorWell)
        self.highlightColorWell = highlightColorWell

        let resetHighlightColorButton = NSButton(title: "Reset to Blue", target: self, action: #selector(resetHighlightColor))
        resetHighlightColorButton.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(resetHighlightColorButton)
        self.resetHighlightColorButton = resetHighlightColorButton

        let opacityLabel = NSTextField(labelWithString: "Opacity:")
        opacityLabel.font = NSFont.systemFont(ofSize: 13)
        opacityLabel.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(opacityLabel)

        let opacitySlider = NSSlider(
            value: OverlayAppearance.opacityScale,
            minValue: OverlayAppearance.opacityScaleRange.lowerBound,
            maxValue: OverlayAppearance.opacityScaleRange.upperBound,
            target: self,
            action: #selector(opacityChanged(_:))
        )
        // A tick every 25% from 25% to 150%, so 100% (the default look) is a tick.
        opacitySlider.numberOfTickMarks = 6
        opacitySlider.isContinuous = true
        opacitySlider.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(opacitySlider)

        let opacityValueLabel = NSTextField(labelWithString: "")
        opacityValueLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        opacityValueLabel.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(opacityValueLabel)
        self.opacityValueLabel = opacityValueLabel

        let appearanceHintLabel = NSTextField(wrappingLabelWithString: "Applies to everything Zonogy draws on the desktop, such as placeholders, zone bars, and the destination indicator.")
        appearanceHintLabel.font = NSFont.systemFont(ofSize: 12)
        appearanceHintLabel.textColor = .secondaryLabelColor
        appearanceHintLabel.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(appearanceHintLabel)

        // DockMenus is a feature of its own, unlike the app-level settings above.
        let dockMenusSeparator = NSBox()
        dockMenusSeparator.boxType = .separator
        dockMenusSeparator.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(dockMenusSeparator)

        let dockMenusCheckbox = NSButton(checkboxWithTitle: "Enable DockMenus", target: self, action: #selector(dockMenusToggled(_:)))
        dockMenusCheckbox.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(dockMenusCheckbox)
        self.dockMenusCheckbox = dockMenusCheckbox

        let dockMenusHintLabel = NSTextField(wrappingLabelWithString: "Hovering over a Dock app shows a window list. Clicking uses Zonogy's window selection instead of the default Dock behavior; shift-click to bypass.")
        dockMenusHintLabel.font = NSFont.systemFont(ofSize: 12)
        dockMenusHintLabel.textColor = .secondaryLabelColor
        dockMenusHintLabel.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(dockMenusHintLabel)
        self.dockMenusHintLabel = dockMenusHintLabel

        let dockMenusDragHintLabel = NSTextField(wrappingLabelWithString: "Dragging an app or window from the Dock places it directly into the zone where you drop it.")
        dockMenusDragHintLabel.font = NSFont.systemFont(ofSize: 12)
        dockMenusDragHintLabel.textColor = .secondaryLabelColor
        dockMenusDragHintLabel.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(dockMenusDragHintLabel)

        // Version info
        let versionLabel = NSTextField(labelWithString: AppVersion.preferencesDisplayString)
        versionLabel.font = NSFont.systemFont(ofSize: 11)
        versionLabel.textColor = .tertiaryLabelColor
        versionLabel.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(versionLabel)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 20),
            titleLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),

            permissionBanners.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 16),
            permissionBanners.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),
            permissionBanners.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -20),

            launchAtLoginCheckbox.topAnchor.constraint(equalTo: permissionBanners.bottomAnchor, constant: 18),
            launchAtLoginCheckbox.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),

            launchAtLoginHintLabel.topAnchor.constraint(equalTo: launchAtLoginCheckbox.bottomAnchor, constant: 6),
            launchAtLoginHintLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 40),
            launchAtLoginHintLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -20),

            updateCheckCheckbox.topAnchor.constraint(equalTo: launchAtLoginHintLabel.bottomAnchor, constant: 18),
            updateCheckCheckbox.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),

            updateCheckHintLabel.topAnchor.constraint(equalTo: updateCheckCheckbox.bottomAnchor, constant: 6),
            updateCheckHintLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 40),
            updateCheckHintLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -20),

            appearanceSeparator.topAnchor.constraint(equalTo: updateCheckHintLabel.bottomAnchor, constant: 20),
            appearanceSeparator.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),
            appearanceSeparator.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -20),

            highlightColorWell.topAnchor.constraint(equalTo: appearanceSeparator.bottomAnchor, constant: 14),
            highlightColorWell.leadingAnchor.constraint(equalTo: highlightColorLabel.trailingAnchor, constant: 8),
            highlightColorLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),
            highlightColorLabel.centerYAnchor.constraint(equalTo: highlightColorWell.centerYAnchor),

            resetHighlightColorButton.leadingAnchor.constraint(equalTo: highlightColorWell.trailingAnchor, constant: 12),
            resetHighlightColorButton.centerYAnchor.constraint(equalTo: highlightColorWell.centerYAnchor),

            opacitySlider.topAnchor.constraint(equalTo: highlightColorWell.bottomAnchor, constant: 12),
            opacitySlider.leadingAnchor.constraint(equalTo: highlightColorWell.leadingAnchor),
            opacitySlider.widthAnchor.constraint(equalToConstant: 220),
            opacityLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),
            opacityLabel.centerYAnchor.constraint(equalTo: opacitySlider.centerYAnchor),

            opacityValueLabel.leadingAnchor.constraint(equalTo: opacitySlider.trailingAnchor, constant: 8),
            opacityValueLabel.centerYAnchor.constraint(equalTo: opacitySlider.centerYAnchor),

            appearanceHintLabel.topAnchor.constraint(equalTo: opacitySlider.bottomAnchor, constant: 8),
            appearanceHintLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),
            appearanceHintLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -20),

            dockMenusSeparator.topAnchor.constraint(equalTo: appearanceHintLabel.bottomAnchor, constant: 20),
            dockMenusSeparator.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),
            dockMenusSeparator.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -20),

            dockMenusCheckbox.topAnchor.constraint(equalTo: dockMenusSeparator.bottomAnchor, constant: 14),
            dockMenusCheckbox.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),

            dockMenusHintLabel.topAnchor.constraint(equalTo: dockMenusCheckbox.bottomAnchor, constant: 6),
            dockMenusHintLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 40),
            dockMenusHintLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -20),

            dockMenusDragHintLabel.topAnchor.constraint(equalTo: dockMenusHintLabel.bottomAnchor, constant: 8),
            dockMenusDragHintLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 40),
            dockMenusDragHintLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -20),

            versionLabel.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -20),
            versionLabel.centerXAnchor.constraint(equalTo: containerView.centerXAnchor),
        ])

        self.view = containerView
        self.preferredContentSize = NSSize(width: 580, height: 580)
        syncLaunchAtLoginCheckbox()
        syncUpdateCheckCheckbox()
        syncHighlightColorControls()
        syncOpacityValueLabel()
        syncDockMenusCheckbox()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        permissionBanners.startPolling()
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        permissionBanners.stopPolling()
    }

    @objc private func launchAtLoginToggled(_ sender: NSButton) {
        let enabled = sender.state == .on
        AppController.shared.setLaunchAtLoginEnabledFromSettings(enabled)
        syncLaunchAtLoginCheckbox()
    }

    private func syncLaunchAtLoginCheckbox() {
        let enabled = AppController.shared.isLaunchAtLoginEnabledInSettings
        launchAtLoginCheckbox?.state = enabled ? .on : .off
    }

    @objc private func updateCheckToggled(_ sender: NSButton) {
        let enabled = sender.state == .on
        AppController.shared.setAutomaticUpdateCheckEnabledFromSettings(enabled)
        syncUpdateCheckCheckbox()
    }

    private func syncUpdateCheckCheckbox() {
        let enabled = AppController.shared.isAutomaticUpdateCheckEnabledInSettings
        updateCheckCheckbox?.state = enabled ? .on : .off
    }

    @objc private func highlightColorChanged(_ sender: NSColorWell) {
        OverlayAppearance.setCustomHighlightColor(sender.color)
        resetHighlightColorButton?.isEnabled = true
    }

    @objc private func resetHighlightColor() {
        OverlayAppearance.setCustomHighlightColor(nil)
        syncHighlightColorControls()
    }

    private func syncHighlightColorControls() {
        highlightColorWell?.color = OverlayAppearance.highlightColor
        resetHighlightColorButton?.isEnabled = OverlayAppearance.customHighlightColor != nil
    }

    /// Stores 5% steps so the percentage reads cleanly; the slider itself moves freely.
    @objc private func opacityChanged(_ sender: NSSlider) {
        OverlayAppearance.setOpacityScale((sender.doubleValue * 20).rounded() / 20)
        syncOpacityValueLabel()
    }

    private func syncOpacityValueLabel() {
        opacityValueLabel?.stringValue = "\(Int((OverlayAppearance.opacityScale * 100).rounded()))%"
    }

    @objc private func dockMenusToggled(_ sender: NSButton) {
        let enabled = sender.state == .on
        AppController.shared.setDockMenusEnabledFromSettings(enabled)
        syncDockMenusCheckbox()
    }

    private func syncDockMenusCheckbox() {
        let enabled = AppController.shared.isDockMenusEnabledInSettings
        dockMenusCheckbox?.state = enabled ? .on : .off
    }
}
