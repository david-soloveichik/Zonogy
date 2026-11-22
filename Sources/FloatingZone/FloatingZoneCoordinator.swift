import AppKit

/// Where a window placed into a floating zone goes.
enum FloatingPlacement: Equatable {
    /// While the zone is explicitly targeted and another window occupies it, that occupant's frame,
    /// which the incoming window takes over; otherwise centered at the window's own floating size.
    case standard
    /// A window dropped into the zone, which counts as explicitly targeting it: the occupant's frame
    /// when occupied, otherwise centered.
    case dropped
    /// The window keeps its current frame (a drag conversion, or a window already in place).
    case currentFrame
    /// This frame, in the destination display's screen-local coordinates (a snapshot restore, a
    /// drag revert, or a swap that already took the occupant out of the zone).
    case frame(CGRect)
}

/// Defines the operations the floating-zone coordinator can call back into.
protocol FloatingZoneCoordinatorHost: AnyObject {
    var windowController: WindowController { get }
    var targetedZoneManager: TargetedZoneManager { get }
    var screenContexts: [CGDirectDisplayID: ScreenContext] { get }
    var screenContextStore: ScreenContextStore { get }
    var windowPlacementManager: WindowPlacementManager { get }
    func minimizeWindowProgrammatically(_ managed: ManagedWindow, reason: String)
    func queueDeferredMinimization(windowId: Int, reason: String)
    func cancelPendingMinimization(windowId: Int)
    func removeWindowFromAllZones(windowId: Int, reason: String, retarget: Bool, logIfUnassigned: Bool)

    func refreshResizeHandles()
    func descriptor(for screenId: CGDirectDisplayID) -> ScreenDescriptor?
    func setManagedWindow(_ managed: ManagedWindow, screenId: CGDirectDisplayID, zoneIndex: Int?)
    func clearManagedWindowZone(_ managed: ManagedWindow)
    func addZone(on screenId: CGDirectDisplayID, side: ZoneSide?, forDrop: Bool) -> Zone?
    func addZoneIndicatorHitAreas() -> [AddZonePillKey: CGRect]
    func refreshIndicators()
    func updateFloatingIndicatorHighlight(screenId: CGDirectDisplayID?)
    func activeScreenId() -> CGDirectDisplayID
    func detectScreenId(for window: ManagedWindow) -> CGDirectDisplayID?
    func screenIdForAccessibilityFrame(_ frame: CGRect) -> CGDirectDisplayID?
    func shouldProtectFloatingZoneOccupant(windowId: Int) -> Bool
    var isMouseGestureInProgress: Bool { get }
    func scheduleFloatingZoneProtection(windowId: Int)
    func clearFloatingZoneProtection(windowId: Int)
    func floatingOccupantEvicted(windowId: Int)
    func activateFloatingZoneWindow(_ managed: ManagedWindow, reason: String)
}

/// Centralizes floating-zone occupant bookkeeping, placement, targeting, and occlusion checks.
final class FloatingZoneCoordinator {
    private struct TiledFocusContext {
        let window: ManagedWindow
        let pid: pid_t
        let screenId: CGDirectDisplayID?
    }

    weak var host: FloatingZoneCoordinatorHost?
    private let displacedWindowCoordinator: DisplacedWindowCoordinator
    private(set) var occupants: [CGDirectDisplayID: Int] = [:] {
        didSet {
            // A drop arrival hold belongs to an occupancy: it ends when its window leaves the
            // floating zones and does not return with a later placement.
            dropArrivalHoldDeadlines = dropArrivalHoldDeadlines.filter { occupants.values.contains($0.key) }
        }
    }
    /// Per-window remembered floating-zone size. Updated whenever the user resizes a window while
    /// it is a floating-zone occupant or the window takes a frame in a floating zone (an
    /// occupant's or a restored one), and cleared only when the window is destroyed. Applied on
    /// subsequent placements into an empty floating zone so a window returns to its last floating size.
    private var rememberedSizesByWindowId: [Int: CGSize] = [:]
    /// Occupants whose occlusion- and focus-driven minimization waits, until the given deadline,
    /// for the window a drop into their floating zone opens.
    private var dropArrivalHoldDeadlines: [Int: Date] = [:]

    init(host: FloatingZoneCoordinatorHost, displacedWindowCoordinator: DisplacedWindowCoordinator) {
        self.host = host
        self.displacedWindowCoordinator = displacedWindowCoordinator
    }

    /// After a drop into `screenId`'s floating zone, holds the occlusion- and focus-driven
    /// minimization of its occupant for `duration`: the window the drop opens, which its
    /// application can take a moment to build (often activating its other windows first), then
    /// still finds the occupant to replace and takes over its frame.
    func holdOcclusionMinimizationForDrop(on screenId: CGDirectDisplayID, duration: TimeInterval) {
        guard let occupantId = occupants[screenId] else {
            return
        }
        dropArrivalHoldDeadlines[occupantId] = Date().addingTimeInterval(duration)
    }

    private func isHeldForDropArrival(_ windowId: Int) -> Bool {
        guard let deadline = dropArrivalHoldDeadlines[windowId] else {
            return false
        }
        if Date() >= deadline {
            dropArrivalHoldDeadlines.removeValue(forKey: windowId)
            return false
        }
        return true
    }

    func rememberSize(for windowId: Int, size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        rememberedSizesByWindowId[windowId] = size
        Logger.debug("FloatingZoneSize: remembered size \(size) for window \(windowId)")
    }

    func clearRememberedSize(for windowId: Int) {
        if rememberedSizesByWindowId.removeValue(forKey: windowId) != nil {
            Logger.debug("FloatingZoneSize: cleared remembered size for window \(windowId)")
        }
    }

    private func rememberedSize(for windowId: Int) -> CGSize? {
        guard let size = rememberedSizesByWindowId[windowId],
              size.width > 0, size.height > 0 else {
            return nil
        }
        return size
    }

    func occupant(on screenId: CGDirectDisplayID) -> ManagedWindow? {
        guard let host, let windowId = occupants[screenId] else {
            return nil
        }
        return host.windowController.window(withId: windowId)
    }

    func isWindowInFloatingZone(_ windowId: Int) -> Bool {
        return occupants.values.contains(windowId)
    }

    /// Defaults the displacement strategy to `.synchronous` (Zonogy-initiated swap, no
    /// app-launch unminimize storm to fight). Callers that propagate from `placeNewWindow`
    /// (any "a window arrived" placement targeting the floating zone) pass `.deferred` to
    /// avoid an infinite minimize/unminimize loop with apps restoring their session windows.
    func assign(
        _ managed: ManagedWindow,
        to screenId: CGDirectDisplayID,
        placement: FloatingPlacement = .standard,
        activate: Bool = true,
        reason: String,
        displacement: DisplacementStrategy = .synchronous
    ) {
        guard let host else { return }

        host.cancelPendingMinimization(windowId: managed.windowId)

        if isWindowInFloatingZone(managed.windowId),
           let existingScreenId = occupants.first(where: { $0.value == managed.windowId })?.key {
            // Reassigning a window that's already in a floating zone (e.g. screen migration).
            // Avoid a full clear cycle so we don't accidentally change targeting state.
            host.clearFloatingZoneProtection(windowId: managed.windowId)
            occupants.removeValue(forKey: existingScreenId)
        }

        // Resolved before the replacement below evicts the occupant, whose frame the incoming
        // window may take over.
        let descriptor = host.descriptor(for: screenId)
        let target: (frame: CGRect, isTaken: Bool)? = {
            switch placement {
            case .standard, .dropped:
                return descriptor.map {
                    standardPlacement(
                        for: managed,
                        on: screenId,
                        descriptor: $0,
                        keepingOccupantFrame: placement == .dropped || isExplicitlyTargeted(screenId),
                        queryingApplication: true
                    )
                }
            case .frame(let frame):
                return (frame, true)
            case .currentFrame:
                return nil
            }
        }()

        let displacedMinimizeReason = "\(reason)-displaced"
        let finalizeDisplaced: (ManagedWindow) -> Void = { displaced in
            switch displacement {
            case .synchronous:
                host.minimizeWindowProgrammatically(displaced, reason: displacedMinimizeReason)
                Logger.debug(
                    "Floating zone minimized displaced occupant \(displaced.windowId) on screen \(host.screenContextStore.loggingIndex(for: screenId)) (reason: \(displacedMinimizeReason))"
                )
            case .deferred:
                host.queueDeferredMinimization(windowId: displaced.windowId, reason: displacedMinimizeReason)
                Logger.debug(
                    "Floating zone queued deferred minimization for displaced occupant \(displaced.windowId) on screen \(host.screenContextStore.loggingIndex(for: screenId)) (reason: \(displacedMinimizeReason))"
                )
            }
        }

        SingleOccupantReplacement.replaceIfNeeded(
            existingWindowId: occupants[screenId],
            incomingWindowId: managed.windowId,
            lookupWindow: { host.windowController.window(withId: $0) },
            evictExistingWindowId: { occupantId in
                host.clearFloatingZoneProtection(windowId: occupantId)
                occupants.removeValue(forKey: screenId)
                host.floatingOccupantEvicted(windowId: occupantId)
            },
            clearDisplacedAssignment: { host.clearManagedWindowZone($0) },
            // For `.synchronous`: AX kAXMinimized's brief flash-to-key on the displaced
            // window happens before the incoming window's frame writes/raise (because
            // `SingleOccupantReplacement` runs `finalize` before `assignIncoming`), so
            // the flash is invisible. For `.deferred`: the minimize is queued so any
            // ongoing external unminimize burst can drain before it lands (avoiding the
            // infinite ping-pong loop with apps restoring their session windows).
            finalizeDisplaced: finalizeDisplaced,
            assignIncoming: {
                occupants[screenId] = managed.windowId
                managed.isInFloatingZone = true
                host.setManagedWindow(managed, screenId: screenId, zoneIndex: nil)

                var committedSize: CGSize?
                if let target, let descriptor {
                    host.windowController.showWindow(managed, at: target.frame, on: descriptor, raise: activate)
                    committedSize = target.frame.size
                } else {
                    let actual = managed.actualFrame.size
                    if actual.width > 0, actual.height > 0 {
                        committedSize = actual
                    }
                }

                // A taken frame (an occupant's or an explicit one) becomes the window's floating
                // size. Otherwise the size is seeded on first placement only, so subsequent
                // re-entries (after tiling-zone excursions) restore this floating-zone size
                // instead of the window's post-excursion actualFrame.
                if let committedSize,
                   target?.isTaken == true || rememberedSize(for: managed.windowId) == nil {
                    rememberSize(for: managed.windowId, size: committedSize)
                }
            },
            afterAssignIncoming: {
                // `activate: false` places the window without raising it (e.g. the swap partner of
                // a zone-navigation move, which must stay behind the moved, focused window).
                // Protection is skipped too: it records activation recency and re-raises the
                // window when it expires, both of which would steal focus back.
                if activate {
                    host.activateFloatingZoneWindow(managed, reason: reason)
                    host.scheduleFloatingZoneProtection(windowId: managed.windowId)
                }
            }
        )

        Logger.debug("Assigned window \(managed.windowId) to floating zone on screen \(host.screenContextStore.loggingIndex(for: screenId)) (reason: \(reason))")
        host.refreshIndicators()
        host.refreshResizeHandles()
    }

    /// Bookkeeping-only release of a floating slot, for flows that go on to manage the window
    /// themselves (moves out of the floating zone, drag conversion and revert, clear-zones'
    /// batched minimize). A window that disappears instead leaves through the host's
    /// `removeWindowFromAllZones`, which releases the slot here and then applies the
    /// floating-zone emptying retarget.
    func clear(windowId: Int, reason: String) {
        guard let host,
              let entry = occupants.first(where: { $0.value == windowId }) else {
            return
        }
        host.clearFloatingZoneProtection(windowId: windowId)
        if let window = host.windowController.window(withId: windowId) {
            window.isInFloatingZone = false
        }
        occupants.removeValue(forKey: entry.key)
        Logger.debug("Cleared floating zone occupant \(windowId) on screen \(host.screenContextStore.loggingIndex(for: entry.key)) (reason: \(reason))")
        host.refreshIndicators()
        host.refreshResizeHandles()
    }

    func handleFocusChange(pid: pid_t, focusedWindowId: Int?) {
        guard let host,
              let focusContext = tiledFocusContext(pid: pid, focusedWindowId: focusedWindowId) else {
            return
        }

        let entries = occupants
        let focusScreenId = focusContext.screenId
        for (screenId, occupantId) in entries {
            if let focusScreenId, focusScreenId != screenId {
                continue
            }
            guard let window = host.windowController.window(withId: occupantId) else {
                occupants.removeValue(forKey: screenId)
                continue
            }
            let occupantPid = window.backing.pid

            if handleProtectedReactivate(window: window) {
                continue
            }

            if occupantPid == focusContext.pid {
                if focusContext.window.windowId == occupantId {
                    continue
                }
                queueConditionalMinimizeOccupant(on: screenId, reason: "focus-shift-same-app")
            } else {
                queueConditionalMinimizeOccupant(on: screenId, reason: "focus-shift-other-app")
            }
        }
    }

    func handleActivationChange(focusedPid: pid_t?, reason: String) {
        guard let host,
              let focusedPid,
              let focusContext = tiledFocusContext(pid: focusedPid, focusedWindowId: nil) else {
            return
        }

        let entries = occupants
        let focusScreenId = focusContext.screenId
        for (screenId, occupantId) in entries {
            if let focusScreenId, focusScreenId != screenId {
                continue
            }
            guard let window = host.windowController.window(withId: occupantId) else {
                occupants.removeValue(forKey: screenId)
                continue
            }
            let occupantPid = window.backing.pid

            if handleProtectedReactivate(window: window) {
                continue
            }

            if occupantPid == focusContext.pid,
               focusContext.window.windowId == occupantId {
                continue
            }

            queueConditionalMinimizeOccupant(on: screenId, reason: reason)
        }
    }

    /// Prepare host/delegate state right before deferred minimization executes.
    /// For occlusion-driven floating-zone minimization, we only proceed if the window is
    /// still the floating occupant, and still occluded, once any mouse gesture and drop hold
    /// are over.
    func prepareForDeferredMinimization(windowId: Int, reason: String) -> DeferredMinimizationVerdict {
        guard let host else { return .skip }

        guard isOcclusionBasedFloatingMinimizationReason(reason) else {
            return .minimize
        }

        guard let screenId = occupants.first(where: { $0.value == windowId })?.key else {
            Logger.debug(
                "Floating zone deferred minimization skipped for window \(windowId): no longer floating occupant (reason: \(reason))"
            )
            return .skip
        }

        // The gesture may be dragging a tiled window, brought to the front by its click, into this
        // floating zone: the floating window stays a drop destination until the drop is resolved,
        // and the window a drop into it opens still finds it to replace.
        if host.isMouseGestureInProgress || isHeldForDropArrival(windowId) {
            return .postpone
        }

        guard isFloatingZoneOccupantOccluded(on: screenId, occupantWindowId: windowId) else {
            Logger.debug(
                "Floating zone deferred minimization skipped for window \(windowId): not occluded (reason: \(reason))"
            )
            return .skip
        }
        // The occlusion check asks applications and can take a while: a gesture begun meanwhile
        // postpones too.
        if host.isMouseGestureInProgress {
            return .postpone
        }

        // The occupant is leaving the zone system, so it takes the same path as any other
        // minimized window: the slot is released and the floating-zone emptying retarget applies.
        host.removeWindowFromAllZones(windowId: windowId, reason: reason, retarget: true, logIfUnassigned: true)
        return .minimize
    }

    /// How the dropped window entered the floating drag, for resolving the move rule's origin.
    /// The mid-drag floating booking of a converted tiled drag is transient and never counts as
    /// an origin — including when an earlier cancelled conversion already lost the tiled source.
    enum FloatingDropOrigin {
        /// An ordinary drag of a floating-zone window; the origin is its booked floating zone.
        case floatingWindow
        /// A tiled drag converted mid-gesture (Control-Command); the origin is the tiling zone
        /// the gesture started in, or nil when the drag had no source zone.
        case convertedTiledDrag(originZoneKey: ZoneKey?)
    }

    func finalizeFloatingDrop(
        windowId: Int,
        _ finalFrame: CGRect,
        hoveredAddZonePill: AddZonePillKey?,
        hoveredFloatingScreenId: CGDirectDisplayID?,
        finalCursorPoint: CGPoint?,
        dropOrigin: FloatingDropOrigin
    ) {
        guard let host,
              let managed = host.windowController.window(withId: windowId) else {
            return
        }

        let preMoveTarget = host.targetedZoneManager.targetedDestination
        let entryFloatingScreenId = occupants.first(where: { $0.value == windowId })?.key
        let origin: TargetedZoneManager.TargetedDestination? = {
            switch dropOrigin {
            case .convertedTiledDrag(let originZoneKey):
                return originZoneKey.map { .tiled($0) }
            case .floatingWindow:
                return entryFloatingScreenId.map { .floating(screenId: $0) }
            }
        }()

        let addZonePill = hoveredAddZonePill ??
            addZoneDropTarget(for: finalCursorPoint)

        if let addZonePill,
           let newZone = host.addZone(on: addZonePill.screenId, side: addZonePill.side, forDrop: true) {
            clear(windowId: windowId, reason: "floating-drop-add-zone")
            // Zone creation applied its own targeting rule; the standard retarget-after-fill
            // then runs inside the assignment, so the move rule adds nothing here.
            if let result = host.windowPlacementManager.assignWindowFromDrag(
                managed,
                to: ZoneKey(screenId: addZonePill.screenId, index: newZone.index)
            ) {
                displacedWindowCoordinator.resolve(
                    result.displacedWindow,
                    preferredScreenId: addZonePill.screenId,
                    disposition: .reassign
                )
            }
            return
        }

        // Resolve the drop's floating destination; without a handled indicator or cross-screen
        // drop, the window simply stays floating where it is.
        var destinationScreenId = entryFloatingScreenId
        if let hoveredFloatingScreenId,
           handleFloatingIndicatorDrop(managed: managed, destinationScreenId: hoveredFloatingScreenId) {
            destinationScreenId = hoveredFloatingScreenId
        } else if handleCrossScreenFloatingDrop(managed: managed, finalFrame: finalFrame) {
            destinationScreenId = host.screenIdForAccessibilityFrame(finalFrame) ?? entryFloatingScreenId
        }

        if let destinationScreenId {
            host.targetedZoneManager.retargetAfterMovingWindow(
                from: origin,
                to: .floating(screenId: destinationScreenId),
                preMoveTarget: preMoveTarget,
                reason: "floating-drop"
            )
        }
    }

    private func handleFloatingIndicatorDrop(managed: ManagedWindow, destinationScreenId: CGDirectDisplayID) -> Bool {
        guard let originScreenId = occupants.first(where: { $0.value == managed.windowId })?.key else {
            return false
        }

        if destinationScreenId == originScreenId {
            return true
        }

        return moveFloatingWindow(managed, originScreenId: originScreenId, destinationScreenId: destinationScreenId)
    }

    private func handleCrossScreenFloatingDrop(managed: ManagedWindow, finalFrame: CGRect) -> Bool {
        guard let host,
              let originScreenId = occupants.first(where: { $0.value == managed.windowId })?.key,
              let destinationScreenId = host.screenIdForAccessibilityFrame(finalFrame) else {
            return false
        }

        if destinationScreenId == originScreenId {
            return false
        }

        return moveFloatingWindow(managed, originScreenId: originScreenId, destinationScreenId: destinationScreenId)
    }

    /// App-driven moves bypass the drag pipeline, so an application relocating its own
    /// floating window across displays would otherwise leave the occupancy booked against
    /// the old display. Re-book the window on the display it now physically occupies,
    /// with the same swap semantics as a cross-display user drag — except the displaced
    /// partner is not raised, since no user gesture is driving this.
    func reconcileOccupantScreenAfterAppDrivenMove(windowId: Int, accessibilityFrame: CGRect) {
        guard let host,
              let originScreenId = occupants.first(where: { $0.value == windowId })?.key,
              let destinationScreenId = host.screenIdForAccessibilityFrame(accessibilityFrame),
              destinationScreenId != originScreenId,
              let managed = host.windowController.window(withId: windowId) else {
            return
        }
        _ = moveFloatingWindow(
            managed,
            originScreenId: originScreenId,
            destinationScreenId: destinationScreenId,
            raiseDisplaced: false
        )
    }

    private func moveFloatingWindow(
        _ managed: ManagedWindow,
        originScreenId: CGDirectDisplayID,
        destinationScreenId: CGDirectDisplayID,
        raiseDisplaced: Bool = true
    ) -> Bool {
        guard let host else {
            return false
        }

        let displacedWindow = occupants[destinationScreenId].flatMap { host.windowController.window(withId: $0) }
        let originIndex = host.screenContextStore.loggingIndex(for: originScreenId)
        let destinationIndex = host.screenContextStore.loggingIndex(for: destinationScreenId)

        // Bookkeeping: move the dragged window to the destination screen's floating zone.
        occupants.removeValue(forKey: originScreenId)
        occupants[destinationScreenId] = managed.windowId
        host.setManagedWindow(managed, screenId: destinationScreenId, zoneIndex: nil)

        // If the destination already had a floating occupant, swap it back to the origin screen.
        if let displacedWindow {
            occupants[originScreenId] = displacedWindow.windowId
            host.setManagedWindow(displacedWindow, screenId: originScreenId, zoneIndex: nil)

            // The origin zone emptied as the dragged window left it, so the swap partner is
            // centered there as in any empty floating zone.
            if let descriptor = host.descriptor(for: originScreenId) {
                let frame = centeredFrame(for: displacedWindow, on: descriptor)
                host.windowController.showWindow(displacedWindow, at: frame, on: descriptor, raise: false)
                if raiseDisplaced {
                    // No activation follows, and the window may sit below this display's tiles.
                    host.windowController.raiseWithoutActivating(displacedWindow)
                }
            }

            Logger.debug(
                "Swapped floating zone occupants: window \(managed.windowId) -> screen \(destinationIndex), " +
                    "window \(displacedWindow.windowId) -> screen \(originIndex)"
            )
        } else {
            Logger.debug("Moved floating zone window \(managed.windowId) from screen \(originIndex) to screen \(destinationIndex)")
        }

        host.refreshIndicators()
        host.refreshResizeHandles()
        return true
    }
    
    private func addZoneDropTarget(for cursorPoint: CGPoint?) -> AddZonePillKey? {
        guard let host, let cursorPoint else { return nil }
        let hitAreas = host.addZoneIndicatorHitAreas()
        for (pill, frame) in hitAreas where frame.contains(cursorPoint) {
            return pill
        }
        return nil
    }

    /// Where `.standard` and `.dropped` put `managed` in `screenId`'s floating zone: the occupant's
    /// frame when `keepingOccupantFrame` and another window occupies the zone (`isTaken`), else
    /// centered at the window's floating size. `queryingApplication: false` reads both from
    /// Zonogy's records rather than asking the applications (for pre-positioning).
    private func standardPlacement(
        for managed: ManagedWindow,
        on screenId: CGDirectDisplayID,
        descriptor: ScreenDescriptor,
        keepingOccupantFrame: Bool,
        queryingApplication: Bool
    ) -> (frame: CGRect, isTaken: Bool) {
        if keepingOccupantFrame,
           let frame = occupantFrame(on: screenId, excluding: managed.windowId, queryingApplication: queryingApplication) {
            return (frame, true)
        }
        return (centeredFrame(for: managed, on: descriptor, queryingApplication: queryingApplication), false)
    }

    /// Whether `screenId`'s floating zone is explicitly targeted: the user pointed at it, so the window
    /// it receives takes its occupant's place and frame. An implicit target merely catches windows not
    /// aimed anywhere, which keep their own size.
    private func isExplicitlyTargeted(_ screenId: CGDirectDisplayID) -> Bool {
        guard let host else {
            return false
        }
        return host.targetedZoneManager.targetedFloatingScreenId == screenId
            && host.targetedZoneManager.isFloatingTargetExplicit
    }

    /// The frame a window taking over `screenId`'s floating zone from its occupant gets: the
    /// occupant's frame, in the display's screen-local coordinates. Nil when the zone is empty or
    /// holds only `windowId`, or the frame cannot be read. `queryingApplication: false` reads it
    /// from Zonogy's records instead of asking the occupant's application.
    func occupantFrame(
        on screenId: CGDirectDisplayID,
        excluding windowId: Int,
        queryingApplication: Bool = true
    ) -> CGRect? {
        guard let host,
              let occupantId = occupants[screenId], occupantId != windowId,
              let occupant = host.windowController.window(withId: occupantId),
              let descriptor = host.descriptor(for: screenId) else {
            return nil
        }
        let frame = queryingApplication
            ? host.windowController.actualFrameInAccessibilityCoordinates(for: occupant)
            : occupant.cachedFrame
        guard let frame, frame.width > 0, frame.height > 0 else {
            return nil
        }
        return descriptor.accessibilityToScreen(frame)
    }

    /// The frame of a window placed into an empty floating zone: centered, sized to the first
    /// available of its remembered floating size, its current size, or 55% of the display, within
    /// limits. `queryingApplication: false` sizes a window without a remembered size from the frame
    /// Zonogy last observed rather than asking its application (for pre-positioning).
    private func centeredFrame(
        for managed: ManagedWindow,
        on descriptor: ScreenDescriptor,
        queryingApplication: Bool = true
    ) -> CGRect {
        let bounds = descriptor.visibleScreenBounds.standardized
        let minWidth = bounds.width / 3
        let maxWidth = bounds.width * 0.8
        let minHeight = bounds.height / 3
        let maxHeight = bounds.height * 0.8

        var width: CGFloat
        var height: CGFloat
        if let remembered = rememberedSize(for: managed.windowId) {
            width = remembered.width
            height = remembered.height
        } else {
            // Read once: each `actualFrame` access asks the application.
            let currentFrame = queryingApplication ? managed.actualFrame : (managed.cachedFrame ?? .zero)
            if currentFrame.width > 0, currentFrame.height > 0 {
                width = currentFrame.width
                height = currentFrame.height
            } else {
                width = (bounds.width * 0.55).rounded()
                height = (bounds.height * 0.55).rounded()
            }
        }

        width = min(max(width, minWidth), maxWidth)
        height = min(max(height, minHeight), maxHeight)

        var originX = (bounds.midX - width / 2).rounded()
        var originY = (bounds.midY - height / 2).rounded()
        originX = max(bounds.minX, min(originX, bounds.maxX - width))
        originY = max(bounds.minY, min(originY, bounds.maxY - height))
        return CGRect(x: originX, y: originY, width: width, height: height)
    }

    /// Compute the placement frame for a window in the floating zone without actually placing it,
    /// from Zonogy's records. Used for pre-positioning minimized windows before unminimizing.
    func computePlacementFrame(for managed: ManagedWindow, on screenId: CGDirectDisplayID) -> CGRect? {
        guard let descriptor = host?.descriptor(for: screenId) else { return nil }
        return standardPlacement(
            for: managed,
            on: screenId,
            descriptor: descriptor,
            keepingOccupantFrame: isExplicitlyTargeted(screenId),
            queryingApplication: false
        ).frame
    }

    func hasAvailableTiledZone() -> Bool {
        guard let host else { return false }
        return emptyZoneCount(in: host.screenContexts) > 0
    }

    private func emptyZoneCount(in contexts: [CGDirectDisplayID: ScreenContext]) -> Int {
        var count = 0
        for context in contexts.values {
            for zone in context.zoneController.allZones where zone.isEmpty {
                count += 1
            }
        }
        return count
    }

    private func tiledFocusContext(pid: pid_t, focusedWindowId: Int?) -> TiledFocusContext? {
        guard let host,
              let managed = resolvedFocusedWindow(host: host, pid: pid, focusedWindowId: focusedWindowId),
              isTiledWindow(managed) else {
            return nil
        }

        let resolvedPid = managed.backing.pid
        let screenId = managed.screenDisplayId ?? host.detectScreenId(for: managed)
        return TiledFocusContext(window: managed, pid: resolvedPid, screenId: screenId)
    }

    private func resolvedFocusedWindow(
        host: FloatingZoneCoordinatorHost,
        pid: pid_t,
        focusedWindowId: Int?
    ) -> ManagedWindow? {
        if let focusedWindowId,
           let window = host.windowController.window(withId: focusedWindowId) {
            return window
        }
        return host.windowController.focusedWindowIfTracked(pid: pid)
    }

    private func isTiledWindow(_ window: ManagedWindow) -> Bool {
        return window.zoneIndex != nil
    }

    /// If `window` is under active floating-zone protection, re-raise it (unless the
    /// user has just minimized it) and return `true` so the caller skips further
    /// focus/activation handling. Returns `false` when the window is not protected.
    private func handleProtectedReactivate(window: ManagedWindow) -> Bool {
        guard let host, host.shouldProtectFloatingZoneOccupant(windowId: window.windowId) else {
            return false
        }
        if window.isMinimizedPerAccessibility {
            Logger.debug("Floating zone protection skipped reactivate for minimized window \(window.windowId)")
            return true
        }
        host.activateFloatingZoneWindow(window, reason: "protection-reactivate")
        return true
    }

    private func queueConditionalMinimizeOccupant(on screenId: CGDirectDisplayID, reason: String) {
        guard let host,
              let occupant = occupant(on: screenId) else {
            return
        }
        host.queueDeferredMinimization(windowId: occupant.windowId, reason: reason)
        Logger.debug(
            "Floating zone queued conditional minimization for occupant \(occupant.windowId) on screen \(host.screenContextStore.loggingIndex(for: screenId)) (reason: \(reason))"
        )
    }

    private func isOcclusionBasedFloatingMinimizationReason(_ reason: String) -> Bool {
        reason.hasPrefix("focus-shift-") ||
            reason == "workspace-activate" ||
            reason.hasPrefix("occlusion-check-")
    }

    private func isFloatingZoneOccupantOccluded(on screenId: CGDirectDisplayID, occupantWindowId: Int) -> Bool {
        guard let host,
              let occupant = host.windowController.window(withId: occupantWindowId),
              let occupantFrame = host.windowController.actualFrameInAccessibilityCoordinates(for: occupant),
              let context = host.screenContexts[screenId] else {
            return false
        }

        var occluders: [OcclusionWindow] = []
        occluders.reserveCapacity(context.zoneController.allZones.count + 4)

        // Occupied tiling zones occlude based on their zone frames, not the window's
        // live frame. This keeps ActiveFit reveal spillover from enlarging the occlusion area.
        for zone in context.zoneController.allZones {
            guard let windowId = zone.occupantWindowId,
                  windowId != occupantWindowId,
                  let managed = host.windowController.window(withId: windowId) else {
                continue
            }
            let zoneFrame = context.descriptor.screenToAccessibility(zone.frame)
            occluders.append(OcclusionWindow(cgWindowId: managed.backing.cgWindowId, frame: zoneFrame))
        }

        // Fast path: if nothing even overlaps geometrically, occlusion is impossible.
        guard occluders.contains(where: {
            FloatingZoneOverlapPolicy.overlapsZoneFrame(
                floatingFrame: occupantFrame,
                zoneFrame: $0.frame
            )
        }) else {
            return false
        }

        guard let zOrder = WindowServerWindowList.onScreenWindowNumbersFrontToBack() else {
            return false
        }

        let target = OcclusionWindow(cgWindowId: occupant.backing.cgWindowId, frame: occupantFrame)
        return WindowOcclusionPolicy.isOccluded(
            target: target,
            occluders: occluders,
            zOrderFrontToBack: zOrder
        )
    }

}
