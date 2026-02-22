import AppKit

/// Manages draggable resize handles between zones for adjusting zone layout ratios.
struct ZoneSeparatorDescriptor {
    let screenId: CGDirectDisplayID
    let index: Int
    let orientation: ZoneLayout.SeparatorOrientation
    let frame: CGRect // Screen-local coordinates
    let screenCocoaBounds: CGRect // Screen's Cocoa bounds for coordinate conversion
}

protocol ZoneResizeHandleManagerDelegate: AnyObject {
    func resizeHandleDragBegan(screenId: CGDirectDisplayID, separatorIndex: Int)
    func resizeHandleDragged(screenId: CGDirectDisplayID, separatorIndex: Int, delta: CGPoint)
    func resizeHandleDragEnded(screenId: CGDirectDisplayID, separatorIndex: Int)
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
        let separatorIndex: Int
        let orientation: ZoneLayout.SeparatorOrientation

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
        private var syncTimer: Timer?

        init(frame frameRect: NSRect, screenId: CGDirectDisplayID, index: Int, orientation: ZoneLayout.SeparatorOrientation, dragOverlay: ZoneResizeDragOverlay) {
            self.screenId = screenId
            self.separatorIndex = index
            self.orientation = orientation
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

            // Show the drag overlay at the handle window's current Cocoa frame.
            // The overlay provides smooth visual tracking independent of layout work.
            if let handleWindow = window {
                dragOverlay.show(cocoaFrame: handleWindow.frame, orientation: orientation)
                suppressBarDrawing = true
            }
            needsDisplay = true
        }

        override func mouseUp(with event: NSEvent) {
            // Stop the throttle timer and flush any remaining accumulated delta
            // so the final layout exactly matches the overlay position.
            syncTimer?.invalidate()
            syncTimer = nil
            if pendingDelta.x != 0 || pendingDelta.y != 0 {
                let delta = pendingDelta
                pendingDelta = .zero
                delegate?.resizeHandleDragged(screenId: screenId, separatorIndex: separatorIndex, delta: delta)
            }

            // Clean up all drag state BEFORE notifying delegate, so the full
            // sync triggered by dragEnded can freely reposition this handle.
            let hadActiveResizeDrag = hasActiveResizeDrag
            hasActiveResizeDrag = false
            HandleView.activeDragView = nil
            isDragging = false
            dragOverlay.hide()
            suppressBarDrawing = false
            needsDisplay = true

            if hadActiveResizeDrag {
                delegate?.resizeHandleDragEnded(screenId: screenId, separatorIndex: separatorIndex)
            }
        }

        override func mouseDragged(with event: NSEvent) {
            if !hasActiveResizeDrag {
                hasActiveResizeDrag = true
                delegate?.resizeHandleDragBegan(screenId: screenId, separatorIndex: separatorIndex)
            }

            isDragging = true

            // Move the drag overlay immediately for smooth visual tracking.
            // NSEvent deltaY follows screen/CGEvent convention: positive = downward.
            // Cocoa window Y is inverted: positive = upward. Negate to match.
            dragOverlay.moveByDelta(dx: event.deltaX, dy: -event.deltaY)

            // Accumulate deltas. A repeating timer (~20Hz) drains the accumulated
            // delta into the delegate, keeping the main thread free between ticks
            // so mouse events and overlay moves stay responsive.
            pendingDelta.x += event.deltaX
            pendingDelta.y += event.deltaY

            if syncTimer == nil {
                let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
                    guard let self = self else { return }
                    let delta = self.pendingDelta
                    guard delta.x != 0 || delta.y != 0 else { return }
                    self.pendingDelta = .zero
                    self.delegate?.resizeHandleDragged(
                        screenId: self.screenId,
                        separatorIndex: self.separatorIndex,
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
            let key = "\(descriptor.screenId)-\(descriptor.index)"
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
            let view = HandleView(frame: NSRect(origin: .zero, size: cocoaFrame.size), screenId: descriptor.screenId, index: descriptor.index, orientation: descriptor.orientation, dragOverlay: dragOverlay)
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
