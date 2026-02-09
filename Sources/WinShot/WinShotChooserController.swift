/// Coordinates the WinShot chooser UI, key monitoring, and snapshot selection
import AppKit
import Carbon

protocol WinShotChooserControllerDelegate: AnyObject {
    /// Called when a snapshot is selected (by releasing modifiers)
    func chooserController(_ controller: WinShotChooserController, didSelect snapshotId: UUID)

    /// Called when a snapshot deletion is requested
    func chooserController(_ controller: WinShotChooserController, didRequestDelete snapshotId: UUID)

    /// Called when the chooser is cancelled (Escape or click outside)
    func chooserControllerDidCancel(_ controller: WinShotChooserController)
}

final class WinShotChooserController: WinShotModifierMonitorDelegate, WinShotChooserViewDelegate {
    weak var delegate: WinShotChooserControllerDelegate?

    private var window: WinShotChooserWindow?
    private var chooserView: WinShotChooserView?
    private let modifierMonitor = WinShotModifierMonitor()
    private var keyMonitor: Any?
    private var clickMonitor: Any?

    private(set) var isActive = false
    private(set) var currentScreenId: CGDirectDisplayID?

    init() {
        modifierMonitor.delegate = self
    }

    /// Show the chooser with the given snapshots on the specified screen
    func show(snapshots: [WinShotSnapshot], on screenId: CGDirectDisplayID) {
        guard !snapshots.isEmpty else {
            Logger.debug("WinShot: Cannot show chooser - no snapshots")
            return
        }

        currentScreenId = screenId

        // Create window if needed
        if window == nil {
            window = WinShotChooserWindow()
        }

        // Create chooser view
        let chooserView = WinShotChooserView(frame: .zero)
        chooserView.delegate = self
        chooserView.configure(with: snapshots)
        self.chooserView = chooserView

        // Size window based on content
        let windowSize = WinShotChooserView.preferredWindowSize(for: snapshots.count)
        window?.setContentSize(windowSize)
        chooserView.frame = NSRect(origin: .zero, size: windowSize)

        // Add chooserView as subview of the visual effect view (for proper rounded corner clipping)
        // The window structure is: contentView (container) -> visualEffectView -> chooserView
        if let contentView = window?.contentView,
           let visualEffectView = contentView.subviews.first as? NSVisualEffectView {
            // Remove any existing chooser subviews (from previous show calls)
            visualEffectView.subviews.forEach { $0.removeFromSuperview() }
            visualEffectView.addSubview(chooserView)
        }

        // Position window
        window?.centerOnScreen(screenId)
        window?.makeKeyAndOrderFront(nil)

        // Start monitors
        startKeyMonitor()
        startClickMonitor()
        modifierMonitor.start()

        isActive = true
        Logger.debug("WinShot: Chooser opened with \(snapshots.count) snapshot(s)")
    }

    /// Hide the chooser
    func hide() {
        stopKeyMonitor()
        stopClickMonitor()
        modifierMonitor.stop()

        window?.orderOut(nil)
        chooserView = nil

        isActive = false
        currentScreenId = nil
        Logger.debug("WinShot: Chooser closed")
    }

    /// Cycle to the next snapshot
    func cycleNext() {
        chooserView?.selectNext()
    }

    /// Cycle to the previous snapshot
    func cyclePrevious() {
        chooserView?.selectPrevious()
    }

    /// Select a specific snapshot index.
    func selectIndex(_ index: Int) {
        chooserView?.selectIndex(index)
    }

    /// Refresh the chooser with updated snapshots (called when snapshots change while chooser is open)
    func refreshSnapshots(_ snapshots: [WinShotSnapshot]) {
        guard isActive, let screenId = currentScreenId else { return }

        if snapshots.isEmpty {
            Logger.debug("WinShot: Closing chooser - no snapshots remaining")
            cancel()
            return
        }

        // Preserve the currently selected snapshot ID if it still exists
        let previousSelectedId = chooserView?.selectedSnapshotId

        // Reconfigure the view
        chooserView?.configure(with: snapshots)

        // Try to restore selection to the same snapshot, or stay at current index
        if let previousId = previousSelectedId,
           let newIndex = snapshots.firstIndex(where: { $0.id == previousId }) {
            chooserView?.selectIndex(newIndex)
        }

        // Resize window if snapshot count changed significantly
        let windowSize = WinShotChooserView.preferredWindowSize(for: snapshots.count)
        window?.setContentSize(windowSize)
        chooserView?.frame = NSRect(origin: .zero, size: windowSize)
        window?.centerOnScreen(screenId)

        Logger.debug("WinShot: Chooser refreshed with \(snapshots.count) snapshot(s)")
    }

    // MARK: - Key Monitoring

    private func startKeyMonitor() {
        guard keyMonitor == nil else { return }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.isActive else { return event }
            return self.handleKeyDown(event)
        }
    }

    private func stopKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }

    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        let keyCode = event.keyCode
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let hasControlCommand = flags.contains(.control) && flags.contains(.command)

        // Escape to cancel
        if keyCode == UInt16(kVK_Escape) {
            cancel()
            return nil
        }

        // Tab to cycle (while holding Control-Command)
        if keyCode == UInt16(kVK_Tab) && hasControlCommand {
            if flags.contains(.shift) {
                cyclePrevious()
            } else {
                cycleNext()
            }
            return nil
        }

        return event
    }

    // MARK: - Click Outside Monitoring

    private func startClickMonitor() {
        guard clickMonitor == nil else { return }

        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self = self, self.isActive else { return }

            // Check if click is outside the chooser window
            guard let window = self.window else { return }

            let screenLocation = NSEvent.mouseLocation
            let windowFrame = window.frame
            if !windowFrame.contains(screenLocation) {
                self.cancel()
            }
        }
    }

    private func stopClickMonitor() {
        if let monitor = clickMonitor {
            NSEvent.removeMonitor(monitor)
            clickMonitor = nil
        }
    }

    // MARK: - Actions

    private func cancel() {
        hide()
        delegate?.chooserControllerDidCancel(self)
    }

    private func confirmSelection() {
        guard let snapshotId = chooserView?.selectedSnapshotId else {
            cancel()
            return
        }

        // Hide the window first, then dispatch restoration asynchronously
        // so the window is fully off-screen before any screenshot capture
        // (e.g., for pre-restore snapshots)
        hide()
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.chooserController(self, didSelect: snapshotId)
        }
    }

    // MARK: - WinShotModifierMonitorDelegate

    func winShotModifierMonitorDidReleaseModifiers(_ monitor: WinShotModifierMonitor) {
        guard isActive else { return }
        confirmSelection()
    }

    // MARK: - WinShotChooserViewDelegate

    func chooserView(_ view: WinShotChooserView, didRequestDelete snapshotId: UUID) {
        delegate?.chooserController(self, didRequestDelete: snapshotId)

        // If no snapshots remain, close the chooser
        if view.snapshotCount <= 1 {
            cancel()
        }
    }

    func chooserView(_ view: WinShotChooserView, didSelect snapshotId: UUID) {
        // Click on snapshot triggers immediate restoration
        // Dispatch restoration asynchronously so the window hides immediately
        let snapshotIdToRestore = snapshotId
        hide()
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.delegate?.chooserController(self, didSelect: snapshotIdToRestore)
        }
    }

    deinit {
        hide()
    }
}
