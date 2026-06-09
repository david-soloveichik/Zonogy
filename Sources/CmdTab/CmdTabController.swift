/// Coordinates the CmdTab window switcher UI and window activation

import AppKit
import SwiftUI

protocol CmdTabControllerDelegate: AnyObject {
    /// Called when CmdTab dismisses, with the final outcome for the session.
    func cmdTabController(_ controller: CmdTabController, didDismiss outcome: CmdTabController.DismissalOutcome)

    /// Returns the frame of the targeted zone in screen coordinates, and its screen descriptor
    func targetedZoneFrame() -> (CGRect, ScreenDescriptor)?

    /// Returns the screen ID for the targeted zone (for fallback centering)
    func targetedScreenId() -> CGDirectDisplayID?

    /// Provides all managed windows ordered by last active time
    func allManagedWindowsOrderedByRecency() -> [LauncherWindowItem]

    /// Returns the window ID of the currently frontmost managed window, or nil if none.
    /// Used to determine whether to start selection at index 0 or 1.
    func frontmostManagedWindowId() -> Int?

    /// Starts a CmdTab row drag session for the given window. Return false to abort the drag.
    func cmdTabController(_ controller: CmdTabController, beginDragForWindow window: LauncherWindowItem) -> Bool

    /// Called repeatedly during a CmdTab row drag session as the cursor moves.
    func cmdTabControllerDidUpdateDrag(_ controller: CmdTabController, cursorPointAX: CGPoint?)

    /// Called when a CmdTab row drag session ends. Returns true if the drop resolved successfully.
    func cmdTabController(_ controller: CmdTabController, didEndDragForWindow window: LauncherWindowItem, cursorPointAX: CGPoint?) -> Bool

    /// Called when the user cancels an in-flight CmdTab row drag (e.g., by pressing Escape).
    /// The delegate should tear down any cursor-driven drag session it owns.
    func cmdTabControllerDidCancelDrag(_ controller: CmdTabController)

    /// Returns the current cursor point in accessibility coordinates.
    func cmdTabCurrentCursorAccessibilityPoint() -> CGPoint?
}

final class CmdTabController {
    enum DismissalOutcome {
        case cancelled
        case selected(LauncherWindowItem)
        case interrupted
        case dragResolved
        case openedNewWindow
    }

    weak var delegate: CmdTabControllerDelegate?

    private var window: CmdTabWindow?
    private var model: CmdTabModel?
    private var hostingView: NSHostingView<CmdTabView>?
    private lazy var rowDragController = CursorDrivenRowDragController<LauncherWindowItem>(
        logPrefix: "CmdTab",
        currentCursorAXProvider: { [weak self] in
            self?.delegate?.cmdTabCurrentCursorAccessibilityPoint()
        },
        onDidBeginDrag: { _ in },
        onDidUpdateDrag: { [weak self] cursorPointAX in
            guard let self else { return }
            self.delegate?.cmdTabControllerDidUpdateDrag(self, cursorPointAX: cursorPointAX)
        },
        onDidEndDrag: { [weak self] window, cursorPointAX in
            guard let self else { return }
            let didResolveDrop = self.delegate?.cmdTabController(self, didEndDragForWindow: window, cursorPointAX: cursorPointAX) ?? false
            self.completeRowDrag(didResolveDrop: didResolveDrop)
        },
        onDidCancelByUser: { [weak self] _ in
            guard let self else { return }
            self.delegate?.cmdTabControllerDidCancelDrag(self)
            self.completeRowDrag(didResolveDrop: false)
        }
    )

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
            onActivateSelected: { [weak self] in self?.activateSelectedWindow() },
            onBeginDrag: { [weak self] window in self?.beginDrag(for: window) }
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

        positionWindowOnCurrentTarget()
        window?.makeKeyAndOrderFront(nil)

        isActive = true
        Logger.debug("CmdTab: Opened with \(model.windows.count) windows")
        return true
    }

    func repositionToCurrentTarget() {
        guard isActive else {
            return
        }
        positionWindowOnCurrentTarget()
    }

    private func positionWindowOnCurrentTarget() {
        guard let delegate = delegate else { return }
        if let (zoneFrame, descriptor) = delegate.targetedZoneFrame() {
            window?.centerOnZone(frame: zoneFrame, screenDescriptor: descriptor)
        } else if let screenId = delegate.targetedScreenId() {
            window?.centerOnScreen(screenId, forFloatingZone: true)
        } else {
            window?.center()
        }
    }

    func cancel() {
        completeDismissal(with: .cancelled)
    }

    /// Dismiss CmdTab because a new window is being opened in the current app. Commits any
    /// open-time retarget so the new window lands in the targeted zone.
    func dismissForNewWindow() {
        completeDismissal(with: .openedNewWindow)
    }

    func hideForExternalInterruption() {
        completeDismissal(with: .interrupted)
    }

    private func completeDismissal(with outcome: DismissalOutcome) {
        guard isActive else {
            return
        }

        tearDownVisibleCmdTabUI()
        Logger.debug("CmdTab: Closed")
        delegate?.cmdTabController(self, didDismiss: outcome)
    }

    private func tearDownVisibleCmdTabUI() {
        window?.orderOut(nil)
        hostingView = nil
        model = nil

        isActive = false
    }

    private func beginDrag(for window: LauncherWindowItem) {
        guard isActive,
              let delegate,
              delegate.cmdTabController(self, beginDragForWindow: window) else {
            return
        }

        tearDownVisibleCmdTabUI()
        Logger.debug("CmdTab: Closed for drag")

        rowDragController.beginDrag(
            for: window,
            title: window.title,
            initialCursorPointCocoa: NSEvent.mouseLocation,
            driveViaMouseMonitors: true
        )
    }

    private func completeRowDrag(didResolveDrop: Bool) {
        if didResolveDrop {
            Logger.debug("CmdTab: Drag completed")
            delegate?.cmdTabController(self, didDismiss: .dragResolved)
            return
        }

        Logger.debug("CmdTab: Drag cancelled")
        delegate?.cmdTabController(self, didDismiss: .cancelled)
    }

    /// Activates the currently selected window and dismisses CmdTab
    func activateSelectedWindow() {
        guard let model = model,
              let selectedWindow = model.selectedWindow else {
            cancel()
            return
        }

        completeDismissal(with: .selected(selectedWindow))
    }

    /// Move selection to next window in the list
    func selectNext() {
        model?.selectNext()
    }

    /// Move selection to previous window in the list
    func selectPrevious() {
        model?.selectPrevious()
    }
}
