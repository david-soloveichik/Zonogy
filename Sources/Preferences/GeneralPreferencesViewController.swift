/// View controller for the General preferences tab
import AppKit
import ApplicationServices

final class GeneralPreferencesViewController: NSViewController {

    private var accessibilityPollingTimer: Timer?
    private var lastKnownAccessibilityState: Bool = false
    private var accessibilityStatusView: NSView?
    private var accessibilityStatusIcon: NSImageView?
    private var accessibilityStatusLabel: NSTextField?
    private var screenRecordingStatusView: NSView?
    private var screenRecordingStatusIcon: NSImageView?
    private var screenRecordingStatusLabel: NSTextField?
    private var launchAtLoginCheckbox: NSButton?
    private var updateCheckCheckbox: NSButton?
    private var settleDelayInput: NumberStepperInput?
    private var cmdTabSkipInput: NumberStepperInput?
    private var highlightColorWell: NSColorWell?
    private var opacitySlider: NSSlider?
    private var opacityValueLabel: NSTextField?
    private var resetAppearanceButton: NSButton?
    private var dockMenusCheckbox: NSButton?
    private var dockMenusHintLabel: NSTextField?

    override func loadView() {
        let containerView = NSView(frame: NSRect(x: 0, y: 0, width: 580, height: 420))

        // Title label
        let titleLabel = NSTextField(labelWithString: "General Settings")
        titleLabel.font = NSFont.systemFont(ofSize: 16, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(titleLabel)

        // Accessibility status banner
        let accessibilityStatusView = NSView()
        accessibilityStatusView.wantsLayer = true
        accessibilityStatusView.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(accessibilityStatusView)
        self.accessibilityStatusView = accessibilityStatusView

        let accessibilityStatusIcon = NSImageView()
        accessibilityStatusIcon.translatesAutoresizingMaskIntoConstraints = false
        accessibilityStatusIcon.imageScaling = .scaleProportionallyUpOrDown
        accessibilityStatusView.addSubview(accessibilityStatusIcon)
        self.accessibilityStatusIcon = accessibilityStatusIcon

        let accessibilityStatusLabel = NSTextField(wrappingLabelWithString: "")
        accessibilityStatusLabel.font = NSFont.systemFont(ofSize: 12)
        accessibilityStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        accessibilityStatusView.addSubview(accessibilityStatusLabel)
        self.accessibilityStatusLabel = accessibilityStatusLabel

        let accessibilityOpenSettingsButton = NSButton(title: "Open Settings…", target: self, action: #selector(openAccessibilitySettings))
        accessibilityOpenSettingsButton.bezelStyle = NSButton.BezelStyle.recessed
        accessibilityOpenSettingsButton.controlSize = NSControl.ControlSize.small
        accessibilityOpenSettingsButton.translatesAutoresizingMaskIntoConstraints = false
        accessibilityStatusView.addSubview(accessibilityOpenSettingsButton)

        NSLayoutConstraint.activate([
            accessibilityStatusIcon.leadingAnchor.constraint(equalTo: accessibilityStatusView.leadingAnchor, constant: 12),
            accessibilityStatusIcon.centerYAnchor.constraint(equalTo: accessibilityStatusView.centerYAnchor),
            accessibilityStatusIcon.widthAnchor.constraint(equalToConstant: 16),
            accessibilityStatusIcon.heightAnchor.constraint(equalToConstant: 16),

            accessibilityStatusLabel.leadingAnchor.constraint(equalTo: accessibilityStatusIcon.trailingAnchor, constant: 8),
            accessibilityStatusLabel.centerYAnchor.constraint(equalTo: accessibilityStatusView.centerYAnchor),
            accessibilityStatusLabel.trailingAnchor.constraint(lessThanOrEqualTo: accessibilityOpenSettingsButton.leadingAnchor, constant: -8),

            accessibilityOpenSettingsButton.trailingAnchor.constraint(equalTo: accessibilityStatusView.trailingAnchor, constant: -12),
            accessibilityOpenSettingsButton.centerYAnchor.constraint(equalTo: accessibilityStatusView.centerYAnchor),
        ])

        // Screen Recording status banner
        let screenRecordingStatusView = NSView()
        screenRecordingStatusView.wantsLayer = true
        screenRecordingStatusView.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(screenRecordingStatusView)
        self.screenRecordingStatusView = screenRecordingStatusView

        let screenRecordingStatusIcon = NSImageView()
        screenRecordingStatusIcon.translatesAutoresizingMaskIntoConstraints = false
        screenRecordingStatusIcon.imageScaling = .scaleProportionallyUpOrDown
        screenRecordingStatusView.addSubview(screenRecordingStatusIcon)
        self.screenRecordingStatusIcon = screenRecordingStatusIcon

        let screenRecordingStatusLabel = NSTextField(wrappingLabelWithString: "")
        screenRecordingStatusLabel.font = NSFont.systemFont(ofSize: 12)
        screenRecordingStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        screenRecordingStatusView.addSubview(screenRecordingStatusLabel)
        self.screenRecordingStatusLabel = screenRecordingStatusLabel

        let screenRecordingOpenSettingsButton = NSButton(title: "Open Settings…", target: self, action: #selector(openScreenRecordingSettings))
        screenRecordingOpenSettingsButton.bezelStyle = NSButton.BezelStyle.recessed
        screenRecordingOpenSettingsButton.controlSize = NSControl.ControlSize.small
        screenRecordingOpenSettingsButton.translatesAutoresizingMaskIntoConstraints = false
        screenRecordingStatusView.addSubview(screenRecordingOpenSettingsButton)

        NSLayoutConstraint.activate([
            screenRecordingStatusIcon.leadingAnchor.constraint(equalTo: screenRecordingStatusView.leadingAnchor, constant: 12),
            screenRecordingStatusIcon.centerYAnchor.constraint(equalTo: screenRecordingStatusView.centerYAnchor),
            screenRecordingStatusIcon.widthAnchor.constraint(equalToConstant: 16),
            screenRecordingStatusIcon.heightAnchor.constraint(equalToConstant: 16),

            screenRecordingStatusLabel.leadingAnchor.constraint(equalTo: screenRecordingStatusIcon.trailingAnchor, constant: 8),
            screenRecordingStatusLabel.centerYAnchor.constraint(equalTo: screenRecordingStatusView.centerYAnchor),
            screenRecordingStatusLabel.trailingAnchor.constraint(lessThanOrEqualTo: screenRecordingOpenSettingsButton.leadingAnchor, constant: -8),

            screenRecordingOpenSettingsButton.trailingAnchor.constraint(equalTo: screenRecordingStatusView.trailingAnchor, constant: -12),
            screenRecordingOpenSettingsButton.centerYAnchor.constraint(equalTo: screenRecordingStatusView.centerYAnchor),
        ])

        let launchAtLoginCheckbox = NSButton(checkboxWithTitle: "Launch Zonogy at login", target: self, action: #selector(launchAtLoginToggled(_:)))
        launchAtLoginCheckbox.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(launchAtLoginCheckbox)
        self.launchAtLoginCheckbox = launchAtLoginCheckbox

        let updateCheckCheckbox = NSButton(checkboxWithTitle: "Automatically check for updates", target: self, action: #selector(updateCheckToggled(_:)))
        updateCheckCheckbox.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(updateCheckCheckbox)
        self.updateCheckCheckbox = updateCheckCheckbox

        // Separates the app-level checkboxes from the timing and appearance settings below.
        let settingsSeparator = NSBox()
        settingsSeparator.boxType = .separator
        settingsSeparator.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(settingsSeparator)

        // Several features share the settle delay, so it lives here, with its uses in a popover.
        let settleDelayInput = NumberStepperInput(range: SecondsPreference.settleDelay.range) { [weak self] seconds in
            AppController.shared.setSettleDelayFromSettings(seconds)
            self?.syncSecondsInputs()
        }
        self.settleDelayInput = settleDelayInput
        let settleDelayRow = Self.makeSecondsRow(
            "Treat changes as intentional after", input: settleDelayInput,
            trailing: MoreInfoButton { Self.makeSettleDelayInfoView() }
        )
        containerView.addSubview(settleDelayRow)

        let cmdTabSkip = SecondsPreference.cmdTabJustMinimizedSkip
        let cmdTabSkipInput = NumberStepperInput(range: cmdTabSkip.range) { [weak self] seconds in
            cmdTabSkip.saveSeconds(seconds)
            self?.syncSecondsInputs()
        }
        self.cmdTabSkipInput = cmdTabSkipInput
        let cmdTabSkipRow = Self.makeSecondsRow(
            "CmdTab doesn't suggest windows minimized in the last", input: cmdTabSkipInput
        )
        containerView.addSubview(cmdTabSkipRow)

        // Overlay appearance: the highlight color and opacity of everything Zonogy draws on the desktop.
        let highlightLabel = NSTextField(labelWithString: "Highlight:")
        highlightLabel.font = NSFont.systemFont(ofSize: 13)

        let highlightColorWell = NSColorWell(style: .minimal)
        highlightColorWell.supportsAlpha = false
        highlightColorWell.target = self
        highlightColorWell.action = #selector(highlightColorChanged(_:))
        self.highlightColorWell = highlightColorWell

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
        opacitySlider.widthAnchor.constraint(equalToConstant: 200).isActive = true
        self.opacitySlider = opacitySlider

        let opacityValueLabel = NSTextField(labelWithString: "")
        opacityValueLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        // Wide enough for "150%", so the reset button beside it holds still while dragging.
        opacityValueLabel.widthAnchor.constraint(equalToConstant: 40).isActive = true
        self.opacityValueLabel = opacityValueLabel

        // Last in the row, so hiding it while both settings are at their defaults moves nothing.
        let resetAppearanceButton = NSButton(
            image: NSImage(systemSymbolName: "arrow.counterclockwise", accessibilityDescription: "Reset to blue and 100%")!,
            target: self, action: #selector(resetAppearance))
        resetAppearanceButton.isBordered = false
        resetAppearanceButton.contentTintColor = .secondaryLabelColor
        resetAppearanceButton.toolTip = "Reset to blue and 100%"
        self.resetAppearanceButton = resetAppearanceButton

        let highlightRow = NSStackView(views: [highlightLabel, highlightColorWell, opacitySlider, opacityValueLabel, resetAppearanceButton])
        highlightRow.orientation = .horizontal
        highlightRow.alignment = .centerY
        highlightRow.spacing = 10
        highlightRow.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(highlightRow)

        let appearanceHintLabel = NSTextField(wrappingLabelWithString: "Used for placeholders, zone bars, destination indicators, and more.")
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

            accessibilityStatusView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 16),
            accessibilityStatusView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),
            accessibilityStatusView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -20),
            accessibilityStatusView.heightAnchor.constraint(equalToConstant: 36),

            screenRecordingStatusView.topAnchor.constraint(equalTo: accessibilityStatusView.bottomAnchor, constant: 10),
            screenRecordingStatusView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),
            screenRecordingStatusView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -20),
            screenRecordingStatusView.heightAnchor.constraint(equalToConstant: 36),

            launchAtLoginCheckbox.topAnchor.constraint(equalTo: screenRecordingStatusView.bottomAnchor, constant: 18),
            launchAtLoginCheckbox.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),

            updateCheckCheckbox.topAnchor.constraint(equalTo: launchAtLoginCheckbox.bottomAnchor, constant: 10),
            updateCheckCheckbox.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),

            settingsSeparator.topAnchor.constraint(equalTo: updateCheckCheckbox.bottomAnchor, constant: 20),
            settingsSeparator.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),
            settingsSeparator.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -20),

            settleDelayRow.topAnchor.constraint(equalTo: settingsSeparator.bottomAnchor, constant: 14),
            settleDelayRow.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),

            cmdTabSkipRow.topAnchor.constraint(equalTo: settleDelayRow.bottomAnchor, constant: 10),
            cmdTabSkipRow.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),

            highlightRow.topAnchor.constraint(equalTo: cmdTabSkipRow.bottomAnchor, constant: 14),
            highlightRow.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),

            appearanceHintLabel.topAnchor.constraint(equalTo: highlightRow.bottomAnchor, constant: 8),
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

            versionLabel.topAnchor.constraint(equalTo: dockMenusDragHintLabel.bottomAnchor, constant: 24),
            versionLabel.centerXAnchor.constraint(equalTo: containerView.centerXAnchor),
        ])

        self.view = containerView
        fitPreferredContentSizeToContent()
        lastKnownAccessibilityState = AXIsProcessTrusted()
        syncAccessibilityStatus()
        syncScreenRecordingStatus()
        syncLaunchAtLoginCheckbox()
        syncUpdateCheckCheckbox()
        syncSecondsInputs()
        syncAppearanceControls()
        syncDockMenusCheckbox()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        startAccessibilityPolling()
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        stopAccessibilityPolling()
    }

    private func startAccessibilityPolling() {
        stopAccessibilityPolling()
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.syncAccessibilityStatus()
            self?.syncScreenRecordingStatus()
        }
        timer.tolerance = 0.5
        accessibilityPollingTimer = timer
    }

    private func stopAccessibilityPolling() {
        accessibilityPollingTimer?.invalidate()
        accessibilityPollingTimer = nil
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

    private func syncSecondsInputs() {
        settleDelayInput?.show(SecondsPreference.settleDelay.loadSeconds())
        cmdTabSkipInput?.show(SecondsPreference.cmdTabJustMinimizedSkip.loadSeconds())
    }

    /// A setting that reads "<words> [N] seconds", with `trailing` after it.
    private static func makeSecondsRow(_ words: String, input: NumberStepperInput, trailing: NSView? = nil) -> NSStackView {
        let wordsLabel = NSTextField(labelWithString: words)
        wordsLabel.font = NSFont.systemFont(ofSize: 13)
        let secondsLabel = NSTextField(labelWithString: "seconds")
        secondsLabel.font = NSFont.systemFont(ofSize: 13)
        let row = NSStackView(views: [wordsLabel, input.field, input.stepper, secondsLabel] + [trailing].compactMap { $0 })
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 6
        row.setCustomSpacing(12, after: secondsLabel)
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    /// What the settle delay is for, in its More Info popover.
    private static func makeSettleDelayInfoView() -> NSView {
        let width: CGFloat = 380
        let label = NSTextField(wrappingLabelWithString: "This counters apps temporarily bringing forward a window other than the one you want, such as an existing window when you open a document.")
        label.font = NSFont.systemFont(ofSize: 12)
        label.preferredMaxLayoutWidth = width
        label.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(label)
        NSLayoutConstraint.activate([
            // Pinned to a width: a wrapping label yields horizontally, and the popover's fitting
            // size would otherwise squeeze it to its longest word.
            label.widthAnchor.constraint(equalToConstant: width),
            label.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            label.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            label.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
        ])
        return content
    }

    @objc private func highlightColorChanged(_ sender: NSColorWell) {
        OverlayAppearance.setCustomHighlightColor(sender.color)
        syncAppearanceControls()
    }

    /// Stores 5% steps so the percentage reads cleanly; the slider itself moves freely.
    @objc private func opacityChanged(_ sender: NSSlider) {
        OverlayAppearance.setOpacityScale((sender.doubleValue * 20).rounded() / 20)
        syncAppearanceControls()
    }

    @objc private func resetAppearance() {
        OverlayAppearance.setCustomHighlightColor(nil)
        OverlayAppearance.setOpacityScale(1)
        opacitySlider?.doubleValue = OverlayAppearance.opacityScale
        syncAppearanceControls()
    }

    /// Everything but the slider's position, which follows the pointer while dragged.
    private func syncAppearanceControls() {
        highlightColorWell?.color = OverlayAppearance.highlightColor
        opacityValueLabel?.stringValue = "\(Int((OverlayAppearance.opacityScale * 100).rounded()))%"
        resetAppearanceButton?.isHidden = OverlayAppearance.customHighlightColor == nil && OverlayAppearance.opacityScale == 1
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

    private func syncAccessibilityStatus() {
        let hasAccess = AXIsProcessTrusted()

        // Detect transition from no access to access granted
        if hasAccess && !lastKnownAccessibilityState {
            lastKnownAccessibilityState = true
            AppController.shared.restartAfterAccessibilityGranted()
            return  // App is restarting, skip UI update
        } else {
            lastKnownAccessibilityState = hasAccess
        }

        if hasAccess {
            accessibilityStatusView?.layer?.backgroundColor = NSColor.systemGreen.withAlphaComponent(0.15).cgColor
            accessibilityStatusView?.layer?.cornerRadius = 6
            accessibilityStatusIcon?.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Granted")
            accessibilityStatusIcon?.contentTintColor = .systemGreen
            accessibilityStatusLabel?.stringValue = "Accessibility permission granted"
            accessibilityStatusLabel?.textColor = .labelColor
        } else {
            accessibilityStatusView?.layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.15).cgColor
            accessibilityStatusView?.layer?.cornerRadius = 6
            accessibilityStatusIcon?.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Required")
            accessibilityStatusIcon?.contentTintColor = .systemOrange
            accessibilityStatusLabel?.stringValue = "Accessibility permission required"
            accessibilityStatusLabel?.textColor = .labelColor
        }
    }

    private func syncScreenRecordingStatus() {
        let hasAccess = CGPreflightScreenCaptureAccess()

        if hasAccess {
            screenRecordingStatusView?.layer?.backgroundColor = NSColor.systemGreen.withAlphaComponent(0.15).cgColor
            screenRecordingStatusView?.layer?.cornerRadius = 6
            screenRecordingStatusIcon?.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Granted")
            screenRecordingStatusIcon?.contentTintColor = .systemGreen
            screenRecordingStatusLabel?.stringValue = "Screen Recording permission granted (for WinShot Snapshots)"
            screenRecordingStatusLabel?.textColor = .labelColor
        } else {
            screenRecordingStatusView?.layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.15).cgColor
            screenRecordingStatusView?.layer?.cornerRadius = 6
            screenRecordingStatusIcon?.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Required")
            screenRecordingStatusIcon?.contentTintColor = .systemOrange
            screenRecordingStatusLabel?.stringValue = "Screen Recording permission not granted (for WinShot Snapshots)"
            screenRecordingStatusLabel?.textColor = .labelColor
        }
    }

    @objc private func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    @objc private func openScreenRecordingSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }
}
