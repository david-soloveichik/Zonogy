import Foundation
import AppKit

/// Handles drag-and-drop of external files/URLs onto placeholders, add-zone indicators, and floating zone indicators.
extension AppController {
    func placeholderReceivedExternalDrop(
        screenId: CGDirectDisplayID,
        zoneIndex: Int,
        items: [ExternalDropItem]
    ) {
        handleExternalDrop(into: zoneKey(for: screenId, index: zoneIndex), items: items, clearExistingOccupant: false, reason: "placeholder-drop")
    }

    func occupiedZoneReceivedExternalDrop(
        screenId: CGDirectDisplayID,
        zoneIndex: Int,
        items: [ExternalDropItem]
    ) {
        handleExternalDrop(into: zoneKey(for: screenId, index: zoneIndex), items: items, clearExistingOccupant: true, reason: "occupied-zone-drop")
    }

    func addZoneIndicatorManager(
        _ manager: AddZoneIndicatorManager,
        didReceiveExternalDrop items: [ExternalDropItem],
        for pill: AddZonePillKey
    ) {
        guard !items.isEmpty else { return }
        lastEdgePillExternalDropAt = Date()
        if let zone = addZone(on: pill.screenId, side: pill.side, announce: false, promoteFloatingOccupant: false) {
            let newZoneKey = zoneKey(for: pill.screenId, index: zone.index)
            targetedZoneManager.setTargetedZone(newZoneKey, reason: "add-zone-drop")
        } else {
            Logger.debug("Add-zone drop requested a new zone on screen \(screenContextStore.loggingIndex(for: pill.screenId)) but creation failed (likely at max zones)")
        }
        openExternalDropItems(items)
    }

    func floatingZoneIndicatorReceivedExternalDrop(screenId: CGDirectDisplayID, items: [ExternalDropItem]) {
        guard !items.isEmpty else { return }
        lastEdgePillExternalDropAt = Date()
        targetedZoneManager.setFloatingTarget(on: screenId, reason: "floating-zone-drop")
        openExternalDropItems(items)
    }

    // MARK: - Edge-pill hover/drop rescue (ExternalZoneDropInterceptorHost)

    /// Highlights the edge pill under a live external drag from the monitor's precise cursor
    /// position, and snaps a boundary-pinned drag back inside the edge so the system's own
    /// delivery can reach the pill. This shadows the pills' AppKit drag tracking, which cannot
    /// see a cursor pinned exactly on a screen-boundary coordinate (see `edgeHitOverhang`).
    func updateExternalDragEdgePillHover(cursorPoint: CGPoint?) {
        let pill = resolveAddZoneDropTarget(cursorPoint: cursorPoint)
        let floatingScreenId = pill == nil ? resolveFloatingDropTarget(cursorPoint: cursorPoint) : nil
        updateAddZoneIndicatorHighlight(pill: pill)
        updateFloatingIndicatorHighlight(screenId: floatingScreenId)
        if let cursorPoint, pill != nil || floatingScreenId != nil {
            snapInBoundaryPinnedExternalDrag(cursorPoint: cursorPoint, pill: pill, floatingScreenId: floatingScreenId)
        }
    }

    /// The screen-edge line of a resolved edge-pill target, along the axis perpendicular to the
    /// pill: the edge coordinate, whether the screen interior lies below (smaller than) it, and
    /// whether that axis is vertical. Derived from the pill's tracked hit rectangle, whose
    /// overhang past the edge is `width/height - baseThickness`. Returns nil for a pill without
    /// overhang (its edge adjoins another display): the cursor does not pin there, so no
    /// boundary dead band exists and neither the snap-in nor the drop rescue may act — a slow
    /// drag crossing onto the neighbor must not be yanked back, and drops near that edge belong
    /// to whatever the system delivers them to.
    private func edgePillEdgeGeometry(
        pill: AddZonePillKey?,
        floatingScreenId: CGDirectDisplayID?
    ) -> (edge: CGFloat, interiorIsBelowEdge: Bool, axisIsVertical: Bool)? {
        if let pill, let hitRect = addIndicatorTracker.hitAreas[pill] {
            let overhang = hitRect.width - EdgeIndicatorPillSizing.baseThickness
            guard overhang > 0 else { return nil }
            switch pill.side {
            case .right:
                return (edge: hitRect.maxX - overhang, interiorIsBelowEdge: true, axisIsVertical: false)
            case .left:
                return (edge: hitRect.minX + overhang, interiorIsBelowEdge: false, axisIsVertical: false)
            }
        }
        if let floatingScreenId, let hitRect = floatingIndicatorTracker.hitAreas[floatingScreenId] {
            let overhang = hitRect.height - EdgeIndicatorPillSizing.baseThickness
            guard overhang > 0 else { return nil }
            return (edge: hitRect.maxY - overhang, interiorIsBelowEdge: true, axisIsVertical: true)
        }
        return nil
    }

    /// While a live external drag sits pinned in a pill's boundary dead band, AppKit drag
    /// delivery cannot reach the pill, and a drop released there would be performed by the
    /// rescue — with the source app animating the drag image back as if nothing accepted it.
    /// Nudging the drag a couple of points inside the edge lets the system find the pill again,
    /// so the drop lands through the normal AppKit path (highlight, drop, no fly-back) and the
    /// rescue remains a backstop. The nudged position lies outside the dead band, so observing
    /// our own posted event cannot re-trigger the nudge.
    private func snapInBoundaryPinnedExternalDrag(
        cursorPoint: CGPoint,
        pill: AddZonePillKey?,
        floatingScreenId: CGDirectDisplayID?
    ) {
        guard let geometry = edgePillEdgeGeometry(pill: pill, floatingScreenId: floatingScreenId) else {
            return
        }
        let coordinate = geometry.axisIsVertical ? cursorPoint.y : cursorPoint.x
        guard EdgePillDropRescuePolicy.isInDeadBand(
            cursor: coordinate,
            edge: geometry.edge,
            interiorIsBelowEdge: geometry.interiorIsBelowEdge
        ) else {
            return
        }

        let snapped = EdgePillDropRescuePolicy.snapInCoordinate(
            edge: geometry.edge,
            interiorIsBelowEdge: geometry.interiorIsBelowEdge
        )
        let target = geometry.axisIsVertical
            ? CGPoint(x: cursorPoint.x, y: snapped)
            : CGPoint(x: snapped, y: cursorPoint.y)
        let event = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseDragged,
            mouseCursorPosition: target,
            mouseButton: .left
        )
        event?.post(tap: .cghidEventTap)
    }

    /// True when the release position sits in the pill's screen-boundary dead band — the only
    /// region where AppKit drag delivery provably misses (see `EdgePillDropRescuePolicy`).
    private func isRescueCursorInDeadBand(
        cursorPoint: CGPoint,
        pill: AddZonePillKey?,
        floatingScreenId: CGDirectDisplayID?
    ) -> Bool {
        guard let geometry = edgePillEdgeGeometry(pill: pill, floatingScreenId: floatingScreenId) else {
            return false
        }
        return EdgePillDropRescuePolicy.isInDeadBand(
            cursor: geometry.axisIsVertical ? cursorPoint.y : cursorPoint.x,
            edge: geometry.edge,
            interiorIsBelowEdge: geometry.interiorIsBelowEdge
        )
    }

    /// Performs an edge-pill external drop that AppKit's drag session missed because the release
    /// happened with the cursor pinned on a screen boundary. Restricted to the boundary dead
    /// band, and delayed briefly so a drop that did reach the pill's AppKit handlers can mark
    /// itself first — together these keep the rescue from ever competing with a deliverable drop.
    func performEdgePillExternalDropRescueIfNeeded(cursorPoint: CGPoint?) {
        guard let cursorPoint else { return }
        let pill = resolveAddZoneDropTarget(cursorPoint: cursorPoint)
        let floatingScreenId = pill == nil ? resolveFloatingDropTarget(cursorPoint: cursorPoint) : nil
        guard pill != nil || floatingScreenId != nil,
              isRescueCursorInDeadBand(cursorPoint: cursorPoint, pill: pill, floatingScreenId: floatingScreenId),
              let payload = ExternalDropParser.payload(from: NSPasteboard(name: .drag)),
              !payload.isEmpty else {
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            if let consumedAt = self.lastEdgePillExternalDropAt,
               Date().timeIntervalSince(consumedAt) < 0.4 {
                return
            }
            if let pill {
                Logger.debug("Edge-pill drop rescue: routing missed drop to add-zone pill on screen \(self.screenContextStore.loggingIndex(for: pill.screenId))")
                self.addZoneIndicatorManager(self.addZoneIndicatorManager, didReceiveExternalDrop: payload.items, for: pill)
            } else if let floatingScreenId {
                Logger.debug("Edge-pill drop rescue: routing missed drop to floating bar on screen \(self.screenContextStore.loggingIndex(for: floatingScreenId))")
                self.floatingZoneIndicatorReceivedExternalDrop(screenId: floatingScreenId, items: payload.items)
            }
        }
    }

    internal func handleExternalDrop(
        into zoneKey: ZoneKey,
        items: [ExternalDropItem],
        clearExistingOccupant: Bool,
        reason: String
    ) {
        guard !items.isEmpty else { return }
        let screenIndex = screenContextStore.loggingIndex(for: zoneKey.screenId)
        Logger.debug(
            "Handling external drop into zone \(zoneKey.index) on screen \(screenIndex) " +
            "(clearExistingOccupant: \(clearExistingOccupant), items: \(items.count), reason: \(reason))"
        )

        if clearExistingOccupant,
           let context = screenContexts[zoneKey.screenId],
           let zone = context.zoneController.zone(at: zoneKey.index),
           let windowId = zone.occupantWindowId,
           let managed = windowController.window(withId: windowId) {
            Logger.debug(
                "External drop clearing occupant window \(managed.windowId) from zone \(zoneKey.index) on screen \(screenIndex)"
            )
            let manualResizeState = performProgrammaticMinimizeCleanup(
                managed,
                minimizeReason: reason,
                cleanupReason: reason,
                retarget: false
            )
            syncWindowsToZones()
            scheduleMinimizeVerification(
                windowId: managed.windowId,
                emptiedZoneKey: zoneKey,
                minimizeReason: reason,
                cleanupReason: reason,
                manualResizeState: manualResizeState
            )
        }

        targetedZoneManager.setTargetedZone(zoneKey, reason: reason)
        openExternalDropItems(items)
    }

    internal func openExternalDropItems(_ items: [ExternalDropItem]) {
        for item in items {
            if item.url.isFileURL {
                openFileURL(item.url)
                continue
            }

            let scheme = item.url.scheme?.lowercased()
            if scheme == "http" || scheme == "https" {
                openWebLink(item.url)
            } else {
                openGeneralURL(item.url)
            }
        }
    }

    private func openFileURL(_ url: URL) {
        if !NSWorkspace.shared.open(url) {
            Logger.debug("Failed to open dropped file \(url.path)")
        }
    }

    private func openWebLink(_ url: URL) {
        if !browserLaunchController.openNewWindow(with: url) {
            Logger.debug("Failed to open dropped web link \(url.absoluteString) in default browser window")
        }
    }

    private func openGeneralURL(_ url: URL) {
        if !NSWorkspace.shared.open(url) {
            Logger.debug("Failed to open dropped URL \(url.absoluteString)")
        }
    }
}
