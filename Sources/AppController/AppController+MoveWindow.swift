import AppKit
import Foundation

/// Moving a placed managed window into a zone of the user's choosing: the "Move Focused Window to
/// Destination" shortcut moves the focused window into the targeted zone, zone navigation's move
/// key (the same shortcut's key) into the selected zone, and a tiled window dropped into a floating
/// zone goes there. All are the one move below — an occupied destination swaps.
extension AppController {
    /// The "Move Focused Window to Destination" shortcut: move the focused managed window into the
    /// targeted zone.
    internal func moveFocusedWindowToTargetZone() {
        guard let windowId = currentFrontmostManagedWindowId else {
            Logger.debug("Move focused window to target: no focused managed window; ignoring")
            return
        }
        guard let destination = targetedZoneManager.targetedDestination else {
            Logger.debug("Move focused window to target: nothing targeted; ignoring")
            return
        }
        moveWindow(windowId, to: destination, reason: "shortcut-move-focused-window-to-target")
    }

    /// Move the placed window `windowId` into `destination`. An occupied destination swaps: the
    /// occupant takes the moved window's origin — including across the tiling/floating boundary —
    /// and a floating zone keeps its frame for the window entering it.
    /// (Without an origin to give it, the occupant is displaced through the normal placement path
    /// and minimizes.) Targeting follows the move rule, applied once after the swap settles: a
    /// move touching the target retargets as if the destination was just filled; an uninvolved
    /// target stays put. A full-screen window is never moved: macOS controls its frame.
    ///
    /// The origin is derived here, on the main queue, rather than carried over from the caller's
    /// decision: everything below runs in one synchronous block against that live state, so an
    /// interleaved placement or topology change can't detach the partner into a stale zone.
    internal func moveWindow(
        _ windowId: Int,
        to destination: TargetedZoneManager.TargetedDestination,
        reason: String
    ) {
        guard let managed = windowController.window(withId: windowId) else {
            Logger.debug("\(reason): window \(windowId) vanished; ignoring")
            return
        }
        guard !isTrackedFullScreenWindow(managed) else {
            Logger.debug("\(reason): window \(windowId) is full screen; ignoring")
            return
        }
        guard destinationExists(destination) else {
            Logger.debug("\(reason): destination \(destination) vanished; ignoring")
            return
        }
        let origin = targetedDestination(for: managed)
        if let origin, origin == destination {
            Logger.debug("\(reason): window \(windowId) already at \(destination); ignoring")
            return
        }
        let preMoveTarget = targetedZoneManager.targetedDestination

        // Identify the swap partner while pre-move occupancy is still accurate, and detach it so
        // the placements below displace (and minimize) nothing. Each floating zone of the swap
        // keeps its frame for the window entering it, read before either window leaves.
        var partner: ManagedWindow?
        var floatingPlacement = FloatingPlacement.standard
        var partnerFloatingPlacement = FloatingPlacement.standard
        if let origin,
           let occupant = occupant(of: destination),
           occupant.windowId != managed.windowId {
            partner = occupant
            floatingPlacement = keptFloatingPlacement(in: destination, for: managed)
            partnerFloatingPlacement = keptFloatingPlacement(in: origin, for: occupant)
            detach(occupant, from: destination, reason: reason)
        }

        Logger.debug(
            "\(reason): window \(windowId) \(origin.map { "from \($0) " } ?? "")to \(destination)"
                + (partner.map { ", swapping with window \($0.windowId)" } ?? "")
        )

        // The moved window keeps focus: its placement is the activating one; the partner is placed
        // passively (no raise, no recency recording) so it stays behind the moved window.
        var recentlyPlacedInFloatingZone: Int?
        switch destination {
        case .tiled:
            var didActivateInPlacement = false
            windowPlacementManager.placeWindow(
                managed,
                into: destination,
                reason: reason,
                retargetAfterFill: false,
                afterPlacementAction: {
                    didActivateInPlacement = true
                    self.recordActiveWindowForHistory(windowId: managed.windowId, reason: reason)
                    self.raiseWindow(managed)
                }
            )
            if !didActivateInPlacement {
                raiseWindow(managed)
            }
        case .floating:
            // The floating assignment itself activates the placed window.
            windowPlacementManager.placeWindow(
                managed,
                into: destination,
                floatingPlacement: floatingPlacement,
                reason: reason,
                retargetAfterFill: false
            )
            recentlyPlacedInFloatingZone = managed.windowId
        }

        if let partner, let origin {
            windowPlacementManager.placeWindow(
                partner,
                into: origin,
                floatingPlacement: partnerFloatingPlacement,
                reason: "\(reason)-swap",
                retargetAfterFill: false,
                activate: false
            )
            if case .floating = origin {
                recentlyPlacedInFloatingZone = partner.windowId
            }
        }

        targetedZoneManager.retargetAfterMovingWindow(
            from: origin,
            to: destination,
            preMoveTarget: preMoveTarget,
            reason: "\(reason)-filled"
        )
        // A tiling zone vacated by an explicit move into the floating zone is exempt from
        // floating-occupant promotion on this sync (with a swap partner it is refilled anyway).
        let vacatedTilingZone: ZoneKey? = {
            guard case .floating = destination else { return nil }
            return origin?.tiledKey
        }()
        syncWindowsToZones(recentlyPlacedInFloatingZone: recentlyPlacedInFloatingZone, explicitlyVacatedZone: vacatedTilingZone)
    }

    /// Where `incoming` goes in `zone` when a swap moves it there: a floating zone keeps the frame
    /// of the window leaving it (read while that window is still there).
    private func keptFloatingPlacement(
        in zone: TargetedZoneManager.TargetedDestination,
        for incoming: ManagedWindow
    ) -> FloatingPlacement {
        guard case .floating(let screenId) = zone,
              let frame = floatingZoneCoordinator.occupantFrame(on: screenId, excluding: incoming.windowId) else {
            return .standard
        }
        return .frame(frame)
    }

    /// Bookkeeping-only removal of a swap partner from its zone (no minimize), mirroring the
    /// drag-drop swap path, so the subsequent placement finds the spot empty.
    private func detach(
        _ managed: ManagedWindow,
        from destination: TargetedZoneManager.TargetedDestination,
        reason: String
    ) {
        switch destination {
        case .tiled(let key):
            screenContexts[key.screenId]?.zoneController.removeWindow(windowId: managed.windowId)
            clearManagedWindowZone(managed)
        case .floating:
            clearFloatingZone(for: managed.windowId, reason: reason)
            clearManagedWindowZone(managed)
        }
    }
}
