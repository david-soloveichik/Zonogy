/// Window placement and assignment logic for positioning windows in zones
import Foundation
import Cocoa

protocol WindowPlacementManagerDelegate: AnyObject {
    // Zone management
    func removeWindowFromAllZones(windowId: Int, reason: String)
    func zoneController(for screenId: CGDirectDisplayID) -> ZoneController?
    func descriptor(for screenId: CGDirectDisplayID) -> ScreenDescriptor?
    var screenContexts: [CGDirectDisplayID: ScreenContext] { get }
    var screenOrder: [CGDirectDisplayID] { get }

    // Window management
    var windowController: WindowController { get }
    func clearManagedWindowZone(_ managed: ManagedWindow)
    func setManagedWindow(_ managed: ManagedWindow, screenId: CGDirectDisplayID, zoneIndex: Int?)
    func frameWithMargin(for zone: Zone, in controller: ZoneController) -> CGRect
    func forgetPlaceholder(windowId: Int)

    // Screen detection
    func detectScreenId(for window: ManagedWindow) -> CGDirectDisplayID?
    func activeScreenId() -> CGDirectDisplayID

    // Targeted zone management
    var targetedZoneManager: TargetedZoneManager { get }
    var targetedZoneKey: ZoneKey? { get }
    var targetedTemporaryScreenId: CGDirectDisplayID? { get }

    // Placement deferral
    func shouldDeferPlacementForNewWindow(_ managed: ManagedWindow, targetedZoneKey: ZoneKey?) -> Bool

    // Temporary zone management
    func assignWindowToTemporaryZone(
        _ managed: ManagedWindow,
        on screenId: CGDirectDisplayID,
        centerWindow: Bool,
        reason: String
    )
    func updateTemporaryZoneTargeting(reason: String)
}

class WindowPlacementManager {
    weak var delegate: WindowPlacementManagerDelegate?
    struct DragAssignmentResult {
        let displacedWindow: ManagedWindow?
    }

    init() {}

    // MARK: - Public Methods

    /// Places a newly captured window into the best zone (targeted or preferred screen).
    func placeNewWindow(_ managed: ManagedWindow, preferredScreenId: CGDirectDisplayID? = nil) {
        guard let delegate = delegate else { return }

        delegate.removeWindowFromAllZones(windowId: managed.windowId, reason: "place-new-window")
        managed.zoneIndex = nil

        if let preferredScreenId {
            placeWindow(managed, on: preferredScreenId)
            return
        }

        if let temporaryScreenId = delegate.targetedTemporaryScreenId {
            delegate.assignWindowToTemporaryZone(
                managed,
                on: temporaryScreenId,
                centerWindow: true,
                reason: "place-new-window-targeted-temporary"
            )
            return
        }

        delegate.targetedZoneManager.ensureTargetedZone(reason: "placing-window")
        let targetedKey = delegate.targetedZoneKey

        // Keep the current zone occupant alive while the source app is mid tear-out.
        if delegate.shouldDeferPlacementForNewWindow(managed, targetedZoneKey: targetedKey) {
            let screenId = targetedKey?.screenId ?? delegate.detectScreenId(for: managed) ?? delegate.activeScreenId()
            delegate.setManagedWindow(managed, screenId: screenId, zoneIndex: nil)
            Logger.debug("Deferring placement for window \(managed.windowId); awaiting drag/drop completion")
            return
        }

        placeWindowInTargetedZone(managed, targetedKey: targetedKey)
    }

    /// Reassigns or minimizes a window after its zone was deleted.
    func handleWindowAfterZoneRemoval(_ managed: ManagedWindow, preferredScreenId: CGDirectDisplayID) {
        guard let delegate = delegate else { return }

        delegate.removeWindowFromAllZones(windowId: managed.windowId, reason: "zone-removal-reassignment")
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

        if let temporaryScreenId = delegate.targetedTemporaryScreenId {
            delegate.assignWindowToTemporaryZone(
                managed,
                on: temporaryScreenId,
                centerWindow: true,
                reason: "zone-removal-temporary"
            )
            return
        }

        Logger.debug("Zone removal minimizing window \(managed.windowId); no available zone without displacement")
        delegate.clearManagedWindowZone(managed)
        delegate.windowController.minimizeWindow(managed)
    }

    /// Moves an already managed window between zones, optionally minimizing displaced occupants.
    func moveWindow(
        _ managed: ManagedWindow,
        from originKey: ZoneKey,
        to destinationKey: ZoneKey,
        minimizeDisplacedWindows: Bool = true
    ) -> Bool {
        guard let delegate = delegate else { return false }

        if originKey == destinationKey {
            Logger.debug("Move window skipped: window \(managed.windowId) already in zone \(originKey.index) on screen \(originKey.screenId)")
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

        originContext.zoneController.removeWindow(windowId: managed.windowId)
        delegate.clearManagedWindowZone(managed)

        let destinationWasEmpty = zoneWasEmptyBeforePlacement(destinationZone)
        let displacedWindow = removeOccupantIfNeeded(
            in: destinationZone,
            controller: destinationContext.zoneController,
            excluding: managed.windowId
        )

        assignWindowToZone(
            managed,
            zone: destinationZone,
            screenId: destinationKey.screenId,
            descriptor: descriptor,
            zoneWasEmptyBeforeAssignment: destinationWasEmpty
        )

        if minimizeDisplacedWindows {
            minimizeOrCloseDisplacedWindow(displacedWindow)
        }

        let originScreenIndex = delegate.screenOrder.firstIndex(of: originKey.screenId) ?? Int(originKey.screenId)
        let destinationScreenIndex = delegate.screenOrder.firstIndex(of: destinationKey.screenId) ?? Int(destinationKey.screenId)
        Logger.debug(
            "Move window completed: \(managed.windowId) from screen \(originScreenIndex) zone \(originKey.index) to screen \(destinationScreenIndex) zone \(destinationKey.index)"
        )
        return true
    }

    // MARK: - Private Methods

    /// Places a window into the currently targeted zone, resolving fallbacks as needed.
    private func placeWindowInTargetedZone(_ managed: ManagedWindow, targetedKey: ZoneKey?) {
        guard let delegate = delegate else { return }

        let resolvedTarget: ZoneKey?
        if let targetedKey {
            resolvedTarget = targetedKey
        } else {
            delegate.targetedZoneManager.ensureTargetedZone(reason: "placing-window")
            resolvedTarget = delegate.targetedZoneKey
        }

        guard let targetKey = resolvedTarget,
              let context = delegate.screenContexts[targetKey.screenId],
              let descriptor = delegate.descriptor(for: targetKey.screenId),
              let zone = context.zoneController.zone(at: targetKey.index) else {
            let fallbackScreen = delegate.detectScreenId(for: managed) ?? delegate.activeScreenId()
            placeWindow(managed, on: fallbackScreen)
            return
        }

        let controller = context.zoneController
        let zoneWasEmptyBeforeAssignment = zoneWasEmptyBeforePlacement(zone)
        let displacedWindow = removeOccupantIfNeeded(in: zone, controller: controller, excluding: managed.windowId)

        assignWindowToZone(
            managed,
            zone: zone,
            screenId: targetKey.screenId,
            descriptor: descriptor,
            zoneWasEmptyBeforeAssignment: zoneWasEmptyBeforeAssignment
        )

        minimizeOrCloseDisplacedWindow(displacedWindow)
    }

    /// Places a window on a specific screen, preferring empty zones before evicting occupants.
    private func placeWindow(_ managed: ManagedWindow, on screenId: CGDirectDisplayID) {
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
        let displacedWindow = removeOccupantIfNeeded(in: highestZone, controller: controller, excluding: managed.windowId)

        assignWindowToZone(
            managed,
            zone: highestZone,
            screenId: screenId,
            descriptor: descriptor,
            zoneWasEmptyBeforeAssignment: zoneWasEmptyBeforeAssignment
        )

        minimizeOrCloseDisplacedWindow(displacedWindow)
    }

    /// Assigns a managed window to a zone and updates targeted-zone bookkeeping.
    private func assignWindowToZone(
        _ managed: ManagedWindow,
        zone: Zone,
        screenId: CGDirectDisplayID,
        descriptor: ScreenDescriptor,
        zoneWasEmptyBeforeAssignment: Bool
    ) {
        guard let delegate = delegate else { return }

        let filledZoneKey = ZoneKey(screenId: screenId, index: zone.index)
        let wasTargetedZone = delegate.targetedZoneManager.targetedZoneKey == filledZoneKey

        for window in delegate.windowController.allWindows where window.isPlaceholder {
            if window.zoneIndex == zone.index && window.screenDisplayId == screenId {
                delegate.windowController.closeWindow(window)
                delegate.forgetPlaceholder(windowId: window.windowId)
            }
        }

        guard let controller = delegate.zoneController(for: screenId) else {
            return
        }
        controller.assignWindow(windowId: managed.windowId, toZoneIndex: zone.index)
        let displayFrame = delegate.frameWithMargin(for: zone, in: controller)
        delegate.windowController.showWindow(managed, at: displayFrame, on: descriptor)
        delegate.setManagedWindow(managed, screenId: screenId, zoneIndex: zone.index)
        delegate.updateTemporaryZoneTargeting(reason: "zone-assignment")

        if zoneWasEmptyBeforeAssignment && wasTargetedZone {
            // Specification: filling the targeted zone promotes the lowest-index remaining empty zone (if any)
            let nextEmpty = delegate.targetedZoneManager.lowestIndexEmptyZone(excluding: filledZoneKey)
            if let nextEmpty {
                delegate.targetedZoneManager.setTargetedZone(nextEmpty, reason: "zone-filled-switch-to-empty")
            }
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
        let displacedWindow = removeOccupantIfNeeded(
            in: zone,
            controller: context.zoneController,
            excluding: managed.windowId
        )

        assignWindowToZone(
            managed,
            zone: zone,
            screenId: targetKey.screenId,
            descriptor: descriptor,
            zoneWasEmptyBeforeAssignment: zoneWasEmptyBeforeAssignment
        )
        return DragAssignmentResult(displacedWindow: displacedWindow)
    }

    private func zoneWasEmptyBeforePlacement(_ zone: Zone) -> Bool {
        guard let occupantId = zone.windowId else {
            return true
        }
        guard let delegate = delegate,
              let occupant = delegate.windowController.window(withId: occupantId) else {
            return false
        }
        return occupant.isPlaceholder
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
                if zone.windowId == nil {
                    return (zone, context, descriptor)
                }

                if let windowId = zone.windowId,
                   let occupant = delegate.windowController.window(withId: windowId),
                   occupant.isPlaceholder {
                    return (zone, context, descriptor)
                }
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

    /// Removes an existing zone occupant (if any) so the caller can place another window.
    private func removeOccupantIfNeeded(
        in zone: Zone,
        controller: ZoneController,
        excluding windowId: Int
    ) -> ManagedWindow? {
        guard let delegate = delegate else { return nil }
        guard let existingId = zone.windowId,
              existingId != windowId,
              let existingWindow = delegate.windowController.window(withId: existingId) else {
            return nil
        }
        controller.removeWindow(windowId: existingId)
        return existingWindow
    }

    /// Applies the standard displacement policy: close placeholders or minimize real windows.
    private func minimizeOrCloseDisplacedWindow(_ displaced: ManagedWindow?) {
        guard let delegate = delegate, let displaced else { return }
        if displaced.isPlaceholder {
            delegate.windowController.closeWindow(displaced)
            delegate.forgetPlaceholder(windowId: displaced.windowId)
        } else {
            delegate.clearManagedWindowZone(displaced)
            delegate.windowController.minimizeWindow(displaced)
        }
    }
}
