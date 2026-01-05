/// Manages DockMenu panel lifecycle, positioning, and user interactions.

import AppKit
import SwiftUI

/// Delegate for DockMenuPanelController to report actions.
protocol DockMenuPanelControllerDelegate: AnyObject {
    func dockMenuPanelController(_ controller: DockMenuPanelController, didSelectWindow window: LauncherWindowItem)
    func dockMenuPanelControllerDidSelectAppHeader(_ controller: DockMenuPanelController, bundleIdentifier: String)
    func dockMenuPanelController(_ controller: DockMenuPanelController, didBeginDragForWindow window: LauncherWindowItem)
}

/// Controls the DockMenu floating panel display and interaction.
final class DockMenuPanelController: NSObject {
    weak var delegate: DockMenuPanelControllerDelegate?

    private var panel: DockMenuPanel?
    private var hostingView: NSHostingView<DockMenuView>?
    private var viewModel: DockMenuViewModel?
    private var currentBundleIdentifier: String?

    /// Whether the panel is currently visible.
    var isVisible: Bool {
        panel?.isVisible ?? false
    }

    /// The panel's frame in Cocoa coordinates, or nil if not visible.
    var panelFrame: CGRect? {
        guard let panel, panel.isVisible else { return nil }
        return panel.frame
    }

    /// Show the DockMenu panel for the given hover event.
    /// - Parameters:
    ///   - event: The hover event containing item and list frames.
    ///   - windows: The app's managed windows to display.
    ///   - stableDockFrame: The stable Dock frame (where the Dock is when fully visible).
    func show(for event: DockMenuHoverEvent, windows: [LauncherWindowItem], stableDockFrame: CGRect) {
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

        viewModel.onWindowDragStart = { [weak self] window in
            guard let self else { return }
            Logger.debug("DockMenuPanelController: drag started for window \(window.title)")
            self.delegate?.dockMenuPanelController(self, didBeginDragForWindow: window)
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
            dockFrame: stableDockFrame,
            orientation: event.dockOrientation,
            screenBounds: screenBounds,
            hasWindows: !windows.isEmpty
        )

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
        }, completionHandler: {
            panel.orderOut(nil)
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

}
