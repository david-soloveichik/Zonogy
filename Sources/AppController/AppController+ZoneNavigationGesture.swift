import AppKit
import Foundation

/// Control-Command + arrow-key zone navigation: builds the navigable zone set, resolves the
/// selection as the gesture proceeds, shows it with the blue-circle overlay, and commits on release
/// (focus a filled zone's window, or target an empty zone), on the move key (move the focused
/// window into the selected zone), or on the Show Launcher key (target the selected zone and open the
/// Launcher there). The gesture lifecycle is driven by `ZoneNavigationInterceptor`; the selection
/// geometry is the pure `ZoneNavigation`.
extension AppController {
    /// Live state for an in-progress zone-navigation gesture. Candidates are snapshotted at engage
    /// time so the circle stays stable for the (brief) duration of the gesture; commits re-check
    /// live occupancy.
    struct ZoneNavigationState {
        let candidates: [ZoneNavigation.Candidate]
        let anchor: ZoneNavigation.Anchor
        var selection: ZoneNavigation.Selection?
    }
}

extension AppController: ZoneNavigationInterceptorDelegate {
    func zoneNavigationShouldHandleEvents(_ interceptor: ZoneNavigationInterceptor) -> Bool {
        !hotkeyService.isSuspended && !sleepWakeProtectionActive
    }

    func zoneNavigationShouldBegin(_ interceptor: ZoneNavigationInterceptor) -> Bool {
        // Choosers that own the arrow keys block the gesture. The Launcher deliberately does not:
        // it keeps its plain arrows, and this gesture is how the target moves by keyboard while it
        // is open. This runs synchronously in the event-tap callback, so the check stays cheap.
        !cmdTabController.isActive
            && !winShotChooserController.isActive
            && hasNavigableZone()
    }

    func zoneNavigation(_ interceptor: ZoneNavigationInterceptor, didBegin direction: ZoneNavigationDirection) {
        beginZoneNavigation(direction: direction)
    }

    func zoneNavigation(_ interceptor: ZoneNavigationInterceptor, didMove direction: ZoneNavigationDirection) {
        moveZoneNavigation(direction: direction)
    }

    func zoneNavigationDidPressMoveKey(_ interceptor: ZoneNavigationInterceptor) -> Bool {
        requestZoneNavigationMove()
    }

    func zoneNavigationDidPressShowLauncherKey(_ interceptor: ZoneNavigationInterceptor) -> Bool {
        requestZoneNavigationLauncherShow()
    }

    func zoneNavigationDidCommit(_ interceptor: ZoneNavigationInterceptor) {
        commitZoneNavigation()
    }

    func zoneNavigationDidCancel(_ interceptor: ZoneNavigationInterceptor) {
        cancelZoneNavigation(reason: "interceptor-cancel")
    }
}

extension AppController {
    private func beginZoneNavigation(direction: ZoneNavigationDirection) {
        let candidates = zoneNavigationCandidates()
        guard !candidates.isEmpty else {
            // `shouldBegin` already gates on `hasNavigableZone()`, so this only happens if the
            // screens changed between engaging and now. Drop the interceptor's engaged state too so
            // it stops swallowing arrows for a dead session.
            Logger.debug("Zone navigation (\(direction)): no navigable zones; ignoring")
            zoneNavigationInterceptor.resetEngagement()
            clearZoneNavigation()
            return
        }

        let start = zoneNavigationStart(candidates: candidates)
        let selection = ZoneNavigation.initialSelection(
            direction: direction,
            focusedZoneId: start.focusedZoneId,
            targetedZoneId: start.targetedZoneId,
            fallbackAnchor: start.anchor,
            candidates: candidates
        )

        zoneNavigationState = ZoneNavigationState(
            candidates: candidates,
            anchor: start.anchor,
            selection: selection
        )
        updateZoneNavigationDot(selection: selection)
        Logger.debug("Zone navigation begun (\(direction)); selection: \(selection.map { String(describing: $0.id) } ?? "none")")
    }

    private func moveZoneNavigation(direction: ZoneNavigationDirection) {
        guard var state = zoneNavigationState else { return }
        let next = ZoneNavigation.nextSelection(
            direction: direction,
            currentSelection: state.selection,
            anchor: state.anchor,
            candidates: state.candidates
        )
        state.selection = next
        zoneNavigationState = state
        updateZoneNavigationDot(selection: next)
    }

    /// Modifier release: focus the selected zone's window, or target the selected zone when empty.
    /// Occupancy is re-read live at commit time (the snapshot only drives geometry).
    private func commitZoneNavigation() {
        guard let state = zoneNavigationState else { return }
        clearZoneNavigation()

        guard let selection = state.selection else {
            Logger.debug("Zone navigation committed with no selection")
            return
        }

        let destination = zoneDestination(for: selection.id)
        if let occupant = occupant(of: destination) {
            Logger.debug("Zone navigation focusing window \(occupant.windowId) in \(selection.id)")
            if case .floating = destination {
                activateFloatingZoneWindow(occupant, reason: "zone-navigation-commit")
            } else {
                raiseWindow(occupant)
            }
            return
        }

        switch destination {
        case .tiled(let key):
            guard screenContexts[key.screenId]?.zoneController.zone(at: key.index) != nil else {
                Logger.debug("Zone navigation commit: targeted zone \(key.index) vanished; ignoring")
                return
            }
            Logger.debug("Zone navigation targeting empty zone \(key.index) on screen \(screenContextStore.loggingIndex(for: key.screenId))")
            let wasAlreadyTargeted = targetedZoneManager.targetedDestination == destination
            // This explicit selection commits any tentative Launcher retarget session — including
            // when it re-affirms the session's current target, which fires no change event for the
            // refresh path's commit-on-change to act on.
            launcherRetargetSession = nil
            performTargetChangeKeepingLauncherVisible {
                targetedZoneManager.setTargetedZone(key, reason: "zone-navigation-commit")
            }
            if wasAlreadyTargeted {
                flashTargetFeedback(for: key)
            }
            autoShowLauncherIfEmptyTargetedTiledZone()
        case .floating(let screenId):
            guard screenContexts[screenId] != nil else { return }
            Logger.debug("Zone navigation targeting empty floating zone on screen \(screenContextStore.loggingIndex(for: screenId))")
            let wasAlreadyTargeted = targetedZoneManager.targetedDestination == destination
            // Same explicit-selection session commit as the tiling branch above.
            launcherRetargetSession = nil
            performTargetChangeKeepingLauncherVisible {
                targetedZoneManager.setFloatingTarget(on: screenId, reason: "zone-navigation-commit")
            }
            if wasAlreadyTargeted {
                pulseFloatingTargetFeedback(for: screenId)
            }
        }
    }

    /// Drop the gesture without committing and tear down the circle.
    internal func cancelZoneNavigation(reason: String) {
        guard zoneNavigationState != nil else { return }
        Logger.debug("Zone navigation cancelled (\(reason))")
        clearZoneNavigation()
    }

    /// Zone topology changed (zone added/removed/replaced, or the screen model rebuilt): an
    /// in-flight gesture's snapshot may now identify different zones — indices are reused after a
    /// removal, so the commit-time existence checks alone can't catch it. Drop the gesture rather
    /// than let a commit act on the wrong zone. Called from the canonical topology mutations, so
    /// mouse-driven changes (placeholder ×, add-zone pill) are covered too.
    internal func cancelZoneNavigationForTopologyChange(reason: String) {
        zoneNavigationInterceptor.resetEngagement()
        cancelZoneNavigation(reason: reason)
    }

    private func clearZoneNavigation() {
        zoneNavigationState = nil
        zoneNavigationDotOverlay.hide()
    }

    /// Cheap "is there anything to navigate?" check used to gate engagement synchronously in the
    /// event-tap callback. Zones always exist, so this only rules out the all-screens-paused case
    /// (which `isScreenTargetable` still keeps reachable via its fallback screen).
    private func hasNavigableZone() -> Bool {
        screenOrder.contains { targetedZoneManager.isScreenTargetable($0) && screenContexts[$0] != nil }
    }

    /// Every navigable zone by its rectangle in accessibility coordinates: each tiling zone —
    /// filled or empty — by its zone frame, plus each screen's floating zone (occupant window
    /// rectangle when filled, bottom-edge bar when empty). Reuses the canonical targetability
    /// policy so navigation reaches exactly the zones the rest of targeting considers valid.
    private func zoneNavigationCandidates() -> [ZoneNavigation.Candidate] {
        var candidates: [ZoneNavigation.Candidate] = []
        for screenId in screenOrder {
            guard targetedZoneManager.isScreenTargetable(screenId),
                  let context = screenContexts[screenId] else {
                continue
            }
            let descriptor = context.descriptor
            for zone in context.zoneController.allZones {
                candidates.append(.init(
                    id: .tiling(screenId: screenId, index: zone.index),
                    frame: descriptor.screenToAccessibility(zone.frame),
                    occupantWindowId: zone.occupantWindowId
                ))
            }

            let occupant = floatingZoneOccupant(on: screenId)
            if let occupant,
               let frame = windowController.actualFrameInAccessibilityCoordinates(for: occupant) {
                candidates.append(.init(
                    id: .floating(screenId: screenId),
                    frame: frame,
                    occupantWindowId: occupant.windowId
                ))
            } else if let barFrame = floatingIndicatorFrames(for: descriptor)?.accessibility {
                // Empty floating zone — or a filled one whose window frame is unreadable — sits at
                // its bottom-edge bar.
                candidates.append(.init(
                    id: .floating(screenId: screenId),
                    frame: barFrame,
                    occupantWindowId: occupant?.windowId
                ))
            }
        }
        return candidates
    }

    /// Resolves where navigation starts: the focused managed window's zone when it is among the
    /// candidates, otherwise the targeted zone. The anchor rectangle backs `nextSelection` when
    /// nothing is selected yet.
    private func zoneNavigationStart(
        candidates: [ZoneNavigation.Candidate]
    ) -> (focusedZoneId: NavigableZoneIdentifier?, targetedZoneId: NavigableZoneIdentifier?, anchor: ZoneNavigation.Anchor) {
        var focusedZoneId: NavigableZoneIdentifier?
        if let focusedId = currentFrontmostManagedWindowId,
           let managed = windowController.window(withId: focusedId),
           let destination = targetedDestination(for: managed) {
            focusedZoneId = navigableZoneIdentifier(for: destination)
        }

        let targetedZoneId = targetedZoneManager.targetedDestination.map(navigableZoneIdentifier(for:))

        func anchor(at id: NavigableZoneIdentifier?) -> ZoneNavigation.Anchor? {
            guard let id, let candidate = candidates.first(where: { $0.id == id }) else { return nil }
            return .init(frame: candidate.frame, screenId: id.screenId)
        }

        let fallback = ZoneNavigation.Anchor(frame: candidates[0].frame, screenId: candidates[0].id.screenId)
        return (
            focusedZoneId,
            targetedZoneId,
            anchor(at: focusedZoneId) ?? anchor(at: targetedZoneId) ?? fallback
        )
    }

    private func updateZoneNavigationDot(selection: ZoneNavigation.Selection?) {
        guard let selection,
              let candidate = zoneNavigationState?.candidates.first(where: { $0.id == selection.id }),
              let descriptor = descriptor(for: selection.id.screenId) else {
            zoneNavigationDotOverlay.hide()
            return
        }
        if selection.id.isFloating, candidate.occupantWindowId == nil,
           let barCocoaFrame = floatingIndicatorFrames(for: descriptor)?.cocoa {
            zoneNavigationDotOverlay.showHalfCircle(onBar: barCocoaFrame, screenCocoaFrame: descriptor.cocoaBounds)
            return
        }
        let screenFrame = descriptor.accessibilityToScreen(candidate.frame)
        let cocoaFrame = descriptor.screenToCocoa(screenFrame)
        zoneNavigationDotOverlay.show(centeredIn: cocoaFrame)
    }

    // MARK: - Move key (move the focused window into the selected zone)

    /// Synchronous decision for the interceptor's move key: with a focused managed window and a
    /// selected zone other than its own, clear the gesture and hand the actual move to the main
    /// queue, returning true so the interceptor ends the gesture. Returning false leaves the
    /// gesture engaged (nothing to move).
    private func requestZoneNavigationMove() -> Bool {
        guard let state = zoneNavigationState,
              let selection = state.selection,
              let focusedId = currentFrontmostManagedWindowId,
              let managed = windowController.window(withId: focusedId) else {
            return false
        }

        let destination = zoneDestination(for: selection.id)
        if let origin = targetedDestination(for: managed), origin == destination {
            return false
        }

        clearZoneNavigation()
        DispatchQueue.main.async { [weak self] in
            self?.performZoneNavigationMove(of: focusedId, to: destination)
        }
        return true
    }

    /// Move the focused window into `destination`. An occupied destination swaps: the occupant
    /// takes the moved window's origin — including across the tiling/floating boundary. (Without
    /// an origin to give it, the occupant is displaced through the normal placement path and
    /// minimizes.) Targeting follows the normal placement rules: the vacated origin does not steal
    /// the target, and filling the targeted zone retargets away.
    ///
    /// The origin is re-derived here, on the main queue, rather than carried over from the
    /// event-tap decision: everything below runs in one synchronous block against that live state,
    /// so an interleaved placement or topology change can't detach the partner into a stale zone.
    private func performZoneNavigationMove(
        of windowId: Int,
        to destination: TargetedZoneManager.TargetedDestination
    ) {
        guard let managed = windowController.window(withId: windowId) else {
            Logger.debug("Zone navigation move: window \(windowId) vanished; ignoring")
            return
        }
        guard destinationExists(destination) else {
            Logger.debug("Zone navigation move: destination \(destination) vanished; ignoring")
            return
        }
        let origin = targetedDestination(for: managed)
        if let origin, origin == destination {
            Logger.debug("Zone navigation move: window \(windowId) already at \(destination); ignoring")
            return
        }

        let reason = "zone-navigation-move"

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
            "Zone navigation move: window \(windowId) \(origin.map { "from \($0) " } ?? "")to \(destination)"
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
                retargetOnRemoval: false,
                forceRetargetAfterFill: false,
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
                retargetOnRemoval: false,
                forceRetargetAfterFill: false
            )
            recentlyPlacedInFloatingZone = managed.windowId
        }

        if let partner, let origin {
            windowPlacementManager.placeWindow(
                partner,
                into: origin,
                centerFloatingWindow: true,
                reason: "\(reason)-swap",
                retargetOnRemoval: false,
                forceRetargetAfterFill: false,
                activate: false
            )
            if case .floating = origin {
                recentlyPlacedInFloatingZone = partner.windowId
            }
        }

        syncWindowsToZones(recentlyPlacedInFloatingZone: recentlyPlacedInFloatingZone)
    }

    // MARK: - Show Launcher key (target the selected zone and open the Launcher)

    /// Synchronous decision for the interceptor's Show Launcher key: with a selected zone, clear the
    /// gesture and hand the retarget + Launcher show to the main queue, returning true so the
    /// interceptor ends the gesture. Returning false leaves it engaged (nothing selected).
    private func requestZoneNavigationLauncherShow() -> Bool {
        guard let state = zoneNavigationState,
              let selection = state.selection else {
            return false
        }

        let destination = zoneDestination(for: selection.id)
        clearZoneNavigation()
        DispatchQueue.main.async { [weak self] in
            self?.performZoneNavigationLauncherShow(at: destination)
        }
        return true
    }

    /// Target the selected zone — occupied or not — and open the Launcher anchored there, via the
    /// same explicit-gesture path as Control-Command-double-click.
    private func performZoneNavigationLauncherShow(at destination: TargetedZoneManager.TargetedDestination) {
        guard destinationExists(destination) else {
            Logger.debug("Zone navigation launcher-show: destination \(destination) vanished; ignoring")
            return
        }
        Logger.debug("Zone navigation launcher-show: targeting \(destination) and opening Launcher")
        retargetForUserGesture(
            destination,
            reason: "zone-navigation-launcher",
            openingLauncherWith: "zone-navigation-launcher"
        )
    }

    private func destinationExists(_ destination: TargetedZoneManager.TargetedDestination) -> Bool {
        switch destination {
        case .tiled(let key):
            return screenContexts[key.screenId]?.zoneController.zone(at: key.index) != nil
        case .floating(let screenId):
            return screenContexts[screenId] != nil
        }
    }

    private func occupant(of destination: TargetedZoneManager.TargetedDestination) -> ManagedWindow? {
        switch destination {
        case .tiled(let key):
            guard let zone = screenContexts[key.screenId]?.zoneController.zone(at: key.index),
                  let windowId = zone.occupantWindowId else {
                return nil
            }
            return windowController.window(withId: windowId)
        case .floating(let screenId):
            return floatingZoneOccupant(on: screenId)
        }
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

    private func zoneDestination(for id: NavigableZoneIdentifier) -> TargetedZoneManager.TargetedDestination {
        switch id {
        case let .tiling(screenId, index):
            return .tiled(ZoneKey(screenId: screenId, index: index))
        case let .floating(screenId):
            return .floating(screenId: screenId)
        }
    }

    private func navigableZoneIdentifier(for destination: TargetedZoneManager.TargetedDestination) -> NavigableZoneIdentifier {
        switch destination {
        case .tiled(let key):
            return .tiling(screenId: key.screenId, index: key.index)
        case .floating(let screenId):
            return .floating(screenId: screenId)
        }
    }
}
