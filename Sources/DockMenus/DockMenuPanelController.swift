/// Manages DockMenu panel lifecycle, positioning, and user interactions.

import AppKit
import SwiftUI

/// Delegate for DockMenuPanelController to report actions.
protocol DockMenuPanelControllerDelegate: AnyObject {
    func dockMenuPanelController(_ controller: DockMenuPanelController, didSelectWindow window: LauncherWindowItem)
    func dockMenuPanelControllerDidSelectAppHeader(_ controller: DockMenuPanelController, bundleIdentifier: String)
    func dockMenuPanelControllerCursorExitedPanel(_ controller: DockMenuPanelController)
    func dockMenuPanelControllerCursorEnteredPanel(_ controller: DockMenuPanelController)
}

/// Controls the DockMenu floating panel display and interaction.
final class DockMenuPanelController: NSObject {
    weak var delegate: DockMenuPanelControllerDelegate?

    private var panel: DockMenuPanel?
    private var hostingView: NSHostingView<DockMenuView>?
    private var viewModel: DockMenuViewModel?
    private var mouseMonitor: Any?
    private var cursorInsidePanel: Bool = false
    private var currentBundleIdentifier: String?

    /// Whether the panel is currently visible.
    var isVisible: Bool {
        panel?.isVisible ?? false
    }

    /// Show the DockMenu panel for the given hover event.
    func show(for event: DockMenuHoverEvent, windows: [LauncherWindowItem]) {
        Logger.debug("DockMenuPanelController: show for \(event.appURL.lastPathComponent) with \(windows.count) windows")

        currentBundleIdentifier = event.bundleIdentifier

        // Create or reuse panel
        let panel: DockMenuPanel
        if let existingPanel = self.panel {
            panel = existingPanel
        } else {
            panel = DockMenuPanel()
            self.panel = panel
        }

        // Set up view model
        let viewModel = DockMenuViewModel()
        viewModel.appName = event.appURL.deletingPathExtension().lastPathComponent
        viewModel.appIcon = loadAppIcon(for: event.appURL)
        viewModel.windows = windows

        viewModel.onWindowSelected = { [weak self] window in
            guard let self else { return }
            Logger.debug("DockMenuPanelController: window selected \(window.title)")
            self.delegate?.dockMenuPanelController(self, didSelectWindow: window)
        }

        viewModel.onAppHeaderSelected = { [weak self] in
            guard let self, let bundleId = self.currentBundleIdentifier else { return }
            Logger.debug("DockMenuPanelController: app header selected")
            self.delegate?.dockMenuPanelControllerDidSelectAppHeader(self, bundleIdentifier: bundleId)
        }

        self.viewModel = viewModel

        // Create SwiftUI view
        let dockMenuView = DockMenuView(viewModel: viewModel)
        let hostingView = NSHostingView(rootView: dockMenuView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false

        // Add to panel's visual effect view
        if let visualEffectView = panel.visualEffectView {
            // Remove old hosting view
            self.hostingView?.removeFromSuperview()

            visualEffectView.addSubview(hostingView)
            NSLayoutConstraint.activate([
                hostingView.leadingAnchor.constraint(equalTo: visualEffectView.leadingAnchor),
                hostingView.trailingAnchor.constraint(equalTo: visualEffectView.trailingAnchor),
                hostingView.topAnchor.constraint(equalTo: visualEffectView.topAnchor),
                hostingView.bottomAnchor.constraint(equalTo: visualEffectView.bottomAnchor),
            ])

            self.hostingView = hostingView
        }

        // Calculate panel size based on content
        let contentHeight = calculateContentHeight(windowCount: windows.count)
        panel.setContentSize(NSSize(width: 300, height: contentHeight))

        // Position panel adjacent to Dock item
        let screenBounds = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
        panel.positionAdjacentTo(
            itemFrame: event.itemFrame,
            orientation: event.dockOrientation,
            screenBounds: screenBounds
        )

        // Set up mouse tracking for panel
        setupMouseTracking()

        // Show panel with fade-in
        panel.alphaValue = 0
        panel.orderFront(nil)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = 1
        }
    }

    /// Hide the DockMenu panel.
    func hide() {
        guard let panel else { return }

        Logger.debug("DockMenuPanelController: hide")

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.1
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            panel.orderOut(nil)
            self?.removeMouseTracking()
        })
    }

    // MARK: - Private

    private func loadAppIcon(for appURL: URL) -> NSImage? {
        return NSWorkspace.shared.icon(forFile: appURL.path)
    }

    private func calculateContentHeight(windowCount: Int) -> CGFloat {
        // Header (22px icon + 12px padding + 3px divider area): ~37pt
        // Each window row (20px icon + 10px padding): ~30pt, plus 2px spacing
        // Top padding on outer VStack: 6pt, inner scroll: 2pt
        let headerHeight: CGFloat = 40
        let rowHeight: CGFloat = 32
        let topPadding: CGFloat = 8
        let maxHeight: CGFloat = 400

        if windowCount == 0 {
            return headerHeight + topPadding
        }

        let contentHeight = headerHeight + CGFloat(windowCount) * rowHeight + topPadding
        return min(contentHeight, maxHeight)
    }

    private func setupMouseTracking() {
        removeMouseTracking()

        // Use a local event monitor instead of NSTrackingArea because SwiftUI's
        // NSHostingView intercepts tracking area events internally.
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            self?.handleMouseMoved()
            return event
        }

        // Check initial cursor position
        handleMouseMoved()
    }

    private func removeMouseTracking() {
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
        }
        mouseMonitor = nil
        cursorInsidePanel = false
    }

    private func handleMouseMoved() {
        guard let panel, panel.isVisible else { return }

        let mouseLocation = NSEvent.mouseLocation
        let isInside = panel.frame.contains(mouseLocation)

        if isInside != cursorInsidePanel {
            cursorInsidePanel = isInside
            if isInside {
                Logger.debug("DockMenuPanelController: cursor entered panel")
                delegate?.dockMenuPanelControllerCursorEnteredPanel(self)
            } else {
                Logger.debug("DockMenuPanelController: cursor exited panel")
                delegate?.dockMenuPanelControllerCursorExitedPanel(self)
            }
        }
    }
}
