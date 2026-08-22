/// WinShot chooser thumbnail drags: highlights the display under the cursor and opens the dragged
/// snapshot's arrangement there on drop, so an arrangement can be dragged to another display.
import AppKit

extension AppController {
    func chooserControllerDidBeginDrag(_ controller: WinShotChooserController) {
        setWinShotDragPassthrough(true)
    }

    func chooserControllerDidUpdateDrag(_ controller: WinShotChooserController, cursorPointAX: CGPoint?) {
        // The snapshot can disappear mid-drag (a window in it closed, the per-display limit trimmed
        // it); with nothing left to drop, abandon the drag rather than keep highlighting a target.
        guard let snapshotId = controller.draggedSnapshotId,
              winShotManager.snapshot(withId: snapshotId) != nil else {
            controller.cancelThumbnailDrag(reason: "snapshot-removed")
            return
        }
        guard let screenId = winShotDropScreenId(containing: cursorPointAX),
              let descriptor = descriptor(for: screenId) else {
            winShotDragOverlayManager.present(over: [])
            return
        }
        // One overlay over the display's visible bounds, in the style of the zone overlays shown
        // during window drags. The manager keys overlays by zone, so the display borrows a key with
        // the (never used) zone index 0.
        winShotDragOverlayManager.present(over: [
            ZoneOverlayDescriptor(
                key: ZoneKey(screenId: screenId, index: 0),
                cocoaFrame: descriptor.visibleCocoaBounds,
                isEmpty: false
            ),
        ])
    }

    func chooserController(
        _ controller: WinShotChooserController,
        didEndDragOf snapshotId: UUID,
        cursorPointAX: CGPoint?
    ) -> Bool {
        endWinShotDragFeedback()

        guard let snapshot = winShotManager.snapshot(withId: snapshotId) else {
            Logger.debug("WinShot: Dragged snapshot \(snapshotId) not found")
            return false
        }
        guard let screenId = winShotDropScreenId(containing: cursorPointAX) else {
            Logger.debug("WinShot: Drag dropped outside any display that can take the arrangement")
            return false
        }

        Logger.debug("WinShot: Drag dropped on \(screenContextStore.logDescription(for: screenId))")
        openWinShotSnapshot(snapshot, on: screenId, reason: "winshot-chooser-drag")
        return true
    }

    func chooserControllerDidCancelDrag(_ controller: WinShotChooserController) {
        endWinShotDragFeedback()
    }

    func chooserCurrentCursorAccessibilityPoint() -> CGPoint? {
        currentCursorAccessibilityPoint()
    }

    private func endWinShotDragFeedback() {
        winShotDragOverlayManager.tearDown()
        setWinShotDragPassthrough(false)
    }

    /// While a thumbnail is in flight, the edge pills and zone resize bars pass the cursor through,
    /// so they neither light up under it nor suggest they could take the drop: only a display can.
    /// (An unmanaged-window edge drag toggles the pills' pass-through too; it never coincides with
    /// this one, since no edge-drag candidate starts while the chooser is open or dragging.)
    private func setWinShotDragPassthrough(_ enabled: Bool) {
        addZoneIndicatorManager.setMousePassthrough(enabled)
        floatingIndicatorManager.setMousePassthrough(enabled)
        resizeHandleManager.setMousePassthrough(enabled)
    }

    /// The display under `cursorPointAX` that a dragged arrangement can open on: any display not
    /// paused for a full-screen Space (the chooser's own display included).
    private func winShotDropScreenId(containing cursorPointAX: CGPoint?) -> CGDirectDisplayID? {
        guard let cursorPointAX,
              let screenId = screenId(containingAccessibilityPoint: cursorPointAX),
              !isScreenPausedForFullScreen(screenId) else {
            return nil
        }
        return screenId
    }
}
