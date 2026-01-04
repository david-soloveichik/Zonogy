/// Coordinates the AltTab window switcher UI and window activation

import AppKit
import SwiftUI

protocol AltTabControllerDelegate: AnyObject {
    /// Called when a window is selected from the AltTab list
    func altTabController(_ controller: AltTabController, didSelectWindow window: LauncherWindowItem)

    /// Called when AltTab is dismissed without selection
    func altTabControllerDidDismiss(_ controller: AltTabController)

    /// Returns the frame of the targeted zone in screen coordinates, and its screen descriptor
    func targetedZoneFrame() -> (CGRect, ScreenDescriptor)?

    /// Returns the screen ID for the targeted zone (for fallback centering)
    func targetedScreenId() -> CGDirectDisplayID?

    /// Provides all managed windows ordered by last active time
    func allManagedWindowsOrderedByRecency() -> [LauncherWindowItem]
}

final class AltTabController {
    weak var delegate: AltTabControllerDelegate?

    private var window: LauncherWindow?
    private var model: AltTabModel?
    private var hostingView: NSHostingView<AltTabView>?
    private var clickMonitor: Any?

    private(set) var isActive = false

    enum InitialSelection {
        case mostRecent
        case leastRecent
    }

    @discardableResult
    func show(initialSelection: InitialSelection = .mostRecent) -> Bool {
        guard let delegate = delegate else {
            Logger.debug("AltTab: Cannot show - no delegate")
            return false
        }

        // Get all windows ordered by recency
        let allWindows = delegate.allManagedWindowsOrderedByRecency()

        guard !allWindows.isEmpty else {
            Logger.debug("AltTab: No windows to show")
            return false
        }

        let model = AltTabModel(windows: allWindows)
        self.model = model

        switch initialSelection {
        case .mostRecent:
            // Start at index 1 (previous window) since index 0 is the currently active window
            model.selectedIndex = min(1, allWindows.count - 1)
        case .leastRecent:
            model.selectedIndex = max(0, allWindows.count - 1)
        }

        // Create window if needed
        if window == nil {
            window = LauncherWindow()
            // Adjust window size for AltTab (smaller than Launcher)
            window?.setContentSize(NSSize(width: 400, height: 350))
        }

        // Create the SwiftUI view
        let altTabView = AltTabView(
            model: model,
            onActivateSelected: { [weak self] in self?.activateSelectedWindow() }
        )

        let hostingView = NSHostingView(rootView: altTabView)
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
            window?.centerOnScreen(screenId)
        } else {
            window?.center()
        }

        window?.makeKeyAndOrderFront(nil)

        startClickMonitor()

        isActive = true
        Logger.debug("AltTab: Opened with \(model.windows.count) windows")
        return true
    }

    func hide() {
        stopClickMonitor()

        window?.orderOut(nil)
        hostingView = nil
        model = nil

        isActive = false
        Logger.debug("AltTab: Closed")

        delegate?.altTabControllerDidDismiss(self)
    }

    /// Activates the currently selected window and dismisses AltTab
    func activateSelectedWindow() {
        guard let model = model,
              let selectedWindow = model.selectedWindow else {
            hide()
            return
        }

        hide()

        // Notify delegate
        delegate?.altTabController(self, didSelectWindow: selectedWindow)
    }

    /// Move selection to next window in the list (wraps around)
    func selectNext() {
        model?.selectNext()
    }

    /// Move selection to previous window in the list (wraps around)
    func selectPrevious() {
        model?.selectPrevious()
    }

    // MARK: - Click Outside Monitoring

    private func startClickMonitor() {
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self = self, self.isActive else { return }

            // Check if click is outside our window
            if let window = self.window {
                let windowFrame = window.frame
                let screenPoint = NSEvent.mouseLocation

                if !windowFrame.contains(screenPoint) {
                    self.hide()
                }
            }
        }
    }

    private func stopClickMonitor() {
        if let monitor = clickMonitor {
            NSEvent.removeMonitor(monitor)
            clickMonitor = nil
        }
    }
}
