import AppKit
import Foundation

/// Moving the focused managed window into a zone of the user's choosing: the "Move Focused Window
/// to Destination" shortcut moves it into the targeted zone, and zone navigation's move key (the
/// same shortcut's key) into the selected zone. Both are the one move below — an occupied
/// destination swaps.
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
        moveFocusedWindow(windowId, to: destination, reason: "shortcut-move-focused-window-to-target")
    }

    /// Move the focused window `windowId` into `destination`. An occupied destination swaps: the
    /// occupant takes the moved window's origin — including across the tiling/floating boundary.
    /// (Without an origin to give it, the occupant is displaced through the normal placement path
    /// and minimizes.) Targeting follows the move rule, applied once after the swap settles: a
    /// move touching the target retargets as if the destination was just filled; an uninvolved
    /// target stays put.
    ///
    /// The origin is derived here, on the main queue, rather than carried over from the caller's
    /// decision: everything below runs in one synchronous block against that live state, so an
    /// interleaved placement or topology change can't detach the partner into a stale zone.
    internal func moveFocusedWindow(
        _ windowId: Int,
        to destination: TargetedZoneManager.TargetedDestination,
        reason: String
    ) {
        guard let managed = windowController.window(withId: windowId) else {
            Logger.debug("\(reason): window \(windowId) vanished; ignoring")
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
        // the placements below displace (and minimize) nothing.
        var partner: ManagedWindow?
        if origin != nil,
           let occupant = occupant(of: destination),
           occupant.windowId != managed.windowId {
            partner = occupant
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
                centerFloatingWindow: true,
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
                centerFloatingWindow: true,
                reason: reason,
                retargetAfterFill: false
            )
            recentlyPlacedInFloatingZone = managed.windowId
        }

        if let partner, let origin {
            windowPlacementManager.placeWindow(
                partner,
                into: origin,
                centerFloatingWindow: true,
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
            clearFloatingZone(for: managed.windowId, minimize: false, reason: reason)
            clearManagedWindowZone(managed)
        }
    }
}
