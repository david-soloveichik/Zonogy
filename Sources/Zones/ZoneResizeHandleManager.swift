import AppKit

/// Manages draggable resize handles between zones for adjusting zone layout ratios.
struct ZoneSeparatorDescriptor {
    let screenId: CGDirectDisplayID
    let id: ZoneLayout.SeparatorIdentity
    let frame: CGRect // Screen-local coordinates
    let screenCocoaBounds: CGRect // Screen's Cocoa bounds for coordinate conversion

    var orientation: ZoneLayout.SeparatorOrientation { id.orientation }
}

protocol ZoneResizeHandleManagerDelegate: AnyObject {
    func resizeHandleDragBegan(screenId: CGDirectDisplayID, separatorId: ZoneLayout.SeparatorIdentity)
    func resizeHandleDragged(screenId: CGDirectDisplayID, separatorId: ZoneLayout.SeparatorIdentity, delta: CGPoint)
    func resizeHandleDragEnded(screenId: CGDirectDisplayID, separatorId: ZoneLayout.SeparatorIdentity)
    /// Returns true when the previous resize sync's AX writes are still in flight,
    /// allowing the caller to skip a tick and let delta accumulate.
    func isResizeHandleSyncBusy() -> Bool
}

final class ZoneResizeHandleManager {
    private final class HandleWindow: NSPanel {
        init(frame: NSRect) {
            super.init(
                contentRect: frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            isReleasedWhenClosed = false
            isFloatingPanel = true
            becomesKeyOnlyIfNeeded = false
            ignoresMouseEvents = false
            isOpaque = false
            hasShadow = false
            backgroundColor = .clear
            level = .floating
            collectionBehavior = [
                .moveToActiveSpace,
                .transient,
                .ignoresCycle,
                .fullScreenAuxiliary
            ]
        }

        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    private final class HandleView: NSView {
        weak var delegate: ZoneResizeHandleManagerDelegate?
        unowned let dragOverlay: ZoneResizeDragOverlay
        let screenId: CGDirectDisplayID
        let separatorId: ZoneLayout.SeparatorIdentity
        var orientation: ZoneLayout.SeparatorOrientation { separatorId.orientation }

        private var isHovering = false
        private var isDragging = false
        private var hasActiveResizeDrag = false
        /// When true, the overlay is drawing the bar — suppress local drawing to avoid a double bar.
        private var suppressBarDrawing = false
        fileprivate static weak var activeDragView: HandleView?

        /// Accumulated delta and throttle timer for heavy layout work.
        /// The timer fires at a fixed interval (~20Hz) so the main thread stays
        /// free between ticks for processing mouse events and overlay moves.
        private var pendingDelta: CGPoint = .zero
        /// Unapplied drag delta in Cocoa coordinates (y up).
        ///
        /// When the overlay is clamped at the minimum/maximum zone size, the cursor can
        /// continue moving while the bar is pinned. This "overshoot" is stored here so
        /// reversing direction first consumes the overshoot (re-acquiring the bar) before
        /// the overlay starts moving again.
        private var uncommittedCocoaDelta: CGPoint = .zero
        private var syncTimer: Timer?

        init(frame frameRect: NSRect, screenId: CGDirectDisplayID, separatorId: ZoneLayout.SeparatorIdentity, dragOverlay: ZoneResizeDragOverlay) {
            self.screenId = screenId
            self.separatorId = separatorId
            self.dragOverlay = dragOverlay
            super.init(frame: frameRect)
            wantsLayer = true
            ForceClickSuppression.apply(to: self)
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        /// Force-reset all drag state for teardown or abnormal cleanup.
        func resetDragState() {
            syncTimer?.invalidate()
            syncTimer = nil
            pendingDelta = .zero
            uncommittedCocoaDelta = .zero
            hasActiveResizeDrag = false
            if HandleView.activeDragView === self {
                HandleView.activeDragView = nil
            }
            isDragging = false
            suppressBarDrawing = false
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach { removeTrackingArea($0) }
            let options: NSTrackingArea.Options = [.activeAlways, .mouseEnteredAndExited, .cursorUpdate]
            addTrackingArea(NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil))
        }

        override func cursorUpdate(with event: NSEvent) {
            switch orientation {
            case .vertical:
                NSCursor.resizeLeftRight.set()
            case .horizontal:
                NSCursor.resizeUpDown.set()
            }
        }

        override func mouseEntered(with event: NSEvent) {
            // Prevent other handles from lighting up if a drag is in progress
            if let dragger = HandleView.activeDragView, dragger !== self {
                return
            }
            isHovering = true
            needsDisplay = true
        }

        override func mouseExited(with event: NSEvent) {
            isHovering = false
            needsDisplay = true
        }

        override func draw(_ dirtyRect: NSRect) {
            guard (isHovering || isDragging), !suppressBarDrawing else { return }
            ZoneResizeBarStyle.draw(in: bounds, orientation: orientation)
        }

        override func mouseDown(with event: NSEvent) {
            HandleView.activeDragView = self
            isDragging = true
            uncommittedCocoaDelta = .zero

            // Show the drag overlay at the handle window's current Cocoa frame.
            // The overlay provides smooth visual tracking independent of layout work.
            // Clamp to the zone layout's min/max ratio so the bar can't visually
            // exceed the minimum zone size.
            if let handleWindow = window {
                let movementRange = Self.overlayMovementRange(
                    orientation: orientation,
                    overlayFrame: handleWindow.frame,
                    screen: handleWindow.screen
                )
                dragOverlay.show(cocoaFrame: handleWindow.frame, orientation: orientation, movementRange: movementRange)
                suppressBarDrawing = true
            }
            needsDisplay = true
        }

        /// Compute the allowed overlay origin range on the movement axis from
        /// the screen's visible frame and ZoneLayout's min ratio constants.
        private static func overlayMovementRange(
            orientation: ZoneLayout.SeparatorOrientation,
            overlayFrame: CGRect,
            screen: NSScreen?
        ) -> ClosedRange<CGFloat> {
            guard let visibleFrame = screen?.visibleFrame else {
                return (-CGFloat.greatestFiniteMagnitude)...(CGFloat.greatestFiniteMagnitude)
            }
            switch orientation {
            case .vertical:
                let minRatio = ZoneLayout.minWidthRatio
                let halfWidth = overlayFrame.width / 2
                let minX = visibleFrame.minX + visibleFrame.width * minRatio - halfWidth
                let maxX = visibleFrame.minX + visibleFrame.width * (1 - minRatio) - halfWidth
                return minX...maxX
            case .horizontal:
                // In screen coords (y down), separator at ratio r is at visibleHeight * r.
                // In Cocoa coords (y up), that maps to visibleFrame.maxY - visibleHeight * r,
                // so a larger ratio = lower Cocoa Y.
                let minRatio = ZoneLayout.minHeightRatio
                let halfHeight = overlayFrame.height / 2
                let lowY = visibleFrame.maxY - visibleFrame.height * (1 - minRatio) - halfHeight
                let highY = visibleFrame.maxY - visibleFrame.height * minRatio - halfHeight
                return lowY...highY
            }
        }

        override func mouseUp(with event: NSEvent) {
            // Stop the throttle timer and flush any remaining accumulated delta
            // so the final layout exactly matches the overlay position.
            syncTimer?.invalidate()
            syncTimer = nil
            if pendingDelta.x != 0 || pendingDelta.y != 0 {
                let delta = pendingDelta
                pendingDelta = .zero
                delegate?.resizeHandleDragged(screenId: screenId, separatorId: separatorId, delta: delta)
            }

            // Clean up all drag state BEFORE notifying delegate, so the full
            // sync triggered by dragEnded can freely reposition this handle.
            let hadActiveResizeDrag = hasActiveResizeDrag
            hasActiveResizeDrag = false
            HandleView.activeDragView = nil
            isDragging = false
            uncommittedCocoaDelta = .zero
            dragOverlay.hide()
            suppressBarDrawing = false
            needsDisplay = true

            if hadActiveResizeDrag {
                delegate?.resizeHandleDragEnded(screenId: screenId, separatorId: separatorId)
            }
        }

        override func mouseDragged(with event: NSEvent) {
            if !hasActiveResizeDrag {
                hasActiveResizeDrag = true
                delegate?.resizeHandleDragBegan(screenId: screenId, separatorId: separatorId)
            }

            isDragging = true

            // Move the drag overlay immediately for smooth visual tracking.
            // NSEvent deltaY follows screen/CGEvent convention: positive = downward.
            // Cocoa window Y is inverted: positive = upward. Negate to match.
            //
            // Track overshoot beyond the clamp so the cursor can move past the limit
            // while the bar is pinned, then re-acquire the bar when reversing direction.
            switch orientation {
            case .vertical:
                uncommittedCocoaDelta.x += event.deltaX
            case .horizontal:
                uncommittedCocoaDelta.y += -event.deltaY
            }
            let applied = dragOverlay.moveByDelta(dx: uncommittedCocoaDelta.x, dy: uncommittedCocoaDelta.y)
            uncommittedCocoaDelta.x -= applied.x
            uncommittedCocoaDelta.y -= applied.y

            // Convert applied delta back from Cocoa to screen convention:
            // X is the same; Y is negated (Cocoa up → screen down).
            pendingDelta.x += applied.x
            pendingDelta.y += -applied.y

            if syncTimer == nil {
                let timer = Timer(timeInterval: 0.025, repeats: true) { [weak self] _ in
                    guard let self = self else { return }
                    let delta = self.pendingDelta
                    guard delta.x != 0 || delta.y != 0 else { return }
                    // Frame-skip: if the previous AX writes haven't finished,
                    // let delta accumulate so the next flush sends a larger jump
                    // instead of queuing up stale intermediate positions.
                    if self.delegate?.isResizeHandleSyncBusy() == true { return }
                    self.pendingDelta = .zero
                    self.delegate?.resizeHandleDragged(
                        screenId: self.screenId,
                        separatorId: self.separatorId,
                        delta: delta
                    )
                }
                // Schedule in .common modes so it fires during mouse-tracking.
                RunLoop.main.add(timer, forMode: .common)
                syncTimer = timer
            }
        }
    }

    private final class Handle {
        let window: HandleWindow
        let view: HandleView

        init(window: HandleWindow, view: HandleView) {
            self.window = window
            self.view = view
        }
    }

    weak var delegate: ZoneResizeHandleManagerDelegate?
    private let dragOverlay = ZoneResizeDragOverlay()
    private var handles: [String: Handle] = [:] // Key: "screenId-index"

    func present(over descriptors: [ZoneSeparatorDescriptor]) {
        var pendingRemoval = Set(handles.keys)

        for descriptor in descriptors {
            let key = "\(descriptor.screenId)-\(descriptor.id.logLabel)"
            // Convert screen-local frame to Cocoa frame for window
            // descriptor.frame is in screen-local coordinates (origin at screen's top-left, y down).
            // NSWindow needs Cocoa coordinates (origin at primary screen's bottom-left, y up).
            let cocoaFrame = CoordinateConversion.screenToCocoa(
                screenFrame: descriptor.frame,
                screenBounds: descriptor.screenCocoaBounds
            )

            if let handle = handles[key] {
                // While a drag is active on this handle, the overlay provides the
                // visual bar — skip repositioning to avoid layout-driven stutter.
                let isDragging = HandleView.activeDragView === handle.view
                if !isDragging, handle.window.frame != cocoaFrame {
                    handle.window.setFrame(cocoaFrame, display: true)
                    handle.view.setFrameSize(cocoaFrame.size)
                    handle.view.needsDisplay = true
                }
                handle.view.delegate = delegate
                handle.window.orderFrontRegardless()
                pendingRemoval.remove(key)
                continue
            }

            let window = HandleWindow(frame: cocoaFrame)
            let view = HandleView(frame: NSRect(origin: .zero, size: cocoaFrame.size), screenId: descriptor.screenId, separatorId: descriptor.id, dragOverlay: dragOverlay)
            view.delegate = delegate
            view.autoresizingMask = [.width, .height]
            window.contentView = view
            window.orderFrontRegardless()

            let handle = Handle(window: window, view: view)
            handles[key] = handle
            pendingRemoval.remove(key)
        }

        for key in pendingRemoval {
            if let handle = handles[key] {
                // Never close a handle mid-drag — the gesture owns it until mouse-up.
                if HandleView.activeDragView === handle.view {
                    continue
                }
                handles.removeValue(forKey: key)
                handle.window.orderOut(nil)
                handle.window.close()
            }
        }
    }

    func tearDown() {
        dragOverlay.hide()
        for handle in handles.values {
            handle.view.resetDragState()
            handle.window.orderOut(nil)
            handle.window.close()
        }
        handles.removeAll()
    }
}
