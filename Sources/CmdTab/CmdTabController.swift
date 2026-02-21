/// Coordinates the CmdTab window switcher UI and window activation

import AppKit
import SwiftUI

protocol CmdTabControllerDelegate: AnyObject {
    /// Called when a window is selected from the CmdTab list
    func cmdTabController(_ controller: CmdTabController, didSelectWindow window: LauncherWindowItem)

    /// Called when CmdTab is dismissed without selection
    func cmdTabControllerDidDismiss(_ controller: CmdTabController)

    /// Returns the frame of the targeted zone in screen coordinates, and its screen descriptor
    func targetedZoneFrame() -> (CGRect, ScreenDescriptor)?

    /// Returns the screen ID for the targeted zone (for fallback centering)
    func targetedScreenId() -> CGDirectDisplayID?

    /// Provides all managed windows ordered by last active time
    func allManagedWindowsOrderedByRecency() -> [LauncherWindowItem]

    /// Returns the window ID of the currently frontmost managed window, or nil if none.
    /// Used to determine whether to start selection at index 0 or 1.
    func frontmostManagedWindowId() -> Int?
}

final class CmdTabController {
    weak var delegate: CmdTabControllerDelegate?

    private var window: CmdTabWindow?
    private var model: CmdTabModel?
    private var hostingView: NSHostingView<CmdTabView>?
    private var clickMonitor: ClickOutsideMonitor?

    private(set) var isActive = false

    enum InitialSelection {
        case mostRecent
        case leastRecent
    }

    enum AppFilter {
        case allWindows
        case app(bundleId: String, name: String)
        case noWindows  // Used when frontmost app has no bundle ID
    }

    @discardableResult
    func show(initialSelection: InitialSelection = .mostRecent, appFilter: AppFilter = .allWindows) -> Bool {
        guard let delegate = delegate else {
            Logger.debug("CmdTab: Cannot show - no delegate")
            return false
        }

        // Get all windows ordered by recency
        var allWindows = delegate.allManagedWindowsOrderedByRecency()

        // Determine header text, filter windows, and set wrap behavior
        let headerText: String
        let wrapsAround: Bool
        switch appFilter {
        case .allWindows:
            headerText = "Switch Windows"
            wrapsAround = false
        case .app(let bundleId, let name):
            allWindows = allWindows.filter { $0.bundleIdentifier == bundleId }
            headerText = "\(name) Windows"
            wrapsAround = true
        case .noWindows:
            allWindows = []
            headerText = "Switch Windows"
            wrapsAround = false
        }

        // Show UI even if empty (will display empty state)
        let model = CmdTabModel(windows: allWindows, wrapsAround: wrapsAround)
        self.model = model

        if !allWindows.isEmpty {
            switch initialSelection {
            case .mostRecent:
                // If the frontmost window is managed and is the first entry, start at index 1 (previous window).
                // Otherwise start at index 0 (no frontmost managed window, or it's not in the list).
                if let frontmostId = delegate.frontmostManagedWindowId(),
                   allWindows.first?.managedWindowId == frontmostId {
                    model.selectedIndex = min(1, allWindows.count - 1)
                } else {
                    model.selectedIndex = 0
                }
            case .leastRecent:
                model.selectedIndex = max(0, allWindows.count - 1)
            }
        }

        // Create window if needed
        if window == nil {
            window = CmdTabWindow()
        }

        // Create the SwiftUI view
        let cmdTabView = CmdTabView(
            model: model,
            headerText: headerText,
            onActivateSelected: { [weak self] in self?.activateSelectedWindow() }
        )

        let hostingView = NSHostingView(rootView: cmdTabView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        self.hostingView = hostingView

        // Add hosting view to the visual effect view
        if let visualEffectView = window?.visualEffectView {
            visualEffectView.subviews.forEach { $0.removeFromSuperview() }
            visualEffectView.addSubview(hostingView)
            NSLayoutConstraint.activate([
                hostingView.leadingAnchor.constraint(equalTo: visualEffectView.leadingAnchor),
                hostingView.trailingAnchor.constraint(equalTo: visualEffectView.trailingAnchor),
                hostingView.topAnchor.constraint(equalTo: visualEffectView.topAnchor),
                hostingView.bottomAnchor.constraint(equalTo: visualEffectView.bottomAnchor),
            ])
        }

        // Position window on targeted zone or center on screen
        if let (zoneFrame, descriptor) = delegate.targetedZoneFrame() {
            window?.centerOnZone(frame: zoneFrame, screenDescriptor: descriptor)
        } else if let screenId = delegate.targetedScreenId() {
            window?.centerOnScreen(screenId, forTemporaryZone: true)
        } else {
            window?.center()
        }

        window?.makeKeyAndOrderFront(nil)

        startClickMonitor()

        isActive = true
        Logger.debug("CmdTab: Opened with \(model.windows.count) windows")
        return true
    }

    func hide() {
        stopClickMonitor()

        window?.orderOut(nil)
        hostingView = nil
        model = nil

        isActive = false
        Logger.debug("CmdTab: Closed")

        delegate?.cmdTabControllerDidDismiss(self)
    }

    /// Activates the currently selected window and dismisses CmdTab
    func activateSelectedWindow() {
        guard let model = model,
              let selectedWindow = model.selectedWindow else {
            hide()
            return
        }

        hide()

        // Notify delegate
        delegate?.cmdTabController(self, didSelectWindow: selectedWindow)
    }

    /// Move selection to next window in the list
    func selectNext() {
        model?.selectNext()
    }

    /// Move selection to previous window in the list
    func selectPrevious() {
        model?.selectPrevious()
    }

    // MARK: - Click Outside Monitoring

    private func startClickMonitor() {
        guard let window = window else { return }
        let monitor = ClickOutsideMonitor(window: window, mode: .includeOwnApp) { [weak self] in
            guard let self, self.isActive else { return }
            self.hide()
        }
        monitor.start()
        clickMonitor = monitor
    }

    private func stopClickMonitor() {
        clickMonitor?.stop()
        clickMonitor = nil
    }
}
