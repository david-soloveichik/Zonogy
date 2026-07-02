import AppKit
import ApplicationServices
import Foundation

/// Tracks edge-pill targeting for untracked windows from apps Zonogy would normally manage.
extension AppController {
    func windowElementDidMove(element: AXUIElement, pid: pid_t) {
        if shouldIgnoreDueToSleepWake(event: "windowElementDidMove(\(pid))") {
            return
        }
        handleUnmanagedWindowEdgeMove(element: element, pid: pid)
    }

    internal func handleCapturedWindowForUnmanagedWindowEdgeDrag(_ managed: ManagedWindow) -> Bool {
        guard MouseButtons.isLeftMouseButtonDown(),
              var state = unmanagedWindowEdgeDragState,
              state.isActive,
              unmanagedWindowEdgeDragStateMatches(state, matches: managed) else {
            return false
        }

        state.parkedCapturedWindowId = managed.windowId
        unmanagedWindowEdgeDragState = state
        Logger.debug(
            "Unmanaged edge drag: parked captured window \(managed.windowId) " +
            "(pid \(managed.backing.pid), CGWindowID \(managed.backing.cgWindowId)) until mouse-up"
        )
        return true
    }

    internal func suppressManagedMoveForUnmanagedWindowEdgeDrag(
        windowId: Int,
        frame: CGRect,
        event: String
    ) -> Bool {
        if unmanagedWindowEdgeDragSuppressedManagedWindowIds.contains(windowId) {
            if event == "move-begin", unmanagedWindowEdgeDragState == nil {
                unmanagedWindowEdgeDragSuppressedManagedWindowIds.remove(windowId)
                Logger.debug("Unmanaged edge drag: cleared stale managed-move suppression for window \(windowId)")
                return false
            }

            // After mouse-up, WindowController can still deliver the paired managed move-end.
            // Keep swallowing this window's managed drag callbacks until that move-end arrives.
            if event == "move-end" {
                finishUnmanagedWindowEdgeDrag()
                unmanagedWindowEdgeDragSuppressedManagedWindowIds.remove(windowId)
            }
            Logger.debug("Unmanaged edge drag: suppressed managed \(event) for parked window \(windowId)")
            return true
        }

        guard var state = unmanagedWindowEdgeDragState,
              state.parkedCapturedWindowId == windowId else {
            return false
        }

        unmanagedWindowEdgeDragSuppressedManagedWindowIds.insert(windowId)
        state.latestFrame = frame
        if state.isActive {
            updateUnmanagedWindowEdgeHover(&state)
        }
        unmanagedWindowEdgeDragState = state

        if event == "move-end" {
            finishUnmanagedWindowEdgeDrag()
            unmanagedWindowEdgeDragSuppressedManagedWindowIds.remove(windowId)
        }

        Logger.debug("Unmanaged edge drag: rerouted managed \(event) for parked window \(windowId)")
        return true
    }

    internal func cancelUnmanagedWindowEdgeDrag(reason: String) {
        if unmanagedWindowEdgeDragState != nil {
            Logger.debug("Unmanaged edge drag: cancelled active drag (reason: \(reason))")
        }
        unmanagedWindowEdgeDragState = nil
        unmanagedWindowEdgeDragSuppressedManagedWindowIds.removeAll()
        tearDownUnmanagedWindowEdgeMouseUpMonitors()
        setUnmanagedWindowEdgeIndicatorMousePassthrough(false)
        updateAddZoneIndicatorHighlight(pill: nil)
        updateFloatingIndicatorHighlight(screenId: nil)
    }

    internal func clearUnmanagedWindowEdgeState(forPid pid: pid_t, reason: String) {
        if unmanagedWindowEdgeDragState?.pid == pid {
            cancelUnmanagedWindowEdgeDrag(reason: reason)
        }
    }

    internal func clearUnmanagedWindowEdgeState(for element: AXUIElement, pid: pid_t, reason: String) {
        let elementKey = AccessibilityElementKey(element: element)
        if let state = unmanagedWindowEdgeDragState,
           state.pid == pid,
           state.elementKey == elementKey {
            cancelUnmanagedWindowEdgeDrag(reason: reason)
        }
    }

    private func handleUnmanagedWindowEdgeMove(element: AXUIElement, pid: pid_t) {
        guard unmanagedWindowEdgeDragState != nil || (!dragDropCoordinator.isDragging && !floatingDragHandler.isActive) else {
            return
        }
        guard MouseButtons.isLeftMouseButtonDown() else {
            if unmanagedWindowEdgeDragState?.pid == pid {
                cancelUnmanagedWindowEdgeDrag(reason: "move-without-left-button")
            }
            return
        }
        guard let application = NSRunningApplication(processIdentifier: pid),
              shouldManage(application: application) else {
            return
        }
        guard windowController.managedWindow(matching: element) == nil else {
            return
        }
        guard let frame = ManagedWindow.frame(of: element) else {
            return
        }

        let elementKey = AccessibilityElementKey(element: element)
        let cgWindowId = windowController.externalIdentifier(for: element)?.cgWindowId

        if var state = unmanagedWindowEdgeDragState {
            guard unmanagedWindowEdgeDragStateMatches(
                state,
                matchesPid: pid,
                elementKey: elementKey,
                cgWindowId: cgWindowId
            ) else {
                if !state.isActive {
                    cancelUnmanagedWindowEdgeDrag(reason: "replaced-by-new-untracked-window")
                    beginUnmanagedWindowEdgeCandidate(
                        elementKey: elementKey,
                        pid: pid,
                        cgWindowId: cgWindowId,
                        frame: frame
                    )
                }
                return
            }

            if state.cgWindowId == nil {
                state.cgWindowId = cgWindowId
            }
            state.latestFrame = frame
            updateUnmanagedWindowEdgeActivationAndHover(&state)
            unmanagedWindowEdgeDragState = state
            return
        }

        beginUnmanagedWindowEdgeCandidate(
            elementKey: elementKey,
            pid: pid,
            cgWindowId: cgWindowId,
            frame: frame
        )
    }

    private func beginUnmanagedWindowEdgeCandidate(
        elementKey: AccessibilityElementKey,
        pid: pid_t,
        cgWindowId: Int?,
        frame: CGRect
    ) {
        setUnmanagedWindowEdgeIndicatorMousePassthrough(true)
        unmanagedWindowEdgeDragState = UnmanagedWindowEdgeDragState(
            elementKey: elementKey,
            pid: pid,
            cgWindowId: cgWindowId,
            originFrame: frame,
            latestFrame: frame,
            isActive: false,
            parkedCapturedWindowId: nil,
            hoveredAddZonePill: nil,
            hoveredFloatingScreenId: nil
        )
        installUnmanagedWindowEdgeMouseUpMonitorsIfNeeded()
    }

    private func updateUnmanagedWindowEdgeActivationAndHover(_ state: inout UnmanagedWindowEdgeDragState) {
        if !state.isActive {
            guard UnmanagedWindowEdgeDragPolicy.hasActivated(
                originFrame: state.originFrame,
                latestFrame: state.latestFrame,
                threshold: windowController.dragActivationDistance
            ) else {
                return
            }
            state.isActive = true
            Logger.debug(
                "Unmanaged edge drag: activated for pid \(state.pid), " +
                "CGWindowID \(state.cgWindowId.map(String.init) ?? "unknown")"
            )
        }
        updateUnmanagedWindowEdgeHover(&state)
    }

    private func updateUnmanagedWindowEdgeHover(_ state: inout UnmanagedWindowEdgeDragState) {
        let cursorPoint = currentCursorAccessibilityPoint()
        let addZoneTarget = resolveAddZoneDropTarget(cursorPoint: cursorPoint)
        let floatingTarget = addZoneTarget == nil ? resolveFloatingDropTarget(cursorPoint: cursorPoint) : nil

        if state.hoveredAddZonePill != addZoneTarget {
            state.hoveredAddZonePill = addZoneTarget
            updateAddZoneIndicatorHighlight(pill: addZoneTarget)
        }

        if state.hoveredFloatingScreenId != floatingTarget {
            state.hoveredFloatingScreenId = floatingTarget
            updateFloatingIndicatorHighlight(screenId: floatingTarget)
        }
    }

    private func finishUnmanagedWindowEdgeDrag() {
        guard let state = unmanagedWindowEdgeDragState else {
            tearDownUnmanagedWindowEdgeMouseUpMonitors()
            setUnmanagedWindowEdgeIndicatorMousePassthrough(false)
            return
        }

        unmanagedWindowEdgeDragState = nil
        tearDownUnmanagedWindowEdgeMouseUpMonitors()
        updateAddZoneIndicatorHighlight(pill: nil)
        updateFloatingIndicatorHighlight(screenId: nil)
        defer {
            setUnmanagedWindowEdgeIndicatorMousePassthrough(false)
        }

        guard state.isActive else {
            return
        }

        let cursorPoint = currentCursorAccessibilityPoint()
        let addZoneTarget = state.hoveredAddZonePill ?? resolveAddZoneDropTarget(cursorPoint: cursorPoint)
        let floatingTarget = addZoneTarget == nil
            ? (state.hoveredFloatingScreenId ?? resolveFloatingDropTarget(cursorPoint: cursorPoint))
            : nil

        if let target = UnmanagedWindowEdgeDragPolicy.edgeDropTarget(
            hoveredAddZonePill: addZoneTarget,
            hoveredFloatingScreenId: floatingTarget
        ) {
            applyUnmanagedWindowEdgeTarget(target)
        }

        placeParkedCapturedWindowNormallyIfNeeded(state)
    }

    @discardableResult
    private func applyUnmanagedWindowEdgeTarget(_ target: UnmanagedWindowEdgeDragPolicy.EdgeDropTarget) -> Bool {
        switch target {
        case .addZone(let pill):
            guard let zone = addZone(on: pill.screenId, side: pill.side, announce: false, promoteFloatingOccupant: false) else {
                Logger.debug(
                    "Unmanaged edge drag: add-zone drop did nothing because screen " +
                    "\(screenContextStore.loggingIndex(for: pill.screenId)) has no room on the \(pill.side.rawValue) side"
                )
                return false
            }
            targetedZoneManager.setTargetedZone(
                ZoneKey(screenId: pill.screenId, index: zone.index),
                reason: "unmanaged-window-add-zone-drop"
            )
            return true

        case .floatingZone(let screenId):
            targetedZoneManager.setFloatingTarget(on: screenId, reason: "unmanaged-window-floating-zone-drop")
            return true
        }
    }

    private func unmanagedWindowEdgeDragStateMatches(
        _ state: UnmanagedWindowEdgeDragState,
        matches managed: ManagedWindow
    ) -> Bool {
        guard state.pid == managed.backing.pid else {
            return false
        }
        if let cgWindowId = state.cgWindowId {
            return cgWindowId == managed.backing.cgWindowId
        }
        return state.elementKey == AccessibilityElementKey(element: managed.backing.element)
    }

    private func unmanagedWindowEdgeDragStateMatches(
        _ state: UnmanagedWindowEdgeDragState,
        matchesPid pid: pid_t,
        elementKey: AccessibilityElementKey,
        cgWindowId: Int?
    ) -> Bool {
        guard state.pid == pid else {
            return false
        }
        if let stateWindowId = state.cgWindowId, let cgWindowId {
            return stateWindowId == cgWindowId
        }
        return state.elementKey == elementKey
    }

    private func placeParkedCapturedWindowNormallyIfNeeded(_ state: UnmanagedWindowEdgeDragState) {
        guard let windowId = state.parkedCapturedWindowId,
              let managed = windowController.window(withId: windowId),
              !managed.isPlacedInZone else {
            return
        }
        Logger.debug("Unmanaged edge drag: placing parked captured window \(windowId) through normal placement")
        windowPlacementManager.placeNewWindow(managed)
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == managed.backing.pid {
            setCurrentFrontmostManagedWindowId(managed.windowId, reason: "unmanaged-edge-drag-normal-placement")
            refreshResizeHandles()
        }
    }

    private func setUnmanagedWindowEdgeIndicatorMousePassthrough(_ enabled: Bool) {
        guard unmanagedWindowEdgeIndicatorMousePassthroughEnabled != enabled else {
            return
        }
        unmanagedWindowEdgeIndicatorMousePassthroughEnabled = enabled
        addZoneIndicatorManager.setMousePassthroughForUnmanagedWindowEdgeDrag(enabled)
        floatingIndicatorManager.setMousePassthroughForUnmanagedWindowEdgeDrag(enabled)
        Logger.debug(
            "Unmanaged edge drag: edge indicators mouse passthrough \(enabled ? "enabled" : "disabled")"
        )
    }

    private func installUnmanagedWindowEdgeMouseUpMonitorsIfNeeded() {
        if unmanagedWindowEdgeDragLocalMouseUpMonitor == nil {
            unmanagedWindowEdgeDragLocalMouseUpMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] event in
                self?.finishUnmanagedWindowEdgeDrag()
                return event
            }
        }
        if unmanagedWindowEdgeDragGlobalMouseUpMonitor == nil {
            unmanagedWindowEdgeDragGlobalMouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] _ in
                self?.finishUnmanagedWindowEdgeDrag()
            }
        }
    }

    private func tearDownUnmanagedWindowEdgeMouseUpMonitors() {
        if let monitor = unmanagedWindowEdgeDragLocalMouseUpMonitor {
            NSEvent.removeMonitor(monitor)
            unmanagedWindowEdgeDragLocalMouseUpMonitor = nil
        }
        if let monitor = unmanagedWindowEdgeDragGlobalMouseUpMonitor {
            NSEvent.removeMonitor(monitor)
            unmanagedWindowEdgeDragGlobalMouseUpMonitor = nil
        }
    }
}
