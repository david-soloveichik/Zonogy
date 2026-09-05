/// View controller for the Debug preferences tab.
import AppKit

final class DebugPreferencesViewController: NSViewController {
    private var saveLogCheckbox: NSButton?
    private var dockOverlayCheckbox: NSButton?
    private var fullScreenOverlayCheckbox: NSButton?
    private var showPassThroughHolesCheckbox: NSButton?
    private var disablePrePositionCheckbox: NSButton?
    private var disableNativeTabsCheckbox: NSButton?
    private var highlightImplicitFloatingTargetCheckbox: NSButton?
    private var timeTravelHintLabel: NSTextField?

    override func loadView() {
        let containerView = NSView(frame: NSRect(x: 0, y: 0, width: 580, height: 525))

        let titleLabel = NSTextField(labelWithString: "Debug Settings")
        titleLabel.font = NSFont.systemFont(ofSize: 16, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(titleLabel)

        let saveLog = makeToggle(
            title: "Save debug log to file",
            hint: "When enabled, Zonogy writes /tmp/zonogy-debug.log. Turning this on clears that file.",
            action: #selector(saveLogToggled(_:))
        )
        saveLogCheckbox = saveLog.checkbox
        let dockOverlay = makeToggle(
            title: "Show Dock debug rectangle",
            hint: "Shows a blue rectangle around the Dock frame used by DockMenus.",
            action: #selector(dockOverlayToggled(_:))
        )
        dockOverlayCheckbox = dockOverlay.checkbox
        let fullScreenOverlay = makeToggle(
            title: "Show full-screen debug rectangles",
            hint: "Shows orange rectangles around displays detected as native macOS full-screen.",
            action: #selector(fullScreenOverlayToggled(_:))
        )
        fullScreenOverlayCheckbox = fullScreenOverlay.checkbox
        let showPassThroughHoles = makeToggle(
            title: "Show placeholder pass-through holes",
            hint: "Paints the placeholder click-catching background visibly, so pass-through holes over covered windows appear as clear cut-outs.",
            action: #selector(showPassThroughHolesToggled(_:))
        )
        showPassThroughHolesCheckbox = showPassThroughHoles.checkbox
        let disablePrePosition = makeToggle(
            title: "Disable pre-position of minimized windows prior to unminimize",
            hint: "When on, Zonogy skips moving a minimized window to its destination frame before unminimizing; the window is positioned only after it is restored.",
            action: #selector(disablePrePositionToggled(_:))
        )
        disablePrePositionCheckbox = disablePrePosition.checkbox
        let disableNativeTabs = makeToggle(
            title: "Disable native macOS tab handling",
            hint: "When on, disables Zonogy's special handling of native macOS tabs.",
            action: #selector(disableNativeTabsToggled(_:))
        )
        disableNativeTabsCheckbox = disableNativeTabs.checkbox
        let highlightImplicitFloatingTarget = makeToggle(
            title: "Show the floating zone used when no zone is the destination",
            hint: "Tints red the Floating Zone Bar of the floating zone that receives new windows while no zone is the destination.",
            action: #selector(highlightImplicitFloatingTargetToggled(_:))
        )
        highlightImplicitFloatingTargetCheckbox = highlightImplicitFloatingTarget.checkbox

        // The toggles scroll between the fixed title above and the fixed file locations below.
        let toggleDocument = FlippedView()
        toggleDocument.translatesAutoresizingMaskIntoConstraints = false
        let toggles = [saveLog, dockOverlay, fullScreenOverlay, showPassThroughHoles, disablePrePosition, disableNativeTabs, highlightImplicitFloatingTarget]
        var previousBottom = toggleDocument.topAnchor
        for (index, toggle) in toggles.enumerated() {
            toggleDocument.addSubview(toggle.view)
            NSLayoutConstraint.activate([
                toggle.view.topAnchor.constraint(equalTo: previousBottom, constant: index == 0 ? 0 : 14),
                toggle.view.leadingAnchor.constraint(equalTo: toggleDocument.leadingAnchor, constant: 20),
                toggle.view.trailingAnchor.constraint(equalTo: toggleDocument.trailingAnchor, constant: -20),
            ])
            previousBottom = toggle.view.bottomAnchor
        }
        previousBottom.constraint(equalTo: toggleDocument.bottomAnchor).isActive = true

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        // A persistent scroller track, unlike an overlay one, shows that the list continues below.
        scrollView.scrollerStyle = .legacy
        scrollView.documentView = toggleDocument
        containerView.addSubview(scrollView)

        let filesHeaderLabel = NSTextField(labelWithString: "Debug File Locations")
        filesHeaderLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        filesHeaderLabel.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(filesHeaderLabel)

        let debugLogPathLabel = NSTextField(
            wrappingLabelWithString: "Debug log: \(Logger.logPath)"
        )
        debugLogPathLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        debugLogPathLabel.textColor = .secondaryLabelColor
        debugLogPathLabel.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(debugLogPathLabel)

        let timeTravelLogPathLabel = NSTextField(
            wrappingLabelWithString: "Time-travel log: \(Logger.timeTravelLogPath)"
        )
        timeTravelLogPathLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        timeTravelLogPathLabel.textColor = .secondaryLabelColor
        timeTravelLogPathLabel.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(timeTravelLogPathLabel)

        // Names the capture shortcut, so it is filled in by syncControls whenever the tab appears.
        let timeTravelHintLabel = NSTextField(wrappingLabelWithString: "")
        timeTravelHintLabel.font = NSFont.systemFont(ofSize: 12)
        timeTravelHintLabel.textColor = .secondaryLabelColor
        timeTravelHintLabel.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(timeTravelHintLabel)
        self.timeTravelHintLabel = timeTravelHintLabel

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 20),
            titleLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),

            scrollView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 18),
            scrollView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            // Sized so the list's cut lands mid-line through a hint rather than in a gap, which
            // is what shows that it continues; tuned to the current toggles.
            scrollView.bottomAnchor.constraint(equalTo: filesHeaderLabel.topAnchor, constant: -30),
            toggleDocument.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),

            filesHeaderLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),

            debugLogPathLabel.topAnchor.constraint(equalTo: filesHeaderLabel.bottomAnchor, constant: 8),
            debugLogPathLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),
            debugLogPathLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -20),

            timeTravelLogPathLabel.topAnchor.constraint(equalTo: debugLogPathLabel.bottomAnchor, constant: 4),
            timeTravelLogPathLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),
            timeTravelLogPathLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -20),

            timeTravelHintLabel.topAnchor.constraint(equalTo: timeTravelLogPathLabel.bottomAnchor, constant: 10),
            timeTravelHintLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),
            timeTravelHintLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -20),
            timeTravelHintLabel.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -20),
        ])

        self.view = containerView
        self.preferredContentSize = NSSize(width: 580, height: 525)
        syncControls()
    }

    /// A checkbox with its explanatory hint beneath, indented like the rest of the pane.
    private func makeToggle(title: String, hint: String, action: Selector) -> (view: NSView, checkbox: NSButton) {
        let checkbox = NSButton(checkboxWithTitle: title, target: self, action: action)
        checkbox.translatesAutoresizingMaskIntoConstraints = false
        let hintLabel = NSTextField(wrappingLabelWithString: hint)
        hintLabel.font = NSFont.systemFont(ofSize: 12)
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.translatesAutoresizingMaskIntoConstraints = false

        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(checkbox)
        view.addSubview(hintLabel)
        NSLayoutConstraint.activate([
            checkbox.topAnchor.constraint(equalTo: view.topAnchor),
            checkbox.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hintLabel.topAnchor.constraint(equalTo: checkbox.bottomAnchor, constant: 6),
            hintLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            hintLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hintLabel.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        return (view, checkbox)
    }

    /// Shortcuts may have been rebound since the tab was last shown.
    override func viewWillAppear() {
        super.viewWillAppear()
        syncControls()
    }

    @objc private func saveLogToggled(_ sender: NSButton) {
        let enabled = sender.state == .on
        AppController.shared.setDebugLogToFileEnabledFromSettings(enabled)
        syncControls()
    }

    @objc private func dockOverlayToggled(_ sender: NSButton) {
        let enabled = sender.state == .on
        AppController.shared.setDockMenusDebugOverlayEnabledFromSettings(enabled)
        syncControls()
    }

    @objc private func fullScreenOverlayToggled(_ sender: NSButton) {
        let enabled = sender.state == .on
        AppController.shared.setFullScreenDebugOverlayEnabledFromSettings(enabled)
        syncControls()
    }

    @objc private func showPassThroughHolesToggled(_ sender: NSButton) {
        let enabled = sender.state == .on
        AppController.shared.setShowPlaceholderPassThroughHolesFromSettings(enabled)
        syncControls()
    }

    @objc private func disablePrePositionToggled(_ sender: NSButton) {
        let enabled = sender.state == .on
        AppController.shared.setDisablePrePositionBeforeUnminimizeFromSettings(enabled)
        syncControls()
    }

    @objc private func disableNativeTabsToggled(_ sender: NSButton) {
        let disabled = sender.state == .on
        AppController.shared.setNativeTabHandlingDisabledFromSettings(disabled)
        syncControls()
    }

    @objc private func highlightImplicitFloatingTargetToggled(_ sender: NSButton) {
        let enabled = sender.state == .on
        AppController.shared.setHighlightImplicitFloatingTargetFromSettings(enabled)
        syncControls()
    }

    private func syncControls() {
        saveLogCheckbox?.state = AppController.shared.isDebugLogToFileEnabledInSettings ? .on : .off
        dockOverlayCheckbox?.state = AppController.shared.isDockMenusDebugOverlayEnabledInSettings ? .on : .off
        fullScreenOverlayCheckbox?.state = AppController.shared.isFullScreenDebugOverlayEnabledInSettings ? .on : .off
        showPassThroughHolesCheckbox?.state = AppController.shared.isShowPlaceholderPassThroughHolesInSettings ? .on : .off
        disablePrePositionCheckbox?.state = AppController.shared.isDisablePrePositionBeforeUnminimizeInSettings ? .on : .off
        disableNativeTabsCheckbox?.state = AppController.shared.isNativeTabHandlingDisabledInSettings ? .on : .off
        highlightImplicitFloatingTargetCheckbox?.state = AppController.shared.isHighlightImplicitFloatingTargetInSettings ? .on : .off
        timeTravelHintLabel?.stringValue =
            "Time-travel log capture uses \(KeyboardShortcutPreferences.shared.keyPhrase(for: .captureTimeTravelLogs)) (settable in Shortcuts) and does not depend on these toggles."
    }
}
