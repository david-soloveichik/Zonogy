import AppKit
import Foundation

/// Keyboard zone navigation: builds the navigable zone set, resolves the
/// selection as the gesture proceeds, shows it with the blue-circle overlay, and commits on release
/// (focus a filled zone's window, or target an empty zone), on the move key (move the focused
/// window into the selected zone), or on the Show Launcher key (target the selected zone and open the
/// Launcher there). The Add Zone and Remove Zone keys change the topology under the gesture — add
/// a zone for the selected zone, or remove the selected zone — and the gesture continues around
/// the result. The gesture lifecycle is driven by `ZoneNavigationInterceptor`; the selection
/// policy is the pure `ZoneNavigation`.
extension AppController {
    /// Live state for an in-progress zone-navigation gesture. Candidates and screens are
    /// snapshotted at engage time so the circle stays stable for the (brief) duration of the
    /// gesture; commits re-check live occupancy.
    struct ZoneNavigationState {
        let candidates: [ZoneNavigation.Candidate]
        let screens: [ZoneNavigation.Screen]
        var selection: ZoneNavigation.Selection
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

    func zoneNavigationDidPressAddZoneKey(_ interceptor: ZoneNavigationInterceptor) {
        performZoneNavigationAdd()
    }

    func zoneNavigationDidPressRemoveZoneKey(_ interceptor: ZoneNavigationInterceptor) {
        performZoneNavigationRemove()
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
        let snapshot = zoneNavigationSnapshot()
        guard !snapshot.candidates.isEmpty else {
            // `shouldBegin` already gates on `hasNavigableZone()`, so this only happens if the
            // screens changed between engaging and now. Drop the interceptor's engaged state too so
            // it stops swallowing arrows for a dead session.
            Logger.debug("Zone navigation (\(direction)): no navigable zones; ignoring")
            zoneNavigationInterceptor.resetEngagement()
            clearZoneNavigation()
            return
        }

        let start = zoneNavigationStart(candidates: snapshot.candidates)
        guard let selection = ZoneNavigation.initialSelection(
            direction: direction,
            focusedZoneId: start.focusedZoneId,
            targetedZoneId: start.targetedZoneId,
            fallbackZoneId: start.fallbackZoneId,
            candidates: snapshot.candidates,
            screens: snapshot.screens
        ) else {
            // Unreachable with non-empty candidates (the fallback start always resolves).
            zoneNavigationInterceptor.resetEngagement()
            clearZoneNavigation()
            return
        }

        zoneNavigationState = ZoneNavigationState(
            candidates: snapshot.candidates,
            screens: snapshot.screens,
            selection: selection
        )
        updateZoneNavigationDot(selection: selection.id)
        Logger.debug("Zone navigation begun (\(direction)); selection: \(selection.id)")
    }

    private func moveZoneNavigation(direction: ZoneNavigationDirection) {
        guard var state = zoneNavigationState else { return }
        let next = ZoneNavigation.nextSelection(
            direction: direction,
            currentSelection: state.selection,
            candidates: state.candidates,
            screens: state.screens
        )
        state.selection = next
        zoneNavigationState = state
        updateZoneNavigationDot(selection: next.id)
    }

    /// Modifier release: focus the selected zone's window, or target the selected zone when empty.
    /// Occupancy is re-read live at commit time (the snapshot only drives selection).
    private func commitZoneNavigation() {
        guard let state = zoneNavigationState else { return }
        clearZoneNavigation()

        let selection = state.selection
        let destination = zoneDestination(for: selection.id)
        if let occupant = occupant(of: destination) {
            Logger.debug("Zone navigation focusing window \(occupant.windowId) in \(selection.id)")
            // Focusing hands the user to that window: dismiss the Launcher now rather than
            // waiting on the focus-shift notification — targeting is unchanged by a focus
            // commit, so no follow-target refresh would hide it.
            dismissLauncherIfActive()
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
            autoShowLauncherIfEmptyTargetedFloatingZone()
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
    /// mouse-driven changes (placeholder ×, add-zone pill) are covered too. The one exception is a
    /// change driven by the gesture's own Add/Remove Zone keys, which rebuilds the gesture around
    /// the new topology instead (see `continueZoneNavigation`).
    internal func cancelZoneNavigationForTopologyChange(reason: String) {
        guard !zoneNavigationDrivenTopologyChange else { return }
        zoneNavigationInterceptor.resetEngagement()
        cancelZoneNavigation(reason: reason)
    }

    private func clearZoneNavigation() {
        zoneNavigationState = nil
        zoneNavigationDotOverlay.hide()
    }

    /// Cheap "is there anything to navigate?" check used to gate engagement synchronously in the
    /// event-tap callback. Zones always exist, so this rules out exactly the all-screens-paused
    /// case: the gesture engages only where Zonogy UI may appear.
    private func hasNavigableZone() -> Bool {
        screenOrder.contains { isScreenNavigable($0) }
    }

    /// A screen is navigable when it holds zones and is not paused for full-screen. Stricter
    /// than `isScreenTargetable`, which keeps one fallback screen targetable when every screen
    /// is paused so a target always exists: the gesture draws UI, and no Zonogy UI appears on a
    /// paused screen, so that fallback is deliberately out of navigation's reach.
    private func isScreenNavigable(_ screenId: CGDirectDisplayID) -> Bool {
        screenContexts[screenId] != nil && !fullScreenDisplayIds.contains(screenId)
    }

    /// Every navigable zone plus every navigable screen. Each tiling zone carries its rectangle
    /// in accessibility coordinates and its structural place (column side and stack row, driving
    /// the within-screen moves); each screen contributes its floating zone at its bottom-edge
    /// bar, occupied or not, and its full frame (the input to the cross-screen direction
    /// classification). Only navigable (unpaused) screens contribute — see `isScreenNavigable`.
    private func zoneNavigationSnapshot() -> (candidates: [ZoneNavigation.Candidate], screens: [ZoneNavigation.Screen]) {
        var candidates: [ZoneNavigation.Candidate] = []
        var screens: [ZoneNavigation.Screen] = []
        for screenId in screenOrder {
            guard isScreenNavigable(screenId),
                  let context = screenContexts[screenId] else {
                continue
            }
            let descriptor = context.descriptor
            screens.append(.init(
                id: screenId,
                frame: descriptor.screenToAccessibility(descriptor.cocoaToScreen(descriptor.cocoaBounds))
            ))
            // Within a side, the lower index stacks on top (mirroring `ZoneLayout`).
            let zones = context.zoneController.allZones.sorted { $0.index < $1.index }
            var stackedAbove: [ZoneSide: Int] = [:]
            for zone in zones {
                let position = stackedAbove[zone.side, default: 0]
                stackedAbove[zone.side] = position + 1
                let row: ZoneNavigation.StackRow = context.zoneController.zoneCount(on: zone.side) == 1
                    ? .full
                    : (position == 0 ? .top : .bottom)
                candidates.append(.init(
                    id: .tiling(screenId: screenId, index: zone.index),
                    frame: descriptor.screenToAccessibility(zone.frame),
                    isOccupied: zone.occupantWindowId != nil,
                    place: .init(side: zone.side, row: row)
                ))
            }

            // The bar is the floating zone's fixed home in the gesture; occupancy only matters
            // for what a commit does (and for selecting a filled target in place).
            if let barFrame = floatingIndicatorFrames(for: descriptor)?.accessibility {
                candidates.append(.init(
                    id: .floating(screenId: screenId),
                    frame: barFrame,
                    isOccupied: floatingZoneOccupant(on: screenId) != nil,
                    place: nil
                ))
            }
        }
        return (candidates, screens)
    }

    /// Resolves where navigation starts. While the Launcher is open the gesture starts from the
    /// Launcher's zone — the targeted zone it is anchored to — rather than the focused window's.
    /// Otherwise it starts from the focused managed window's zone when it is among the candidates,
    /// else the targeted zone; the first candidate covers the remaining case.
    private func zoneNavigationStart(
        candidates: [ZoneNavigation.Candidate]
    ) -> (focusedZoneId: NavigableZoneIdentifier?, targetedZoneId: NavigableZoneIdentifier?, fallbackZoneId: NavigableZoneIdentifier?) {
        var focusedZoneId: NavigableZoneIdentifier?
        if !launcherController.isActive,
           let focusedId = currentFrontmostManagedWindowId,
           let managed = windowController.window(withId: focusedId),
           let destination = targetedDestination(for: managed) {
            focusedZoneId = navigableZoneIdentifier(for: destination)
        }

        let targetedZoneId = targetedZoneManager.targetedDestination.map(navigableZoneIdentifier(for:))
        return (focusedZoneId, targetedZoneId, candidates.first?.id)
    }

    private func updateZoneNavigationDot(selection: NavigableZoneIdentifier) {
        guard let candidate = zoneNavigationState?.candidates.first(where: { $0.id == selection }),
              let descriptor = descriptor(for: selection.screenId) else {
            zoneNavigationDotOverlay.hide()
            return
        }
        let screenFrame = descriptor.accessibilityToScreen(candidate.frame)
        let cocoaFrame = descriptor.screenToCocoa(screenFrame)
        if selection.isFloating {
            zoneNavigationDotOverlay.showHalfCircle(onBar: cocoaFrame, screenCocoaFrame: descriptor.cocoaBounds)
        } else {
            zoneNavigationDotOverlay.show(centeredIn: cocoaFrame)
        }
    }

    // MARK: - Move key (move the focused window into the selected zone)

    /// Synchronous decision for the interceptor's move key: with a focused managed window and a
    /// selected zone other than its own, clear the gesture and hand the actual move to the main
    /// queue, returning true so the interceptor ends the gesture. Returning false leaves the
    /// gesture engaged (nothing to move).
    private func requestZoneNavigationMove() -> Bool {
        guard let state = zoneNavigationState,
              let focusedId = currentFrontmostManagedWindowId,
              let managed = windowController.window(withId: focusedId) else {
            return false
        }

        let destination = zoneDestination(for: state.selection.id)
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

    /// Synchronous decision for the interceptor's Show Launcher key: clear the gesture and hand
    /// the retarget + Launcher show to the main queue, returning true so the interceptor ends the
    /// gesture. Returning false leaves it engaged (no gesture state).
    private func requestZoneNavigationLauncherShow() -> Bool {
        guard let state = zoneNavigationState else {
            return false
        }

        let destination = zoneDestination(for: state.selection.id)
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

    // MARK: - Add Zone / Remove Zone keys (change the topology under the gesture)

    /// Add Zone key: add a zone on the selected zone's screen — stacking into the selected zone's
    /// column when it is alone there (`ZoneNavigation.stackedAddSide`), otherwise on the layout's
    /// normal fill-order side — and continue the gesture with the circle on the new zone. A failed
    /// add (the layout style's zone maximum is reached) leaves the gesture unchanged.
    private func performZoneNavigationAdd() {
        guard let state = zoneNavigationState else { return }
        let selectionId = state.selection.id
        let screenId = selectionId.screenId
        guard let context = screenContexts[screenId] else { return }

        var side: ZoneSide?
        if case let .tiling(_, index) = selectionId,
           let zone = context.zoneController.zone(at: index) {
            side = ZoneNavigation.stackedAddSide(
                selectedZoneSide: zone.side,
                zonesOnScreen: context.zoneController.allZones.count,
                zonesOnSelectedSide: context.zoneController.zoneCount(on: zone.side),
                selectedSideCapacity: context.zoneController.layoutStyle.sideCapacity(zone.side)
            )
        }

        let newZone = performZoneNavigationTopologyChange {
            addZone(on: screenId, side: side, announce: true)
        }
        guard let newZone else {
            Logger.debug("Zone navigation add: screen \(screenContextStore.loggingIndex(for: screenId)) is at its zone maximum; gesture unchanged")
            return
        }
        continueZoneNavigation(reason: "add-zone") { _ in
            .tiling(screenId: screenId, index: newZone.index)
        }
    }

    /// Remove Zone key: remove the selected tiling zone — minimizing its occupant via the
    /// standard removal path — and continue the gesture with the circle on the zone that takes
    /// over the removed space. Ignored when the floating zone or a screen's only tiling zone is
    /// selected.
    private func performZoneNavigationRemove() {
        guard let state = zoneNavigationState else { return }
        guard case let .tiling(screenId, index) = state.selection.id else {
            Logger.debug("Zone navigation remove: floating zone selected; ignoring")
            return
        }
        // Pre-check removability so an ignored press is side-effect-free (performRemoveZone would
        // still exit UnderCovers before failing its own last-zone guard).
        guard let context = screenContexts[screenId],
              context.zoneController.allZones.count > 1,
              let removedZone = context.zoneController.zone(at: index) else {
            Logger.debug("Zone navigation remove: zone \(index) is not removable on screen \(screenContextStore.loggingIndex(for: screenId)); ignoring")
            return
        }
        // The removed frame is read live rather than from the gesture snapshot: zone resizes
        // don't cancel the gesture, so snapshot frames can be stale by removal time.
        let removedFrame = context.descriptor.screenToAccessibility(removedZone.frame)

        let removed = performZoneNavigationTopologyChange {
            performRemoveZone(at: index, on: screenId, announce: true, context: context)
        }
        guard removed != nil else {
            Logger.debug("Zone navigation remove: zone \(index) on screen \(screenContextStore.loggingIndex(for: screenId)) vanished; gesture unchanged")
            return
        }
        continueZoneNavigation(reason: "remove-zone") { candidates in
            ZoneNavigation.selectionAfterRemoval(
                removedFrame: removedFrame,
                screenId: screenId,
                candidates: candidates
            )
        }
    }

    /// Run a gesture-driven topology mutation with the canonical topology cancel suppressed, so
    /// the gesture survives for its rebuild. The mutation and the rebuild that follows run in one
    /// synchronous main-queue block, so no other gesture callback can interleave with the
    /// suppressed state.
    private func performZoneNavigationTopologyChange<T>(_ mutate: () -> T) -> T {
        zoneNavigationDrivenTopologyChange = true
        defer { zoneNavigationDrivenTopologyChange = false }
        return mutate()
    }

    /// Rebuild the gesture around topology its own action just changed: fresh candidates, the
    /// selection `chooseSelection` picks from them, and a reset back-out trail (the old trail's
    /// zones may no longer exist). Ends the gesture if it died during the change or no selection
    /// resolves.
    private func continueZoneNavigation(
        reason: String,
        chooseSelection: ([ZoneNavigation.Candidate]) -> NavigableZoneIdentifier?
    ) {
        guard zoneNavigationState != nil else { return }
        let snapshot = zoneNavigationSnapshot()
        guard let selectionId = chooseSelection(snapshot.candidates),
              snapshot.candidates.contains(where: { $0.id == selectionId }) else {
            Logger.debug("Zone navigation \(reason): no selection resolves after the topology change; ending gesture")
            zoneNavigationInterceptor.resetEngagement()
            clearZoneNavigation()
            return
        }
        zoneNavigationState = ZoneNavigationState(
            candidates: snapshot.candidates,
            screens: snapshot.screens,
            selection: .init(id: selectionId, trail: [])
        )
        updateZoneNavigationDot(selection: selectionId)
        Logger.debug("Zone navigation \(reason): continuing with selection \(selectionId)")
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
