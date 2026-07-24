import AppKit

/// Tracks gesture-modifier external drags over managed tiling zones and presents zone overlays.
protocol ExternalZoneDropInterceptorHost: AnyObject, DragOverlayExternalDropDelegate {
    var isManagedWindowDragInProgress: Bool { get }
    func currentCursorAccessibilityPoint() -> CGPoint?
    func noteExternalDragSourceBundleIdentifierIfNeeded()
    func shouldApplyGestureModifierExternalDrag() -> Bool
    func shouldBeginExternalZoneDropInterception(cursorPoint: CGPoint) -> Bool
    func resolveInterceptedExternalDropZoneKey(cursorPoint: CGPoint) -> ZoneKey?
    func externalDropOverlayDescriptors() -> [ZoneOverlayDescriptor]
    func suspendPlaceholderExternalDragOverlay(reason: String)
    func resumePlaceholderExternalDragOverlayIfNeeded(cursorPoint: CGPoint?)
    func resetObservedPlaceholderExternalDrag(reason: String)
    func resetExternalDragSourceBundleIdentifier(reason: String)
    func updateExternalDragEdgePillHover(cursorPoint: CGPoint?)
    func performEdgePillExternalDropRescueIfNeeded(cursorPoint: CGPoint?)
}

final class ExternalZoneDropInterceptor {
    private enum Constants {
        static let monitoredEvents: NSEvent.EventTypeMask = [.leftMouseDragged, .leftMouseUp, .flagsChanged]
    }

    weak var host: ExternalZoneDropInterceptorHost?

    private let overlayManager: DragOverlayManager
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var isInterceptionActive = false
    private var pendingMouseUpTearDownWorkItem: DispatchWorkItem?
    /// Drag-pasteboard change count as of the last finished (or cancelled) gesture. The drag
    /// pasteboard keeps its content after a drag ends, so content alone cannot distinguish a live
    /// external drag from a stale leftover; a differing change count under a held button is the
    /// signal that a fresh drag session has started.
    private var handledDragPasteboardChangeCount = NSPasteboard(name: .drag).changeCount
    private var isDrivingEdgePillHover = false
    /// Installed only while a live external drag is being driven: Escape cancels the drag
    /// session at the AppKit level with the button still down, and without observing it the
    /// hover state (and worse, the drop rescue) would outlive the cancelled session.
    private var escapeGlobalMonitor: Any?
    private var escapeLocalMonitor: Any?

    init(host: ExternalZoneDropInterceptorHost) {
        self.host = host
        self.overlayManager = DragOverlayManager(externalDropDelegate: host, windowLevel: .statusBar)
    }

    func start() {
        guard globalMonitor == nil, localMonitor == nil else {
            return
        }

        handledDragPasteboardChangeCount = NSPasteboard(name: .drag).changeCount
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: Constants.monitoredEvents) { [weak self] event in
            self?.handle(event: event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: Constants.monitoredEvents) { [weak self] event in
            self?.handle(event: event)
            return event
        }
    }

    func stop() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        pendingMouseUpTearDownWorkItem?.cancel()
        pendingMouseUpTearDownWorkItem = nil
        if isDrivingEdgePillHover {
            stopDrivingEdgePillHover()
        }
        tearDownOverlays()
        host?.suspendPlaceholderExternalDragOverlay(reason: "external-zone-drop-interceptor-stop")
        host?.resetObservedPlaceholderExternalDrag(reason: "external-zone-drop-interceptor-stop")
        host?.resetExternalDragSourceBundleIdentifier(reason: "external-zone-drop-interceptor-stop")
    }

    private func handle(event: NSEvent) {
        switch event.type {
        case .leftMouseDragged:
            refreshInterceptionState(allowBeginInterception: true)
        case .flagsChanged:
            refreshInterceptionState(allowBeginInterception: false)
        case .leftMouseUp:
            // Drag-session hit-testing quantizes an edge-pinned cursor onto a screen-boundary
            // row that no on-screen window region covers (see edgeHitOverhang), so a drop
            // released there never reaches the pill's AppKit drop handlers. Give the host a
            // chance to perform the drop itself from the precise cursor position.
            if isDrivingEdgePillHover {
                host?.performEdgePillExternalDropRescueIfNeeded(cursorPoint: host?.currentCursorAccessibilityPoint())
            }
            // Record the gesture's pasteboard state synchronously: the delayed teardown below
            // can be cancelled by the next gesture's first drag event, and a stale count would
            // make leftover pasteboard content look like a live drag.
            handledDragPasteboardChangeCount = NSPasteboard(name: .drag).changeCount
            scheduleMouseUpTearDown()
        default:
            break
        }
    }

    private func refreshInterceptionState(allowBeginInterception: Bool) {
        pendingMouseUpTearDownWorkItem?.cancel()
        pendingMouseUpTearDownWorkItem = nil

        let cursorPoint = host?.currentCursorAccessibilityPoint()
        refreshEdgePillHover(cursorPoint: cursorPoint)

        guard let host,
              !host.isManagedWindowDragInProgress,
              MouseButtons.isLeftMouseButtonDown(),
              NSEvent.modifierFlags.contains(MouseGestureModifierPreferences.shared.modifiers.nsEventFlags),
              ExternalDropParser.canAccept(NSPasteboard(name: .drag)),
              let cursorPoint else {
            tearDownOverlays()
            host?.resumePlaceholderExternalDragOverlayIfNeeded(cursorPoint: cursorPoint)
            return
        }

        host.noteExternalDragSourceBundleIdentifierIfNeeded()
        guard host.shouldApplyGestureModifierExternalDrag() else {
            tearDownOverlays()
            host.resumePlaceholderExternalDragOverlayIfNeeded(cursorPoint: cursorPoint)
            return
        }

        let interceptedZoneKey = host.resolveInterceptedExternalDropZoneKey(cursorPoint: cursorPoint)

        if !isInterceptionActive {
            guard allowBeginInterception else {
                return
            }
            guard host.shouldBeginExternalZoneDropInterception(cursorPoint: cursorPoint) else {
                return
            }

            overlayManager.present(over: host.externalDropOverlayDescriptors())
            isInterceptionActive = true
            Logger.debug("External zone drop interception began")
        } else if interceptedZoneKey == nil {
            tearDownOverlays()
            host.resumePlaceholderExternalDragOverlayIfNeeded(cursorPoint: cursorPoint)
            return
        }

        host.suspendPlaceholderExternalDragOverlay(reason: "control-command-external-drop")
        overlayManager.updateHighlight(to: interceptedZoneKey)
    }

    /// Drives edge-pill (add-zone + floating) drag hover from the monitor's precise cursor
    /// position while a live external drag is in flight. This backs up the pills' own AppKit
    /// drag tracking, which misses a cursor pinned on a screen-boundary coordinate.
    private func refreshEdgePillHover(cursorPoint: CGPoint?) {
        let dragPasteboard = NSPasteboard(name: .drag)
        let liveExternalDrag = MouseButtons.isLeftMouseButtonDown()
            && dragPasteboard.changeCount != handledDragPasteboardChangeCount
            && ExternalDropParser.canAccept(dragPasteboard)

        if liveExternalDrag {
            if !isDrivingEdgePillHover {
                isDrivingEdgePillHover = true
                installEscapeMonitors()
            }
            host?.updateExternalDragEdgePillHover(cursorPoint: cursorPoint)
        } else if isDrivingEdgePillHover {
            stopDrivingEdgePillHover()
        }
    }

    private func stopDrivingEdgePillHover() {
        isDrivingEdgePillHover = false
        tearDownEscapeMonitors()
        host?.updateExternalDragEdgePillHover(cursorPoint: nil)
    }

    /// Escape cancels the drag session while the button stays down; mark the gesture handled so
    /// neither the hover highlight nor the mouse-up drop rescue can act on the dead session.
    private func handleEscapeDuringExternalDrag() {
        guard isDrivingEdgePillHover else { return }
        Logger.debug("External drag cancelled with Escape; disarming edge-pill hover and drop rescue")
        handledDragPasteboardChangeCount = NSPasteboard(name: .drag).changeCount
        stopDrivingEdgePillHover()
    }

    private func installEscapeMonitors() {
        guard escapeGlobalMonitor == nil, escapeLocalMonitor == nil else { return }
        escapeGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            if event.keyCode == 53 {
                self?.handleEscapeDuringExternalDrag()
            }
        }
        escapeLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            if event.keyCode == 53 {
                self?.handleEscapeDuringExternalDrag()
            }
            return event
        }
    }

    private func tearDownEscapeMonitors() {
        if let escapeGlobalMonitor {
            NSEvent.removeMonitor(escapeGlobalMonitor)
            self.escapeGlobalMonitor = nil
        }
        if let escapeLocalMonitor {
            NSEvent.removeMonitor(escapeLocalMonitor)
            self.escapeLocalMonitor = nil
        }
    }

    private func scheduleMouseUpTearDown() {
        pendingMouseUpTearDownWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingMouseUpTearDownWorkItem = nil
            if self.isDrivingEdgePillHover {
                self.stopDrivingEdgePillHover()
            }
            self.tearDownOverlays()
            self.host?.suspendPlaceholderExternalDragOverlay(reason: "external-zone-drop-mouse-up")
            self.host?.resetObservedPlaceholderExternalDrag(reason: "external-zone-drop-mouse-up")
            self.host?.resetExternalDragSourceBundleIdentifier(reason: "external-zone-drop-mouse-up")
        }
        pendingMouseUpTearDownWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: workItem)
    }

    private func tearDownOverlays() {
        guard isInterceptionActive else {
            return
        }
        pendingMouseUpTearDownWorkItem?.cancel()
        pendingMouseUpTearDownWorkItem = nil
        overlayManager.tearDown()
        isInterceptionActive = false
        Logger.debug("External zone drop interception ended")
    }
}
