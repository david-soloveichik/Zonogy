/// View controller for the Debug preferences tab.
import AppKit

final class DebugPreferencesViewController: NSViewController {
    private var logFileCheckbox: NSButton?
    private var dockOverlayCheckbox: NSButton?
    private var fullScreenOverlayCheckbox: NSButton?
    private var showPassThroughHolesCheckbox: NSButton?
    private var disablePrePositionCheckbox: NSButton?
    private var disableNativeTabsCheckbox: NSButton?
    private var highlightImplicitFloatingTargetCheckbox: NSButton?
    private var timeTravelHintLabel: NSTextField?
    private var loggingInfoPopover: NSPopover?

    override func loadView() {
        let containerView = NSView(frame: NSRect(x: 0, y: 0, width: 580, height: 540))

        let titleLabel = NSTextField(labelWithString: "Debug Settings")
        titleLabel.font = NSFont.systemFont(ofSize: 16, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(titleLabel)

        let logFile = makeToggle(
            title: "Save the log to a file",
            hint: "Appends every log line to the log file listed below, in the same format as the time-travel log. "
                + "It and the previous day's file together hold the last one to two days.",
            action: #selector(logFileToggled(_:))
        )
        logFileCheckbox = logFile.checkbox
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

        // The toggles scroll between the fixed title above and the fixed log section below.
        let toggleDocument = FlippedView()
        toggleDocument.translatesAutoresizingMaskIntoConstraints = false
        let toggles = [logFile, dockOverlay, fullScreenOverlay, showPassThroughHoles, disablePrePosition, disableNativeTabs, highlightImplicitFloatingTarget]
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

        let logHeaderLabel = NSTextField(labelWithString: "Debug Logging")
        logHeaderLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        logHeaderLabel.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(logHeaderLabel)

        let logIntroLabel = makeHintLabel(
            "Zonogy logs through the macOS unified logging system (subsystem \(Logger.subsystem))."
        )
        // The levels and the Terminal commands live in a popover, keeping the tab short.
        let moreInfoButton = NSButton(title: "More Info…", target: self, action: #selector(showLoggingInfo(_:)))
        moreInfoButton.controlSize = .small
        moreInfoButton.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        moreInfoButton.translatesAutoresizingMaskIntoConstraints = false
        moreInfoButton.setContentHuggingPriority(.required, for: .horizontal)
        // Names the capture shortcut, so it is filled in by syncControls whenever the tab appears.
        let timeTravelHintLabel = makeHintLabel("")
        self.timeTravelHintLabel = timeTravelHintLabel
        let timeTravelLogPathLabel = makeMonospacedLabel("Time-travel log: \(TimeTravelLogCapture.outputPath)")
        let logFilePathLabel = makeMonospacedLabel("Log file: \(LogFile.path)")
        let previousLogFilePathLabel = makeMonospacedLabel("Previous day: \(LogFile.previousPath)")

        // The log section is a fixed column under the header, pinned to the container's sides.
        let logSection: [(view: NSView, spacingAbove: CGFloat)] = [
            (logIntroLabel, 8), (moreInfoButton, 6), (timeTravelHintLabel, 14), (timeTravelLogPathLabel, 6),
            (logFilePathLabel, 6), (previousLogFilePathLabel, 6),
        ]
        var previousLogView: NSView = logHeaderLabel
        for entry in logSection {
            containerView.addSubview(entry.view)
            NSLayoutConstraint.activate([
                entry.view.topAnchor.constraint(equalTo: previousLogView.bottomAnchor, constant: entry.spacingAbove),
                entry.view.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),
                entry.view.trailingAnchor.constraint(lessThanOrEqualTo: containerView.trailingAnchor, constant: -20),
            ])
            previousLogView = entry.view
        }

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 20),
            titleLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),

            scrollView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 18),
            scrollView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            // Sized so the list's cut lands mid-line through a hint rather than in a gap, which
            // is what shows that it continues; tuned to the current toggles.
            scrollView.bottomAnchor.constraint(equalTo: logHeaderLabel.topAnchor, constant: -30),
            toggleDocument.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),

            logHeaderLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),
            // Wrapping labels need both edges pinned to know their width.
            logIntroLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -20),
            timeTravelHintLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -20),
            timeTravelLogPathLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -20),
            logFilePathLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -20),
            previousLogFilePathLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -20),
            previousLogView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -20),
        ])

        self.view = containerView
        self.preferredContentSize = NSSize(width: 580, height: 540)
        syncControls()
    }

    // MARK: - Logging info popover

    @objc private func showLoggingInfo(_ sender: NSButton) {
        if let popover = loggingInfoPopover, popover.isShown {
            popover.close()
            return
        }
        let content = makeLoggingInfoView()
        content.layoutSubtreeIfNeeded()
        let controller = NSViewController()
        controller.view = content
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = controller
        popover.contentSize = content.fittingSize
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
        loggingInfoPopover = popover
    }

    /// The log levels and how to read them: the detail behind the tab's one-line summary.
    private func makeLoggingInfoView() -> NSView {
        let width: CGFloat = 480
        let inset: CGFloat = 14
        let levelsLabel = makeBulletListLabel([
            "The normal trace is at level Info, which macOS holds in memory only and purges as its buffers fill (minutes).",
            "Events worth finding later are at the Default and Error levels, which macOS keeps on disk until its store is full (days-weeks).",
        ])
        let readLabel = makeHintLabel(
            "Read it with the log command in Terminal; drop the info option to see only the persisted levels:"
        )
        let subsystemPredicate = "--predicate 'subsystem == \"\(Logger.subsystem)\"'"
        let liveCommandLabel = makeMonospacedLabel("log stream --level info \(subsystemPredicate)")
        let historyCommandLabel = makeMonospacedLabel("log show --last 5m --info \(subsystemPredicate)")

        let labels = [levelsLabel, readLabel, liveCommandLabel, historyCommandLabel]
        for label in labels {
            label.textColor = .labelColor
            label.preferredMaxLayoutWidth = width - 2 * inset
        }
        let stack = NSStackView(views: labels)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(4, after: liveCommandLabel)
        stack.edgeInsets = NSEdgeInsets(top: inset, left: inset, bottom: inset, right: inset)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: width),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        return container
    }

    // MARK: - Controls

    /// A checkbox with its explanatory hint beneath, indented like the rest of the pane.
    private func makeToggle(title: String, hint: String, action: Selector) -> (view: NSView, checkbox: NSButton) {
        let checkbox = NSButton(checkboxWithTitle: title, target: self, action: action)
        checkbox.translatesAutoresizingMaskIntoConstraints = false
        let hintLabel = makeHintLabel(hint)

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

    private func makeHintLabel(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = NSFont.systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    /// A hint-styled bulleted list, one item per line, with wrapped lines indented under the text.
    private func makeBulletListLabel(_ items: [String]) -> NSTextField {
        let indent: CGFloat = 12
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
        paragraph.headIndent = indent
        paragraph.paragraphSpacing = 4
        let label = makeHintLabel("")
        label.attributedStringValue = NSAttributedString(
            string: items.map { "•\t\($0)" }.joined(separator: "\n"),
            attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph,
            ]
        )
        return label
    }

    /// A monospaced, selectable line (a path or a Terminal command) so it can be copied.
    private func makeMonospacedLabel(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.isSelectable = true
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    /// Shortcuts may have been rebound since the tab was last shown.
    override func viewWillAppear() {
        super.viewWillAppear()
        syncControls()
    }

    @objc private func logFileToggled(_ sender: NSButton) {
        let enabled = sender.state == .on
        AppController.shared.setLogFileEnabledFromSettings(enabled)
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
        logFileCheckbox?.state = AppController.shared.isLogFileEnabledInSettings ? .on : .off
        dockOverlayCheckbox?.state = AppController.shared.isDockMenusDebugOverlayEnabledInSettings ? .on : .off
        fullScreenOverlayCheckbox?.state = AppController.shared.isFullScreenDebugOverlayEnabledInSettings ? .on : .off
        showPassThroughHolesCheckbox?.state = AppController.shared.isShowPlaceholderPassThroughHolesInSettings ? .on : .off
        disablePrePositionCheckbox?.state = AppController.shared.isDisablePrePositionBeforeUnminimizeInSettings ? .on : .off
        disableNativeTabsCheckbox?.state = AppController.shared.isNativeTabHandlingDisabledInSettings ? .on : .off
        highlightImplicitFloatingTargetCheckbox?.state = AppController.shared.isHighlightImplicitFloatingTargetInSettings ? .on : .off
        timeTravelHintLabel?.stringValue =
            "Time-travel log capture uses \(KeyboardShortcutPreferences.shared.keyPhrase(for: .captureTimeTravelLogs)) (settable in Shortcuts). " +
            "It saves the full log (all levels) for the last \(Int(TimeTravelLogCapture.window)) seconds, or since the previous capture."
    }
}
