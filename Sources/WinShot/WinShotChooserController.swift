/// Coordinates the WinShot chooser UI, key monitoring, snapshot selection, and thumbnail drags
import AppKit
import Carbon

protocol WinShotChooserControllerDelegate: AnyObject {
    /// Called when a snapshot is selected (by releasing modifiers, or clicking it). `screenId` is the
    /// display the chooser was showing on, where the arrangement should open.
    func chooserController(_ controller: WinShotChooserController, didSelect snapshotId: UUID, on screenId: CGDirectDisplayID)

    /// Called when a snapshot deletion is requested
    func chooserController(_ controller: WinShotChooserController, didRequestDelete snapshotId: UUID)

    /// Called when the chooser is cancelled (Escape or click outside)
    func chooserControllerDidCancel(_ controller: WinShotChooserController)

    /// Called when a thumbnail drag starts (the chooser has already closed).
    func chooserControllerDidBeginDrag(_ controller: WinShotChooserController)

    /// Called repeatedly while a thumbnail drag is in flight, as the cursor moves.
    func chooserControllerDidUpdateDrag(_ controller: WinShotChooserController, cursorPointAX: CGPoint?)

    /// Called when a thumbnail drag ends. Returns true if the drop opened the snapshot.
    func chooserController(_ controller: WinShotChooserController, didEndDragOf snapshotId: UUID, cursorPointAX: CGPoint?) -> Bool

    /// Called when the user cancels an in-flight thumbnail drag (Escape).
    func chooserControllerDidCancelDrag(_ controller: WinShotChooserController)

    /// Current cursor position in Accessibility coordinates, for drag updates.
    func chooserCurrentCursorAccessibilityPoint() -> CGPoint?
}

final class WinShotChooserController: WinShotModifierMonitorDelegate, WinShotChooserViewDelegate {
    weak var delegate: WinShotChooserControllerDelegate?

    private var window: WinShotChooserWindow?
    private var chooserView: WinShotChooserView?
    /// The snapshots currently shown, newest first (for the thumbnail a drag carries).
    private var snapshots: [WinShotSnapshot] = []
    private let modifierMonitor = WinShotModifierMonitor()
    private var keyMonitor: Any?
    private var clickMonitor: ClickOutsideMonitor?

    /// Drives a thumbnail drag once the chooser has closed for it: the cursor-following preview,
    /// mouse tracking, and Escape-to-cancel.
    private lazy var thumbnailDragController = CursorDrivenRowDragController<UUID>(
        logPrefix: "WinShot",
        currentCursorAXProvider: { [weak self] in
            self?.delegate?.chooserCurrentCursorAccessibilityPoint()
        },
        onDidBeginDrag: { [weak self] _ in
            guard let self else { return }
            self.delegate?.chooserControllerDidBeginDrag(self)
        },
        onDidUpdateDrag: { [weak self] cursorPointAX in
            guard let self else { return }
            self.delegate?.chooserControllerDidUpdateDrag(self, cursorPointAX: cursorPointAX)
        },
        onDidEndDrag: { [weak self] snapshotId, cursorPointAX in
            guard let self else { return }
            let didOpen = self.delegate?.chooserController(self, didEndDragOf: snapshotId, cursorPointAX: cursorPointAX) ?? false
            Logger.debug(didOpen ? "WinShot: Drag completed" : "WinShot: Drag cancelled")
        },
        onDidCancelByUser: { [weak self] _ in
            guard let self else { return }
            self.delegate?.chooserControllerDidCancelDrag(self)
        }
    )

    /// Called on every `isActive` change, so the app can mirror chooser state where the keyboard
    /// event taps read it.
    var onActiveChanged: (() -> Void)?
    private(set) var isActive = false {
        didSet { onActiveChanged?() }
    }
    private(set) var currentScreenId: CGDirectDisplayID?

    /// The "Show WinShot Switcher" shortcut captured when the chooser opened, so cycling and
    /// confirm-on-release follow whatever the user configured (not a hardwired Control-Command-Tab).
    private var engagedShortcut: (keyCode: UInt16, modifiers: NSEvent.ModifierFlags)?

    init() {
        modifierMonitor.delegate = self
    }

    /// Show the chooser with the given snapshots on the specified screen
    func show(snapshots: [WinShotSnapshot], on screenId: CGDirectDisplayID) {
        guard !snapshots.isEmpty else {
            Logger.debug("WinShot: Cannot show chooser - no snapshots")
            return
        }
        guard !thumbnailDragController.isDragging else {
            Logger.debug("WinShot: Cannot show chooser - thumbnail drag in flight")
            return
        }

        currentScreenId = screenId
        self.snapshots = snapshots

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
        let screenVisibleWidth = visibleFrameWidth(for: screenId)
        let windowSize = WinShotChooserView.preferredWindowSize(
            for: snapshots,
            screenVisibleWidth: screenVisibleWidth
        )
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

        // Capture the configured shortcut so cycling and confirm-on-release use its key/modifiers.
        // If the action has been cleared there's no shortcut to drive them — the chooser can still
        // be dismissed by clicking a snapshot or pressing Escape. (Not reachable today: the chooser
        // only opens via the hotkey, which isn't registered while the action is cleared.)
        let shortcut = KeyboardShortcutPreferences.shared.shortcut(for: .showWinShotChooser)
        engagedShortcut = shortcut.map { (keyCode: UInt16($0.keyCode), modifiers: $0.nsEventModifierFlags) }

        // Start monitors
        startKeyMonitor()
        startClickMonitor()
        if let shortcut {
            modifierMonitor.start(requiredModifiers: shortcut.nsEventModifierFlags)
        }

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
        snapshots = []

        isActive = false
        currentScreenId = nil
        engagedShortcut = nil
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

        // Capture the selection before configure() resets it to 0, then restore it:
        // follow the same snapshot if it survived, otherwise hold the same strip
        // position (clamped) rather than jumping to the newest.
        let previousSelectedId = chooserView?.selectedSnapshotId
        let previousSelectedIndex = chooserView?.selectedThumbnailIndex

        self.snapshots = snapshots
        chooserView?.configure(with: snapshots)

        if let restoredIndex = WinShotChooserSelectionRestorePolicy.restoredSelectionIndex(
            previousSelectedId: previousSelectedId,
            previousSelectedIndex: previousSelectedIndex,
            newSnapshotIds: snapshots.map(\.id)
        ) {
            chooserView?.selectIndex(restoredIndex)
        }

        // Resize window to fit the updated snapshot set
        let screenVisibleWidth = visibleFrameWidth(for: screenId)
        let windowSize = WinShotChooserView.preferredWindowSize(
            for: snapshots,
            screenVisibleWidth: screenVisibleWidth
        )
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

        // Escape to cancel
        if keyCode == UInt16(kVK_Escape) {
            cancel()
            return nil
        }

        // Cycle on the configured shortcut key while its modifiers are held (Shift reverses,
        // unless the shortcut itself includes Shift — see WinShotChooserCyclePolicy).
        if let engaged = engagedShortcut,
           let direction = WinShotChooserCyclePolicy.cycleDirection(
               pressedKeyCode: keyCode,
               heldModifiers: flags,
               shortcutKeyCode: engaged.keyCode,
               shortcutModifiers: engaged.modifiers
           ) {
            switch direction {
            case .next:
                cycleNext()
            case .previous:
                cyclePrevious()
            }
            return nil
        }

        return event
    }

    // MARK: - Click Outside Monitoring

    private func startClickMonitor() {
        guard let window = window else { return }
        let monitor = ClickOutsideMonitor(window: window, mode: .includeOwnApp) { [weak self] in
            guard let self, self.isActive else { return }
            self.cancel()
        }
        monitor.start()
        clickMonitor = monitor
    }

    private func stopClickMonitor() {
        clickMonitor?.stop()
        clickMonitor = nil
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
        handOff(snapshotId)
    }

    /// Close the chooser and hand the snapshot to the delegate to open on the chooser's display.
    /// Hides the window first, then dispatches restoration asynchronously so the chooser is fully
    /// off-screen before restore-side window moves.
    private func handOff(_ snapshotId: UUID) {
        guard let screenId = currentScreenId else { return }
        hide()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.chooserController(self, didSelect: snapshotId, on: screenId)
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
        handOff(snapshotId)
    }

    /// A thumbnail is being dragged out: close the chooser (so releasing the shortcut's modifiers no
    /// longer restores anything; the drop decides) and let the drag carry the thumbnail to the display
    /// it will open on.
    func chooserView(_ view: WinShotChooserView, didBeginDrag snapshotId: UUID) {
        guard isActive, let snapshot = snapshots.first(where: { $0.id == snapshotId }) else { return }

        hide()
        Logger.debug("WinShot: Chooser closed for drag")

        thumbnailDragController.beginDrag(
            for: snapshotId,
            title: "Snapshot",
            image: snapshot.thumbnail,
            initialCursorPointCocoa: NSEvent.mouseLocation,
            driveViaMouseMonitors: true
        )
        // Highlight the starting display right away rather than on the first mouse move.
        thumbnailDragController.updateDrag()
    }

    /// The snapshot a thumbnail drag is carrying, if one is in flight.
    var draggedSnapshotId: UUID? {
        thumbnailDragController.activePayload
    }

    /// True from the chooser opening until it closes or, if a thumbnail is dragged out, until that
    /// drag ends. Mouse gestures that must not interleave with the chooser check this.
    var isActiveOrDragging: Bool {
        isActive || thumbnailDragController.isDragging
    }

    /// Abandons an in-flight thumbnail drag without dropping: for interruptions (sleep, lock) after
    /// which the mouse-up may never arrive, or when the snapshot it carries no longer exists.
    func cancelThumbnailDrag(reason: String) {
        guard thumbnailDragController.isDragging else { return }
        Logger.debug("WinShot: Thumbnail drag cancelled (reason: \(reason))")
        thumbnailDragController.cancelDrag()
        delegate?.chooserControllerDidCancelDrag(self)
    }

    deinit {
        hide()
    }

    private func visibleFrameWidth(for screenId: CGDirectDisplayID) -> CGFloat {
        guard let screen = NSScreen.screens.first(where: { screen in
            guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return false
            }
            return CGDirectDisplayID(screenNumber.uint32Value) == screenId
        }) else {
            return NSScreen.main?.visibleFrame.width ?? 0
        }

        return screen.visibleFrame.width
    }
}
