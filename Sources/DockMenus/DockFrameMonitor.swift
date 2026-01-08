import Foundation
import AppKit
import ApplicationServices

/// Tracks Dock AXList frame changes and emits state updates.
final class DockFrameMonitor {
    struct State: Equatable {
        /// The AXFrame of the Dock's AXList element when AXSelectedChildrenChanged fires.
        var listFrame: CGRect?
        /// Whether the Dock is considered visible (vs hidden due to autohide).
        var isVisible: Bool = false
    }

    var onStateChange: ((State) -> Void)?

    /// Called when hover changes: a running app's Dock icon (event), or a non-running app/non-app item (nil).
    /// Note: nil does NOT reliably indicate cursor left the Dock. See SPECIFICATION-DOCKMENUS.md.
    var onAppHover: ((DockMenuHoverEvent?) -> Void)?

    private var lastState: State?
    private var axNotificationMonitor: DockAXNotificationMonitor?

    /// Cached frame from when the Dock was fully within the primary screen bounds.
    /// Used to handle autohide animation where the Dock reports an off-screen (or partially off-screen) frame.
    private var cachedVisibleFrame: CGRect?

    /// The stable Dock frame (where the Dock is when fully visible).
    /// Use this for positioning UI elements relative to the Dock during animations.
    var stableDockFrame: CGRect? {
        cachedVisibleFrame
    }

    func start() {
        guard axNotificationMonitor == nil else { return }

        let monitor = DockAXNotificationMonitor()
        monitor.onEvent = { [weak self] event in
            self?.handleDockEvent(event)
        }
        monitor.onAppHover = { [weak self] event in
            self?.onAppHover?(event)
        }
        axNotificationMonitor = monitor
        monitor.start()
    }

    func stop() {
        axNotificationMonitor?.stop()
        axNotificationMonitor = nil
        lastState = nil
    }

    /// Called by the click interceptor when it clicks in the Dock frame but finds no Dock element.
    /// This indicates the Dock is hidden (autohide).
    func markDockHidden() {
        guard lastState?.isVisible == true else { return }

        Logger.debug("DockFrameMonitor: Dock visibility changed to hidden")
        var next = lastState ?? State()
        next.isVisible = false
        lastState = next

        DispatchQueue.main.async { [weak self] in
            self?.onStateChange?(next)
        }
    }

    private func handleDockEvent(_ event: DockAXNotificationMonitor.Event) {
        Logger.debug("DockFrameMonitor: received event notification=\(event.notification) listFrame=\(event.listFrame.map { String(describing: $0) } ?? "nil")")

        if event.notification == (kAXSelectedChildrenChangedNotification as String) {
            // Determine the effective frame, handling Dock autohide animation
            let effectiveFrame: CGRect?
            if let frame = event.listFrame {
                // Adjust frame closer to screen edge (AXList frame doesn't fully cover dock items)
                let adjustedFrame = adjustFrameToScreenEdge(frame, itemFrame: event.itemFrame)
                if isFrameWithinPrimaryScreenBounds(adjustedFrame) {
                    // Dock is fully within the primary screen - cache this frame
                    cachedVisibleFrame = adjustedFrame
                    effectiveFrame = adjustedFrame
                } else {
                    // Dock reports an off-screen (or partially off-screen) frame during autohide animation - use cached visible frame if available
                    Logger.debug("DockFrameMonitor: off-screen frame detected, using cached frame=\(cachedVisibleFrame.map { String(describing: $0) } ?? "nil")")
                    effectiveFrame = cachedVisibleFrame ?? frame
                }
            } else {
                effectiveFrame = nil
            }

            let wasVisible = lastState?.isVisible ?? false
            let next = State(listFrame: effectiveFrame, isVisible: true)

            guard next != lastState else {
                Logger.debug("DockFrameMonitor: state unchanged, skipping")
                return
            }
            lastState = next

            if !wasVisible {
                Logger.debug("DockFrameMonitor: Dock visibility changed to visible")
            }
            Logger.debug("DockFrameMonitor: state changed, dispatching frame=\(next.listFrame.map { String(describing: $0) } ?? "nil")")

            DispatchQueue.main.async { [weak self] in
                self?.onStateChange?(next)
            }
        }
    }

    private func isFrameWithinPrimaryScreenBounds(_ frame: CGRect) -> Bool {
        guard let primaryScreen = NSScreen.screens.first(where: { $0.frame.origin == .zero })
            ?? NSScreen.main
            ?? NSScreen.screens.first else {
            // Fall back to the previous heuristic if we can't determine screen bounds.
            return frame.origin.x >= 0
        }

        let primaryBoundsCocoa = primaryScreen.frame
        let primaryBoundsAccessibility = CoordinateConversion.cocoaToAccessibility(
            cocoaFrame: primaryBoundsCocoa,
            primaryScreenBounds: primaryBoundsCocoa
        )

        // Allow a small tolerance for rounding during animations.
        let tolerance: CGFloat = 2
        return primaryBoundsAccessibility.insetBy(dx: -tolerance, dy: -tolerance).contains(frame)
    }

    /// Adjusts the AXList frame closer to the screen edge based on the actual dock item offset.
    /// The Dock's AXList frame doesn't fully cover the actual dock item bounds.
    private func adjustFrameToScreenEdge(_ frame: CGRect, itemFrame: CGRect?) -> CGRect {
        guard let primaryScreen = NSScreen.screens.first(where: { $0.frame.origin == .zero })
            ?? NSScreen.main
            ?? NSScreen.screens.first else {
            return frame
        }

        let screenWidth = primaryScreen.frame.width

        // Detect dock position based on frame geometry
        let isVertical = frame.height > frame.width
        let isLeftDock = frame.origin.x < screenWidth / 2

        // Default offset when AX API doesn't report the actual overhang
        let defaultEdgeOffset: CGFloat = 5

        if isVertical {
            // Vertical dock (left or right side)
            // Compute offset from itemFrame if available, otherwise fallback to default
            let edgeAdjustment: CGFloat
            if let itemFrame {
                if isLeftDock {
                    // Left dock: items extend LEFT of list (itemFrame.x < listFrame.x)
                    let computed = frame.origin.x - itemFrame.origin.x
                    edgeAdjustment = computed > 0 ? computed : defaultEdgeOffset
                } else {
                    // Right dock: items are shifted RIGHT of list (itemFrame.x > listFrame.x)
                    // This mirrors the left dock where items are shifted LEFT (itemFrame.x < listFrame.x)
                    let computed = itemFrame.origin.x - frame.origin.x
                    edgeAdjustment = computed > 0 ? computed : defaultEdgeOffset
                }
            } else {
                edgeAdjustment = defaultEdgeOffset
            }

            if isLeftDock {
                // Left dock: shift x toward 0 (left edge)
                return CGRect(
                    x: frame.origin.x - edgeAdjustment,
                    y: frame.origin.y,
                    width: frame.width,
                    height: frame.height
                )
            } else {
                // Right dock: shift x toward screen right edge
                return CGRect(
                    x: frame.origin.x + edgeAdjustment,
                    y: frame.origin.y,
                    width: frame.width,
                    height: frame.height
                )
            }
        } else {
            // Horizontal dock (bottom)
            // Items extend DOWN from list (itemFrame.maxY > listFrame.maxY)
            // Note: AX API may report same maxY for list and item, so fallback to default
            let edgeAdjustment: CGFloat
            if let itemFrame {
                let computed = itemFrame.maxY - frame.maxY
                edgeAdjustment = computed > 0 ? computed : defaultEdgeOffset
            } else {
                edgeAdjustment = defaultEdgeOffset
            }

            return CGRect(
                x: frame.origin.x,
                y: frame.origin.y + edgeAdjustment,
                width: frame.width,
                height: frame.height
            )
        }
    }
}
