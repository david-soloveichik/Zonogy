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

    // Placement deferral
    func shouldDeferPlacementForNewWindow(_ managed: ManagedWindow, targetedZoneKey: ZoneKey?) -> Bool
}

class WindowPlacementManager {
    weak var delegate: WindowPlacementManagerDelegate?

    init() {}

    // MARK: - Public Methods

    func placeNewWindow(_ managed: ManagedWindow, preferredScreenId: CGDirectDisplayID? = nil) {
        guard let delegate = delegate else { return }

        delegate.removeWindowFromAllZones(windowId: managed.windowId, reason: "place-new-window")
        managed.zoneIndex = nil

        if let preferredScreenId {
            placeWindow(managed, on: preferredScreenId)
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

    func handleWindowAfterZoneRemoval(_ managed: ManagedWindow, preferredScreenId: CGDirectDisplayID) {
        guard let delegate = delegate else { return }

        delegate.removeWindowFromAllZones(windowId: managed.windowId, reason: "zone-removal-reassignment")
        managed.zoneIndex = nil

        if let (zone, context, descriptor) = findZoneAcceptingRemovedWindow(preferredScreenId: preferredScreenId) {
            Logger.debug(
                "Zone removal reassigning window \(managed.windowId) to zone \(zone.index) on \(context.descriptor.localizedName) [\(context.descriptor.displayId)]"
            )
            assignWindowToZone(managed, zone: zone, screenId: context.descriptor.displayId, descriptor: descriptor)
            return
        }

        Logger.debug("Zone removal minimizing window \(managed.windowId); no available zone without displacement")
        delegate.clearManagedWindowZone(managed)
        delegate.windowController.minimizeWindow(managed)
    }

    // MARK: - Private Methods

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
        var displacedWindow: ManagedWindow?
        if let existingId = zone.windowId,
           existingId != managed.windowId,
           let existingWindow = delegate.windowController.window(withId: existingId) {
            controller.removeWindow(windowId: existingId)
            displacedWindow = existingWindow
        }

        assignWindowToZone(managed, zone: zone, screenId: targetKey.screenId, descriptor: descriptor)

        if let displaced = displacedWindow {
            if displaced.isPlaceholder {
                delegate.windowController.closeWindow(displaced)
                delegate.forgetPlaceholder(windowId: displaced.windowId)
            } else {
                delegate.clearManagedWindowZone(displaced)
                delegate.windowController.minimizeWindow(displaced)
            }
        }
    }

    private func placeWindow(_ managed: ManagedWindow, on screenId: CGDirectDisplayID) {
        guard let delegate = delegate,
              let controller = delegate.zoneController(for: screenId),
              let descriptor = delegate.descriptor(for: screenId) else {
            return
        }

        if let emptyZone = controller.findEmptyZone() {
            assignWindowToZone(managed, zone: emptyZone, screenId: screenId, descriptor: descriptor)
            return
        }

        guard let highestZone = controller.highestIndexZone() else {
            return
        }

        var displacedWindow: ManagedWindow?
        if let oldWindowId = highestZone.windowId,
           oldWindowId != managed.windowId,
           let oldWindow = delegate.windowController.window(withId: oldWindowId) {
            controller.removeWindow(windowId: oldWindowId)
            displacedWindow = oldWindow
        }

        assignWindowToZone(managed, zone: highestZone, screenId: screenId, descriptor: descriptor)

        if let displaced = displacedWindow {
            if displaced.isPlaceholder {
                delegate.windowController.closeWindow(displaced)
                delegate.forgetPlaceholder(windowId: displaced.windowId)
            } else {
                delegate.clearManagedWindowZone(displaced)
                delegate.windowController.minimizeWindow(displaced)
            }
        }
    }

    private func assignWindowToZone(
        _ managed: ManagedWindow,
        zone: Zone,
        screenId: CGDirectDisplayID,
        descriptor: ScreenDescriptor
    ) {
        guard let delegate = delegate else { return }

        let filledZoneKey = ZoneKey(screenId: screenId, index: zone.index)
        let wasTargetedZone = delegate.targetedZoneManager.targetedZoneKey == filledZoneKey

        // Track if this zone was empty (had a placeholder) before we fill it
        var wasEmptyZone = false
        for window in delegate.windowController.allWindows where window.isPlaceholder {
            if window.zoneIndex == zone.index && window.screenDisplayId == screenId {
                delegate.windowController.closeWindow(window)
                delegate.forgetPlaceholder(windowId: window.windowId)
                wasEmptyZone = true
            }
        }

        guard let controller = delegate.zoneController(for: screenId) else {
            return
        }
        controller.assignWindow(windowId: managed.windowId, toZoneIndex: zone.index)
        let displayFrame = delegate.frameWithMargin(for: zone, in: controller)
        delegate.windowController.showWindow(managed, at: displayFrame, on: descriptor)
        delegate.setManagedWindow(managed, screenId: screenId, zoneIndex: zone.index)

        if wasEmptyZone && wasTargetedZone {
            // Specification: filling the targeted zone promotes the lowest-index remaining empty zone (if any)
            let nextEmpty = delegate.targetedZoneManager.lowestIndexEmptyZone(excluding: filledZoneKey)
            if let nextEmpty {
                delegate.targetedZoneManager.setTargetedZone(nextEmpty, reason: "zone-filled-switch-to-empty")
            }
        }
    }

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
}
