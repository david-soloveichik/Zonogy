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
    /// All pasteboard reads go through the session tracker, which polls the change count sparingly
    /// and examines a recognized session's content once (see ExternalDragSessionTracker).
    private let dragPasteboard = NSPasteboard(name: .drag)
    private var dragSession: ExternalDragSessionTracker
    private var isDrivingEdgePillHover = false
    /// Installed only while a live external drag is being driven: Escape cancels the drag
    /// session at the AppKit level with the button still down, and without observing it the
    /// hover state (and worse, the drop rescue) would outlive the cancelled session.
    private var escapeGlobalMonitor: Any?
    private var escapeLocalMonitor: Any?

    init(host: ExternalZoneDropInterceptorHost) {
        self.host = host
        self.overlayManager = DragOverlayManager(externalDropDelegate: host, windowLevel: .statusBar)
        self.dragSession = ExternalDragSessionTracker(handledChangeCount: dragPasteboard.changeCount)
    }

    func start() {
        guard globalMonitor == nil, localMonitor == nil else {
            return
        }

        dragSession = ExternalDragSessionTracker(handledChangeCount: dragPasteboard.changeCount)
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
            // A drag event is a gesture in progress. If the previous gesture's mouse-up teardown is
            // still pending, finish that gesture now, before this one presents anything: a later
            // teardown would tear down this gesture's visuals, and a skipped one would leak the
            // previous gesture's source and placeholder state into this one.
            if let pending = pendingMouseUpTearDownWorkItem {
                pending.cancel()
                pendingMouseUpTearDownWorkItem = nil
                finishGesture()
            }
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
            dragSession.endGesture(changeCount: dragPasteboard.changeCount)
            scheduleMouseUpTearDown()
        default:
            break
        }
    }

    private func refreshInterceptionState(allowBeginInterception: Bool) {
        let isButtonDown = MouseButtons.isLeftMouseButtonDown()
        // After a mouse-up, the pending teardown owns the end of the gesture; a modifier release
        // inside its brief delay must not tear the visuals down early.
        if !isButtonDown, pendingMouseUpTearDownWorkItem != nil {
            return
        }
        let cursorPoint = host?.currentCursorAccessibilityPoint()
        refreshEdgePillHover(isButtonDown: isButtonDown, cursorPoint: cursorPoint)

        // Free checks first; the pasteboard was consulted, if at all, by the tracker above.
        guard let host,
              isButtonDown,
              !host.isManagedWindowDragInProgress,
              NSEvent.modifierFlags.contains(ModifierCombinationPreferences.mouseGestures.modifiers.nsEventFlags),
              dragSession.isLiveExternalDrag,
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
    private func refreshEdgePillHover(isButtonDown: Bool, cursorPoint: CGPoint?) {
        if isButtonDown {
            let now = Date()
            if dragSession.shouldPollChangeCount(now: now) {
                dragSession.recordPoll(changeCount: dragPasteboard.changeCount, now: now) {
                    ExternalDropParser.canAccept(dragPasteboard)
                }
            }
        } else if dragSession.isTrackingGesture {
            // The mouse-up that ends a gesture can be missed; the button being up says it is over,
            // so finish it now (there is no drop animation to wait for). This also rebaselines the
            // change count for a drag the throttle never recognized, so its leftover content cannot
            // pass for a fresh session in the next gesture.
            dragSession.endGesture(changeCount: dragPasteboard.changeCount)
            finishGesture()
        }
        let liveExternalDrag = isButtonDown && dragSession.isLiveExternalDrag

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
        dragSession.endGesture(changeCount: dragPasteboard.changeCount)
        // Nothing to wait for (no drop, so no drop animation): finish the gesture at once.
        finishGesture()
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

    /// Defers `finishGesture` briefly so the drop animation completes before the overlays go.
    private func scheduleMouseUpTearDown() {
        pendingMouseUpTearDownWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingMouseUpTearDownWorkItem = nil
            self.finishGesture()
        }
        pendingMouseUpTearDownWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: workItem)
    }

    /// Ends the gesture's visuals and the per-gesture host state, whichever of them is active.
    private func finishGesture() {
        if isDrivingEdgePillHover {
            stopDrivingEdgePillHover()
        }
        tearDownOverlays()
        host?.suspendPlaceholderExternalDragOverlay(reason: "external-zone-drop-mouse-up")
        host?.resetObservedPlaceholderExternalDrag(reason: "external-zone-drop-mouse-up")
        host?.resetExternalDragSourceBundleIdentifier(reason: "external-zone-drop-mouse-up")
    }

    private func tearDownOverlays() {
        guard isInterceptionActive else {
            return
        }
        overlayManager.tearDown()
        isInterceptionActive = false
        Logger.debug("External zone drop interception ended")
    }
}
