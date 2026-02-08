/// Window placement and assignment logic for positioning windows in zones
import Foundation
import Cocoa

protocol WindowPlacementManagerDelegate: AnyObject {
    // Zone management
    func removeWindowFromAllZones(windowId: Int, reason: String, retarget: Bool, logIfUnassigned: Bool)
    func zoneController(for screenId: CGDirectDisplayID) -> ZoneController?
    func descriptor(for screenId: CGDirectDisplayID) -> ScreenDescriptor?
    var screenContexts: [CGDirectDisplayID: ScreenContext] { get }
    var screenOrder: [CGDirectDisplayID] { get }

    // Window management
    var windowController: WindowController { get }
    func minimizeWindowProgrammatically(_ managed: ManagedWindow, reason: String)
    func clearManagedWindowZone(_ managed: ManagedWindow)
    func setManagedWindow(_ managed: ManagedWindow, screenId: CGDirectDisplayID, zoneIndex: Int?)
    func frameWithMargin(for zone: Zone, in controller: ZoneController) -> CGRect

    // Screen detection
    func detectScreenId(for window: ManagedWindow) -> CGDirectDisplayID?
    func activeScreenId() -> CGDirectDisplayID

    // Targeted zone management
    var targetedZoneManager: TargetedZoneManager { get }
    var targetingMode: TargetingMode { get }

    // Placement deferral
    func shouldDeferPlacementForNewWindow(_ managed: ManagedWindow, targetedZoneKey: ZoneKey?) -> Bool

    // Temporary zone management
    func assignWindowToTemporaryZone(
        _ managed: ManagedWindow,
        on screenId: CGDirectDisplayID,
        centerWindow: Bool,
        reason: String
    )
    func cancelPendingMinimization(windowId: Int)
    func queueDeferredMinimization(windowId: Int, reason: String)
    func emptyTemporaryZoneForNewTiledPlacement(
        on screenId: CGDirectDisplayID,
        excluding windowId: Int,
        reason: String
    )

    // UnderCovers coordination
    func willPlaceWindowIntoZone(on screenId: CGDirectDisplayID, zoneIndex: Int)

    // Synchronization
    func requestSync()
}

class WindowPlacementManager {
    weak var delegate: WindowPlacementManagerDelegate?
    struct DragAssignmentResult {
        let displacedWindow: ManagedWindow?
    }

    init() {}

    /// Returns `true` if placing the window into the destination tiled zone would be a no-op
    /// because the window is already assigned to that exact zone.
    ///
    /// Exposed for guardrail tests; callers should generally prefer the higher-level placement APIs.
    static func isNoOpTiledPlacement(
        windowId: Int,
        currentZoneIndex: Int?,
        currentScreenId: CGDirectDisplayID?,
        destinationKey: ZoneKey,
        destinationOccupantWindowId: Int?
    ) -> Bool {
        guard currentZoneIndex == destinationKey.index,
              currentScreenId == destinationKey.screenId,
              destinationOccupantWindowId == windowId else {
            return false
        }
        return true
    }

    // MARK: - Public Methods

    /// Places a newly captured window into the best zone (targeted or preferred screen).
    /// - Parameters:
    ///   - managed: The managed window to place.
    ///   - preferredScreenId: Optional preferred display for placement.
    ///   - requestSync: Whether to request an immediate zone sync after placement.
    func placeNewWindow(
        _ managed: ManagedWindow,
        preferredScreenId: CGDirectDisplayID? = nil,
        requestSync: Bool = true
    ) {
        guard let delegate = delegate else { return }

        let baseReason = "place-new-window"

        if let preferredScreenId {
            delegate.removeWindowFromAllZones(
                windowId: managed.windowId,
                reason: baseReason,
                retarget: true,
                logIfUnassigned: false
            )
            managed.zoneIndex = nil
            placeWindow(managed, on: preferredScreenId, reason: baseReason)
            emptyTemporaryZoneAfterPlacementIfNeeded(managed, reason: "new-window-tiled")
            if requestSync {
                delegate.requestSync()
            }
            return
        }

        delegate.targetedZoneManager.ensureTargetedZone(reason: "placing-window")
        let targetedDestination = delegate.targetedZoneManager.targetedDestination
        let targetedKey: ZoneKey? = {
            if case .tiled(let key) = targetedDestination {
                return key
            }
            return nil
        }()

        // Keep the current zone occupant alive while the source app is mid tear-out.
        if delegate.shouldDeferPlacementForNewWindow(managed, targetedZoneKey: targetedKey) {
            delegate.removeWindowFromAllZones(
                windowId: managed.windowId,
                reason: baseReason,
                retarget: true,
                logIfUnassigned: false
            )
            managed.zoneIndex = nil
            let screenId = targetedKey?.screenId ?? delegate.detectScreenId(for: managed) ?? delegate.activeScreenId()
            delegate.setManagedWindow(managed, screenId: screenId, zoneIndex: nil)
            Logger.debug("Deferring placement for window \(managed.windowId); awaiting drag/drop completion")
            return
        }

        guard let targetedDestination else {
            let fallbackScreen = delegate.detectScreenId(for: managed) ?? delegate.activeScreenId()
            delegate.removeWindowFromAllZones(
                windowId: managed.windowId,
                reason: baseReason,
                retarget: true,
                logIfUnassigned: false
            )
            managed.zoneIndex = nil
            placeWindow(managed, on: fallbackScreen, reason: baseReason)
            emptyTemporaryZoneAfterPlacementIfNeeded(managed, reason: "new-window-tiled")
            if requestSync {
                delegate.requestSync()
            }
            return
        }

        placeWindow(
            managed,
            into: targetedDestination,
            centerTemporaryWindow: true,
            reason: baseReason,
            retargetOnRemoval: true,
            forceRetargetAfterFill: false,
            logIfUnassignedOnRemoval: false
        )
        if requestSync {
            delegate.requestSync()
        }
    }

    /// Reassigns or minimizes a window after its zone was deleted.
    func handleWindowAfterZoneRemoval(_ managed: ManagedWindow, preferredScreenId: CGDirectDisplayID) {
        guard let delegate = delegate else { return }

        delegate.removeWindowFromAllZones(
            windowId: managed.windowId,
            reason: "zone-removal-reassignment",
            retarget: true,
            logIfUnassigned: true
        )
        managed.zoneIndex = nil

        if let (zone, context, descriptor) = findZoneAcceptingRemovedWindow(preferredScreenId: preferredScreenId) {
            Logger.debug(
                "Zone removal reassigning window \(managed.windowId) to zone \(zone.index) on \(context.descriptor.localizedName) [\(context.descriptor.displayId)]"
            )
            let zoneWasEmptyBeforeAssignment = zoneWasEmptyBeforePlacement(zone)
            assignWindowToZone(
                managed,
                zone: zone,
                screenId: context.descriptor.displayId,
                descriptor: descriptor,
                zoneWasEmptyBeforeAssignment: zoneWasEmptyBeforeAssignment
            )
            return
        }

        Logger.debug("Zone removal minimizing window \(managed.windowId); no available zone without displacement")
        delegate.clearManagedWindowZone(managed)
        delegate.minimizeWindowProgrammatically(managed, reason: "zone-removal-no-destination")
    }

    /// Moves an already managed window between zones, optionally minimizing displaced occupants.
    func moveWindow(
        _ managed: ManagedWindow,
        from originKey: ZoneKey,
        to destinationKey: ZoneKey,
        reason: String = "move-window",
        minimizeDisplacedWindows: Bool = true
    ) -> Bool {
        guard let delegate = delegate else { return false }

        if originKey == destinationKey {
            Logger.debug("Move window skipped: window \(managed.windowId) already in zone \(originKey.index) on screen \(ScreenContextStore.loggingIndex(for: originKey.screenId))")
            return true
        }

        guard let originContext = delegate.screenContexts[originKey.screenId],
              let _ = originContext.zoneController.zone(at: originKey.index),
              let destinationContext = delegate.screenContexts[destinationKey.screenId],
              let descriptor = delegate.descriptor(for: destinationKey.screenId),
              let destinationZone = destinationContext.zoneController.zone(at: destinationKey.index) else {
            Logger.debug(
                "Move window aborted: missing origin/destination (\(originKey.screenId):\(originKey.index) -> \(destinationKey.screenId):\(destinationKey.index))"
            )
            return false
        }

        // Clear both sides: zone's record and window's record of the assignment
        originContext.zoneController.removeWindow(windowId: managed.windowId)
        delegate.clearManagedWindowZone(managed)

        let destinationWasEmpty = zoneWasEmptyBeforePlacement(destinationZone)
        let displacement = displacementPlanIfNeeded(
            in: destinationZone,
            controller: destinationContext.zoneController,
            excluding: managed.windowId,
            minimizeReason: "\(reason)-displaced"
        )

        assignWindowToZone(
            managed,
            zone: destinationZone,
            screenId: destinationKey.screenId,
            descriptor: descriptor,
            zoneWasEmptyBeforeAssignment: destinationWasEmpty
        )

        if minimizeDisplacedWindows {
            displacement?.finalize()
        }

        let originScreenIndex = delegate.screenOrder.firstIndex(of: originKey.screenId) ?? Int(originKey.screenId)
        let destinationScreenIndex = delegate.screenOrder.firstIndex(of: destinationKey.screenId) ?? Int(destinationKey.screenId)
        Logger.debug(
            "Move window completed: \(managed.windowId) from screen \(originScreenIndex) zone \(originKey.index) to screen \(destinationScreenIndex) zone \(destinationKey.index)"
        )
        return true
    }

    // MARK: - Private Methods

    /// Places a window on a specific screen, preferring empty zones before evicting occupants.
    private func placeWindow(_ managed: ManagedWindow, on screenId: CGDirectDisplayID, reason: String) {
        guard let delegate = delegate,
              let controller = delegate.zoneController(for: screenId),
              let descriptor = delegate.descriptor(for: screenId) else {
            return
        }

        if let emptyZone = controller.findEmptyZone() {
            let zoneWasEmptyBeforeAssignment = zoneWasEmptyBeforePlacement(emptyZone)
            assignWindowToZone(
                managed,
                zone: emptyZone,
                screenId: screenId,
                descriptor: descriptor,
                zoneWasEmptyBeforeAssignment: zoneWasEmptyBeforeAssignment
            )
            return
        }

        guard let highestZone = controller.highestIndexZone() else {
            return
        }

        let zoneWasEmptyBeforeAssignment = zoneWasEmptyBeforePlacement(highestZone)
        let displacement = displacementPlanIfNeeded(
            in: highestZone,
            controller: controller,
            excluding: managed.windowId,
            minimizeReason: "\(reason)-displaced"
        )

        assignWindowToZone(
            managed,
            zone: highestZone,
            screenId: screenId,
            descriptor: descriptor,
            zoneWasEmptyBeforeAssignment: zoneWasEmptyBeforeAssignment
        )

        displacement?.finalize()
    }

    /// Places a window into a specific zone, used for restoring pre-sleep assignments.
    func placeWindow(
        _ managed: ManagedWindow,
        into zoneKey: ZoneKey,
        reason: String
    ) {
        placeWindow(
            managed,
            into: .tiled(zoneKey),
            centerTemporaryWindow: true,
            reason: reason,
            retargetOnRemoval: true,
            forceRetargetAfterFill: false
        )
    }

    /// Places a window into a specific destination (tiled zone or temporary zone), with optional retarget behavior.
    ///
    /// - Parameters:
    ///   - managed: The window being placed.
    ///   - destination: The destination zone to place into (can be tiled or temporary).
    ///   - centerTemporaryWindow: If placing into a temporary zone, whether to apply the initial centering/resizing.
    ///   - reason: Base reason label for this placement operation (used for greppable logs). Sub-actions derive
    ///     their own reason labels from this, e.g. `"<reason>-displaced"` and `"<reason>-filled"`.
    ///   - retargetOnRemoval: If `managed` is currently placed in another zone, consider retargeting to the old
    ///     zone per spec since it's now becoming empty. 
    ///   - forceRetargetAfterFill: Even if the destination zone isn't currently targeted, pretend like it is for
    ///     the purposes of applying the spec's "retarget after filling a targeted empty tiling zone" rule.
    ///   - logIfUnassignedOnRemoval: Whether to log when the pre-placement cleanup finds that the window wasn't
    ///     assigned to any zone (use `false` for common expected cases like brand-new window placement).
    ///   - afterPlacementAction: Optional action to run after `managed` is placed (or no-op if it's already there), 
    ///     but before any displaced previous occupant of the zone is minimized. (Currently used to "activate/raise 
    ///     the placed window and record its recency" via `activateWindow` for tiling zones.)
    func placeWindow(
        _ managed: ManagedWindow,
        into destination: TargetedZoneManager.TargetedDestination,
        centerTemporaryWindow: Bool = true,
        reason: String,
        retargetOnRemoval: Bool = true,
        forceRetargetAfterFill: Bool = false,
        logIfUnassignedOnRemoval: Bool = true,
        afterPlacementAction: (() -> Void)? = nil
    ) {
        guard let delegate = delegate else {
            return
        }

        if case .tiled(let zoneKey) = destination,
           let controller = delegate.zoneController(for: zoneKey.screenId),
           let zone = controller.zone(at: zoneKey.index),
           Self.isNoOpTiledPlacement(
            windowId: managed.windowId,
            currentZoneIndex: managed.zoneIndex,
            currentScreenId: managed.screenDisplayId,
            destinationKey: zoneKey,
            destinationOccupantWindowId: zone.occupantWindowId
           ) {
            Logger.debug(
                "Skipping placement: window \(managed.windowId) is already in screen \(ScreenContextStore.loggingIndex(for: zoneKey.screenId)) zone \(zoneKey.index) (reason: \(reason))"
            )
            afterPlacementAction?()
            return
        }

        delegate.removeWindowFromAllZones(
            windowId: managed.windowId,
            reason: reason,
            retarget: retargetOnRemoval,
            logIfUnassigned: logIfUnassignedOnRemoval
        )
        managed.zoneIndex = nil

        switch destination {
        case .temporary(let screenId):
            delegate.assignWindowToTemporaryZone(
                managed,
                on: screenId,
                centerWindow: centerTemporaryWindow,
                reason: reason
            )
        case .tiled(let zoneKey):
            placePreparedWindowIntoZone(
                managed,
                zoneKey: zoneKey,
                reason: reason,
                forceRetargetAfterFill: forceRetargetAfterFill,
                afterPlacementAction: afterPlacementAction
            )
        }

        // If placed into a tiled zone, ensure any temporary occupant on that screen is minimized per policy.
        if managed.zoneIndex != nil {
            emptyTemporaryZoneAfterPlacementIfNeeded(managed, reason: reason)
        }
    }

    private func placePreparedWindowIntoZone(
        _ managed: ManagedWindow,
        zoneKey: ZoneKey,
        reason: String,
        forceRetargetAfterFill: Bool,
        afterPlacementAction: (() -> Void)?
    ) {
        guard let delegate = delegate,
              let context = delegate.screenContexts[zoneKey.screenId],
              let descriptor = delegate.descriptor(for: zoneKey.screenId),
              let zone = context.zoneController.zone(at: zoneKey.index) else {
            return
        }

        // Match the temporary-zone pathway: ensure the incoming window can't get minimized
        // by a previously-queued displacement while we're actively placing it.
        delegate.cancelPendingMinimization(windowId: managed.windowId)

        let displacedMinimizeReason = "\(reason)-displaced"
        let retargetReason = "\(reason)-filled"

        let zoneWasEmptyBeforeAssignment = zoneWasEmptyBeforePlacement(zone)

        SingleOccupantReplacement.replaceIfNeeded(
            existingWindowId: zone.occupantWindowId,
            incomingWindowId: managed.windowId,
            lookupWindow: { delegate.windowController.window(withId: $0) },
            evictExistingWindowId: { context.zoneController.removeWindow(windowId: $0) },
            clearDisplacedAssignment: { delegate.clearManagedWindowZone($0) },
            finalizeDisplaced: { delegate.queueDeferredMinimization(windowId: $0.windowId, reason: displacedMinimizeReason) },
            assignIncoming: {
                assignWindowToZone(
                    managed,
                    zone: zone,
                    screenId: zoneKey.screenId,
                    descriptor: descriptor,
                    zoneWasEmptyBeforeAssignment: zoneWasEmptyBeforeAssignment,
                    forceRetargetAfterFill: forceRetargetAfterFill,
                    retargetReason: retargetReason
                )
            },
            afterAssignIncoming: {
                afterPlacementAction?()
            }
        )
    }

    /// Assigns a managed window to a zone and updates targeted-zone bookkeeping.
    private func assignWindowToZone(
        _ managed: ManagedWindow,
        zone: Zone,
        screenId: CGDirectDisplayID,
        descriptor: ScreenDescriptor,
        zoneWasEmptyBeforeAssignment: Bool,
        forceRetargetAfterFill: Bool = false,
        retargetReason: String = "zone-filled"
    ) {
        guard let delegate = delegate else { return }

        delegate.cancelPendingMinimization(windowId: managed.windowId)

        // Record activity for windows placed into zones so they appear in AltTab/Launcher recency lists.
        delegate.windowController.recordWindowActivity(windowId: managed.windowId)

        delegate.willPlaceWindowIntoZone(on: screenId, zoneIndex: zone.index)

        let filledZoneKey = ZoneKey(screenId: screenId, index: zone.index)
        let wasTargetedZone = delegate.targetedZoneManager.targetedZoneKey == filledZoneKey

        // Placeholder windows are now managed separately by PlaceholderCoordinator
        // and are not in the WindowController's allWindows list

        guard let controller = delegate.zoneController(for: screenId) else {
            return
        }
        // Update both sides: zone's record and window's record of the assignment
        controller.assignWindow(windowId: managed.windowId, toZoneIndex: zone.index)
        let displayFrame = delegate.frameWithMargin(for: zone, in: controller)
        delegate.windowController.showWindow(managed, at: displayFrame, on: descriptor)
        delegate.setManagedWindow(managed, screenId: screenId, zoneIndex: zone.index)

        if zoneWasEmptyBeforeAssignment,
           delegate.targetingMode == .independentOfFocus,
           (wasTargetedZone || forceRetargetAfterFill) {
            delegate.targetedZoneManager.retargetAfterFillingZone(filledZoneKey, reason: retargetReason)
        }
    }

    /// Assigns a dragged window into the specified zone, returning its displaced occupant if any.
    func assignWindowFromDrag(
        _ managed: ManagedWindow,
        to targetKey: ZoneKey
    ) -> DragAssignmentResult? {
        guard let delegate = delegate,
              let context = delegate.screenContexts[targetKey.screenId],
              let descriptor = delegate.descriptor(for: targetKey.screenId),
              let zone = context.zoneController.zone(at: targetKey.index) else {
            return nil
        }

        let zoneWasEmptyBeforeAssignment = zoneWasEmptyBeforePlacement(zone)
        let displacement = DisplacedWindowPlanner.planIfNeeded(
            existingWindowId: zone.occupantWindowId,
            incomingWindowId: managed.windowId,
            lookupWindow: { delegate.windowController.window(withId: $0) },
            evictExistingWindowId: { context.zoneController.removeWindow(windowId: $0) },
            clearDisplacedAssignment: { delegate.clearManagedWindowZone($0) },
            finalizeDisplaced: { _ in }
        )

        assignWindowToZone(
            managed,
            zone: zone,
            screenId: targetKey.screenId,
            descriptor: descriptor,
            zoneWasEmptyBeforeAssignment: zoneWasEmptyBeforeAssignment
        )
        return DragAssignmentResult(displacedWindow: displacement?.displaced)
    }

    private func zoneWasEmptyBeforePlacement(_ zone: Zone) -> Bool {
        // A zone is empty if it has no window assigned
        // (placeholders are managed separately and not tracked in zones)
        return zone.occupantWindowId == nil
    }

    /// Finds the first zone that can accept a window displaced by zone removal.
    private func findZoneAcceptingRemovedWindow(
        preferredScreenId: CGDirectDisplayID
    ) -> (zone: Zone, context: ScreenContext, descriptor: ScreenDescriptor)? {
        guard let delegate = delegate else { return nil }

        let orderedScreens = screenOrderStarting(with: preferredScreenId)

        for screenId in orderedScreens {
            guard let context = delegate.screenContexts[screenId],
                  let descriptor = delegate.descriptor(for: screenId) else {
                continue
            }

            for zone in context.zoneController.allZones {
                if zone.occupantWindowId == nil {
                    return (zone, context, descriptor)
                }

                // Placeholders are managed separately and not tracked in zones,
                // so zones with windowId == nil are the only empty ones
            }
        }

        return nil
    }

    /// Returns screen order with the preferred display first to keep placement deterministic.
    private func screenOrderStarting(with preferred: CGDirectDisplayID) -> [CGDirectDisplayID] {
        guard let delegate = delegate else { return [] }

        var ordered = delegate.screenOrder
        if let index = ordered.firstIndex(of: preferred) {
            let prefix = ordered.remove(at: index)
            ordered.insert(prefix, at: 0)
        } else {
            ordered.insert(preferred, at: 0)
        }
        return ordered
    }

    /// Shared displacement path for tiled-zone placement: evict an existing occupant and plan minimization.
    private func displacementPlanIfNeeded(
        in zone: Zone,
        controller: ZoneController,
        excluding windowId: Int,
        minimizeReason: String
    ) -> DisplacedWindowPlan<ManagedWindow>? {
        guard let delegate else { return nil }
        return DisplacedWindowPlanner.planIfNeeded(
            existingWindowId: zone.occupantWindowId,
            incomingWindowId: windowId,
            lookupWindow: { delegate.windowController.window(withId: $0) },
            evictExistingWindowId: { controller.removeWindow(windowId: $0) },
            clearDisplacedAssignment: { delegate.clearManagedWindowZone($0) },
            finalizeDisplaced: { delegate.queueDeferredMinimization(windowId: $0.windowId, reason: minimizeReason) }
        )
    }

    private func emptyTemporaryZoneAfterPlacementIfNeeded(_ managed: ManagedWindow, reason: String) {
        guard let delegate = delegate,
              managed.zoneIndex != nil,
              let screenId = managed.screenDisplayId else {
            return
        }
        delegate.emptyTemporaryZoneForNewTiledPlacement(on: screenId, excluding: managed.windowId, reason: reason)
    }
}
