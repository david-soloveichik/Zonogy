import AppKit
import Foundation

/// Keyboard zone navigation: builds the navigable zone set, resolves the selection as the gesture
/// proceeds — the arrows step it, the jump keys jump it to a cell of the current screen (adding the
/// zone when the cell has none), to the floating zone, or to a display's last-used window — shows
/// it with the blue-circle overlay, and commits on release (focus a filled zone's window, or
/// target an empty zone), on the Move Focused Window to Destination key (move the focused window
/// into the selected zone; see `AppController+MoveFocusedWindow`), or on the Show Launcher key
/// (target the selected zone and open the Launcher there). The Add Zone and Remove Zone keys
/// change the topology under the gesture — add a zone for the selected zone, or remove the
/// selected zone — and the Minimize key minimizes the selected zone's window (or removes an empty
/// tiling zone); the gesture continues around the result. The gesture lifecycle is driven by
/// `ZoneNavigationInterceptor`; the selection policy is the pure `ZoneNavigation`.
extension AppController {
    /// Live state for an in-progress zone-navigation gesture. Candidates and screens are
    /// snapshotted at engage time so the circle stays stable for the (brief) duration of the
    /// gesture; commits re-check live occupancy.
    struct ZoneNavigationState {
        let candidates: [ZoneNavigation.Candidate]
        let screens: [ZoneNavigation.Screen]
        var selection: ZoneNavigation.Selection
        /// The interceptor gesture this state belongs to, ended when the state is cleared.
        let engagement: ZoneNavigationInterceptor.Engagement
    }
}

extension AppController: ZoneNavigationInterceptorDelegate {
    func zoneNavigation(_ interceptor: ZoneNavigationInterceptor, didBegin key: ZoneNavigationKey, engagement: ZoneNavigationInterceptor.Engagement) {
        beginZoneNavigation(key: key, engagement: engagement)
    }

    func zoneNavigation(_ interceptor: ZoneNavigationInterceptor, didPress key: ZoneNavigationKey) {
        pressZoneNavigation(key: key)
    }

    func zoneNavigationDidPressMoveKey(_ interceptor: ZoneNavigationInterceptor) {
        performZoneNavigationMove()
    }

    func zoneNavigationDidPressShowLauncherKey(_ interceptor: ZoneNavigationInterceptor) {
        performZoneNavigationLauncherShow()
    }

    func zoneNavigationDidPressAddZoneKey(_ interceptor: ZoneNavigationInterceptor) {
        performZoneNavigationAdd()
    }

    func zoneNavigationDidPressRemoveZoneKey(_ interceptor: ZoneNavigationInterceptor) {
        performZoneNavigationRemove()
    }

    func zoneNavigationDidPressMinimizeKey(_ interceptor: ZoneNavigationInterceptor) {
        performZoneNavigationMinimize()
    }

    func zoneNavigationDidCommit(_ interceptor: ZoneNavigationInterceptor) {
        commitZoneNavigation()
    }

    func zoneNavigationDidCancel(_ interceptor: ZoneNavigationInterceptor) {
        cancelZoneNavigation(reason: "interceptor-cancel")
    }
}

extension AppController {
    private func beginZoneNavigation(key: ZoneNavigationKey, engagement: ZoneNavigationInterceptor.Engagement) {
        // Admission is re-checked here: the interceptor's `canBegin` gate lags a chooser that opened
        // while this begin was queued behind it.
        guard !cmdTabController.isActive, !winShotChooserController.isActive else {
            Logger.debug("Zone navigation (\(key)): a chooser opened first; ignoring")
            zoneNavigationInterceptor.endEngagement(engagement)
            return
        }

        let snapshot = zoneNavigationSnapshot()
        let start = zoneNavigationStart(candidates: snapshot.candidates)
        let selection: ZoneNavigation.Selection?
        switch key {
        case .move(let direction):
            selection = ZoneNavigation.initialSelection(
                direction: direction,
                focusedZoneId: start.focusedZoneId,
                targetedZoneId: start.targetedZoneId,
                fallbackZoneId: start.fallbackZoneId,
                candidates: snapshot.candidates,
                screens: snapshot.screens
            )
        case .zone, .floatingZone, .display:
            // A jump's start zone only fixes the current screen — and where the circle appears
            // when the jump resolves nothing — so select it in place and then apply the press
            // like any later one.
            selection = ZoneNavigation.startZone(
                focusedZoneId: start.focusedZoneId,
                targetedZoneId: start.targetedZoneId,
                fallbackZoneId: start.fallbackZoneId,
                candidates: snapshot.candidates
            ).map { .init(id: $0.id, trail: []) }
        }
        guard let selection else {
            // Only an empty snapshot resolves nothing. The interceptor's `canBegin` already gates on
            // `hasNavigableZone()`, so this only happens if the screens changed between engaging
            // and now. End the interceptor's gesture too so it stops swallowing keys for a dead
            // session.
            Logger.debug("Zone navigation (\(key)): no navigable zones; ignoring")
            zoneNavigationInterceptor.endEngagement(engagement)
            clearZoneNavigation()
            return
        }

        zoneNavigationState = ZoneNavigationState(
            candidates: snapshot.candidates,
            screens: snapshot.screens,
            selection: selection,
            engagement: engagement
        )
        updateZoneNavigationDot(selection: selection.id)
        Logger.debug("Zone navigation begun (\(key)); selection: \(selection.id)")
        if key.isJump {
            pressZoneNavigation(key: key)
        }
    }

    /// A selection key while engaged: an arrow steps from the current selection; a jump key jumps —
    /// to a cell of the current screen (adding the zone first when the cell has none, which
    /// rebuilds the gesture around the new zone), to the current screen's floating zone, or to a
    /// display's last-used window. Jumps start a fresh back-out trail. A jump that resolves
    /// nothing (a display that doesn't exist, a barless screen) leaves the selection unchanged.
    private func pressZoneNavigation(key: ZoneNavigationKey) {
        guard var state = zoneNavigationState else { return }
        let current = state.selection
        let next: ZoneNavigation.Selection
        switch key {
        case .move(let direction):
            next = ZoneNavigation.nextSelection(
                direction: direction,
                currentSelection: current,
                candidates: state.candidates,
                screens: state.screens
            )
        case .zone(let cell):
            let screenId = current.id.screenId
            guard let context = screenContexts[screenId],
                  let resolution = ZoneNavigation.cellSelection(
                      cell: cell,
                      screenId: screenId,
                      sideCapacity: context.zoneController.layoutStyle.sideCapacity(cell.side),
                      candidates: state.candidates
                  ) else {
                return
            }
            switch resolution {
            case .select(let id):
                next = .init(id: id, trail: [])
            case .add(let side):
                performZoneNavigationAdd(on: screenId, side: side)
                return
            }
        case .floatingZone:
            let barId = NavigableZoneIdentifier.floating(screenId: current.id.screenId)
            guard state.candidates.contains(where: { $0.id == barId }) else { return }
            next = .init(id: barId, trail: [])
        case .display(let ordinal):
            guard let id = ZoneNavigation.displaySelection(
                ordinal: ordinal,
                targetedZoneId: targetedZoneManager.targetedDestination.map(navigableZoneIdentifier(for:)),
                candidates: state.candidates,
                screens: state.screens
            ) else {
                return
            }
            next = .init(id: id, trail: [])
        }
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
            // An explicit window selection: the user has moved past whatever they just
            // minimized, so stop skipping those windows in CmdTab's initial selection.
            recentUserMinimizeTracker.clearAllMarks()
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
                targetedZoneManager.setFloatingTarget(on: screenId, reason: "zone-navigation-commit", explicit: true)
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
    /// change driven by the gesture's own keys (Add Zone, Remove Zone, or a cell key adding its
    /// zone), which rebuilds the gesture around the new topology instead (see
    /// `continueZoneNavigation`).
    internal func cancelZoneNavigationForTopologyChange(reason: String) {
        // Which screens are navigable may have changed with the topology.
        syncKeyboardTapGates()
        // A topology change reindexes zones, so a pending hold follow-up's captured zone index
        // may now denote a different zone; drop it regardless of who drove the change. (A
        // follow-up's own zone operation runs after the pending record is cleared, so this
        // never cancels the follow-up performing it.) The full-screen pause-change caller
        // cancels deliberately too — including a change the press itself caused, e.g. by
        // minimizing a managed window that had entered full screen (such windows keep their
        // zone assignment): a follow-up must not fire into a display in the middle of a
        // full-screen transition. WinShot restores and display-change scheduling cancel at
        // their own sites.
        cancelShortcutHoldFollowUp(reason: "topology-\(reason)")
        guard !zoneNavigationDrivenTopologyChange else { return }
        zoneNavigationInterceptor.resetEngagement()
        cancelZoneNavigation(reason: reason)
    }

    /// Drops the gesture state and ends the interceptor gesture it belonged to. The ending is scoped
    /// to that gesture: after a release or Escape the interceptor has already ended it, and a
    /// gesture engaged since is untouched.
    private func clearZoneNavigation() {
        if let engagement = zoneNavigationState?.engagement {
            zoneNavigationInterceptor.endEngagement(engagement)
        }
        zoneNavigationState = nil
        zoneNavigationDotOverlay.hide()
    }

    /// Cheap "is there anything to navigate?" check, mirrored into the interceptor's `canBegin`
    /// gate. Zones always exist, so this rules out exactly the all-screens-paused case: the gesture
    /// engages only where Zonogy UI may appear.
    internal func hasNavigableZone() -> Bool {
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
    /// classification). Occupants rank by the shared managed-window recency order — the focused
    /// window first, since its activity is recorded only after a stability delay — for the
    /// display keys' last-used entry. Only navigable (unpaused) screens contribute — see
    /// `isScreenNavigable`.
    private func zoneNavigationSnapshot() -> (candidates: [ZoneNavigation.Candidate], screens: [ZoneNavigation.Screen]) {
        var recencyRanks: [Int: Int] = [:]
        let recencyOrder = [currentFrontmostManagedWindowId].compactMap { $0 }
            + windowController.allWindowsOrderedByRecency().map(\.windowId)
        for windowId in recencyOrder where recencyRanks[windowId] == nil {
            recencyRanks[windowId] = recencyRanks.count
        }
        // An occupant absent from the recency order (not expected) still counts as occupied.
        func recencyRank(of windowId: Int?) -> Int? {
            windowId.map { recencyRanks[$0] ?? Int.max }
        }

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
                    recencyRank: recencyRank(of: zone.occupantWindowId),
                    place: .init(side: zone.side, row: row)
                ))
            }

            // The bar is the floating zone's fixed home in the gesture; occupancy only matters
            // for what a commit does, for selecting a filled target in place, and for the
            // display keys' last-used entry.
            if let barFrame = floatingIndicatorFrames(for: descriptor)?.accessibility {
                candidates.append(.init(
                    id: .floating(screenId: screenId),
                    frame: barFrame,
                    recencyRank: recencyRank(of: floatingZoneOccupant(on: screenId)?.windowId),
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

    /// The interceptor's Move key, which has ended the gesture: drop the gesture state and, given a
    /// focused managed window not already in the selected zone, perform the move
    /// (`moveFocusedWindow`, shared with the Move Focused Window to Destination shortcut).
    private func performZoneNavigationMove() {
        guard let state = zoneNavigationState else { return }
        clearZoneNavigation()

        let destination = zoneDestination(for: state.selection.id)
        guard let focusedId = currentFrontmostManagedWindowId,
              let managed = windowController.window(withId: focusedId),
              targetedDestination(for: managed) != destination else {
            Logger.debug("Zone navigation move: nothing to move into \(state.selection.id)")
            return
        }
        moveFocusedWindow(focusedId, to: destination, reason: "zone-navigation-move")
    }

    // MARK: - Show Launcher key (target the selected zone and open the Launcher)

    /// The interceptor's Show Launcher key, which has ended the gesture: drop the gesture state, then
    /// retarget and show the Launcher at the selected zone.
    private func performZoneNavigationLauncherShow() {
        guard let state = zoneNavigationState else {
            return
        }

        let destination = zoneDestination(for: state.selection.id)
        clearZoneNavigation()
        performZoneNavigationLauncherShow(at: destination)
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

    // MARK: - Add Zone / Remove Zone / Minimize keys (act on the selected zone mid-gesture)

    /// Add Zone key: add a zone on the selected zone's screen — stacking into the selected zone's
    /// column when it is alone there (`ZoneNavigation.stackedAddSide`), otherwise on the layout's
    /// normal fill-order side.
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
        performZoneNavigationAdd(on: screenId, side: side)
    }

    /// Add a zone on `screenId` — on `side`, or on the layout's normal fill-order side when nil —
    /// and continue the gesture with the circle on the new zone. A failed add (the layout style's
    /// zone maximum is reached) leaves the gesture unchanged. Shared by the Add Zone key and the
    /// cell keys.
    private func performZoneNavigationAdd(on screenId: CGDirectDisplayID, side: ZoneSide?) {
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

    /// Minimize key: minimize the selected zone's window, via the same behavior as the minimize
    /// shortcuts (optimistic retarget + Launcher, with the emptied-zone bookkeeping left to the
    /// miniaturize notification). The zones are unchanged, so the gesture simply stays engaged:
    /// the snapshot and back-out trail remain valid and the circle stays on the now-empty zone.
    /// On an empty zone the key is the Remove Zone behavior instead, so one key cleans up either
    /// way — minimize a filled zone, remove an empty one (still ignoring the floating zone and a
    /// screen's only tiling zone).
    private func performZoneNavigationMinimize() {
        guard let state = zoneNavigationState else { return }
        let selectionId = state.selection.id
        guard let occupant = occupant(of: zoneDestination(for: selectionId)) else {
            performZoneNavigationRemove()
            return
        }
        Logger.debug("Zone navigation minimize: minimizing window \(occupant.windowId) in \(selectionId)")
        // Mirror the cursor minimize: leave UnderCovers before putting away its floating occupant.
        endUnderCovers(on: selectionId.screenId, reason: "zone-navigation-minimize", recreatePlaceholders: false)
        userInitiatedMinimize(occupant, optimisticReason: "zone-navigation-minimize-optimistic")
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
        guard let state = zoneNavigationState else { return }
        let snapshot = zoneNavigationSnapshot()
        guard let selectionId = chooseSelection(snapshot.candidates),
              snapshot.candidates.contains(where: { $0.id == selectionId }) else {
            Logger.debug("Zone navigation \(reason): no selection resolves after the topology change; ending gesture")
            clearZoneNavigation()
            return
        }
        zoneNavigationState = ZoneNavigationState(
            candidates: snapshot.candidates,
            screens: snapshot.screens,
            selection: .init(id: selectionId, trail: []),
            engagement: state.engagement
        )
        updateZoneNavigationDot(selection: selectionId)
        Logger.debug("Zone navigation \(reason): continuing with selection \(selectionId)")
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
