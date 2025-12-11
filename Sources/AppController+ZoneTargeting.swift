import Foundation
import AppKit
import ApplicationServices

/// Targeted zone bookkeeping, manual window removal, and zone click interception.
extension AppController {
    func zoneController(for screenId: CGDirectDisplayID) -> ZoneController? {
        screenContexts[screenId]?.zoneController
    }

    internal func removeWindowFromAllZones(windowId: Int, reason: String = "unspecified", retarget: Bool = true) {
        if dragDropCoordinator.currentDragWindowId == windowId {
            // Ensure overlays go away when the dragged window disappears.
            dragDropCoordinator.tearDownDragSession()
        }

        var removed = false
        var emptyZoneKey: ZoneKey?

        for (screenId, context) in screenContexts {
            if let zone = context.zoneController.zoneForWindow(windowId: windowId) {
                Logger.debug(
                    "Removing window \(windowId) from zone \(zone.index) on \(context.descriptor.localizedName) [\(screenId)] (reason: \(reason))"
                )
                context.zoneController.removeWindow(windowId: windowId)
                removed = true
                // Specification: Newly empty zones should become targeted when the current target is filled or has a higher index.
                emptyZoneKey = ZoneKey(screenId: screenId, index: zone.index)
            } else {
                context.zoneController.removeWindow(windowId: windowId)
            }
        }

        if retarget, let emptyZoneKey = emptyZoneKey {
            targetedZoneManager.setTargetedZone(emptyZoneKey, reason: reason)
        }

        clearTemporaryZone(for: windowId, minimize: false, reason: reason)

        if !removed, reason != "place-new-window" {
            Logger.debug("Requested removal of window \(windowId) from all zones but none were assigned (reason: \(reason))")
        }
    }

    internal func shouldRetarget(to candidate: ZoneKey) -> Bool {
        if let tempScreen = targetedZoneManager.targetedTemporaryScreenId {
            if temporaryZoneOccupant(on: tempScreen) != nil {
                // Specification: keep the targeted temporary zone while it still holds a window.
                return false
            }
            // Temporary zone is targeted but currently empty; fall back to normal rules.
        }

        guard let currentKey = targetedZoneManager.targetedZoneKey else {
            return true
        }
        if !targetedZoneManager.zoneExists(currentKey) {
            return true
        }
        if !targetedZoneManager.isZoneEmpty(currentKey) {
            return true
        }
        if currentKey.index > candidate.index {
            return true
        }
        return false
    }

    internal func zoneKey(for screenId: CGDirectDisplayID, index: Int) -> ZoneKey {
        ZoneKey(screenId: screenId, index: index)
    }

    private func zoneKey(containingScreenPoint location: CGPoint) -> ZoneKey? {
        let locationRect = CGRect(origin: location, size: .zero)

        for screenId in screenOrder {
            guard let context = screenContexts[screenId] else {
                continue
            }

            let descriptor = context.descriptor
            let accessibilityBounds = descriptor.screenToAccessibility(descriptor.visibleScreenBounds)
            guard accessibilityBounds.contains(location) else {
                continue
            }

            let screenPoint = descriptor.accessibilityToScreen(locationRect).origin
            if let zone = context.zoneController.allZones.first(where: { $0.frame.contains(screenPoint) }) {
                return ZoneKey(screenId: screenId, index: zone.index)
            }

            return nil
        }

        return nil
    }

    internal func setManagedWindow(_ managed: ManagedWindow, screenId: CGDirectDisplayID, zoneIndex: Int?) {
        managed.screenDisplayId = screenId
        managed.zoneIndex = zoneIndex
        if zoneIndex != nil, !managed.isPlaceholder {
            clearTemporaryZone(for: managed.windowId, minimize: false, reason: "assigned-to-tiled-zone")
        }
        activeFitHandleAssignmentChange(managed: managed, screenId: screenId, zoneIndex: zoneIndex)
    }

    internal func clearManagedWindowZone(_ managed: ManagedWindow) {
        managed.zoneIndex = nil
        managed.screenDisplayId = nil
        clearRevealModeForWindow(windowId: managed.windowId, transitionToRest: false, reason: "assignment-cleared")
        activeFitClearSuppressionForWindow(managed.windowId)
    }

    internal func forgetPlaceholder(windowId: Int) {
        placeholderCoordinator.forget(windowId: windowId)
    }

    internal func detectScreenId(for managed: ManagedWindow) -> CGDirectDisplayID? {
        if let existing = managed.screenDisplayId, screenContexts[existing] != nil {
            return existing
        }

        guard let cocoaFrame = cocoaFrame(for: managed) else {
            return nil
        }

        var bestId: CGDirectDisplayID?
        var largestArea: CGFloat = 0

        for (screenId, context) in screenContexts {
            let intersection = cocoaFrame.intersection(context.descriptor.cocoaBounds)
            if intersection.isNull {
                continue
            }
            let area = intersection.width * intersection.height
            if area > largestArea {
                largestArea = area
                bestId = screenId
            }
        }

        if let bestId, largestArea > 0 {
            return bestId
        }

        for (screenId, context) in screenContexts {
            if context.descriptor.cocoaBounds.contains(cocoaFrame.origin) {
                return screenId
            }
        }

        return nil
    }

    internal func cocoaFrame(for managed: ManagedWindow) -> CGRect? {
        switch managed.backing {
        case .appKit(let window):
            return window.frame
        case .accessibility(let element, _, _):
            guard let position = ManagedWindow.copyCGPointValue(element: element, attribute: kAXPositionAttribute as CFString),
                  let size = ManagedWindow.copyCGSizeValue(element: element, attribute: kAXSizeAttribute as CFString) else {
                return nil
            }
            let accessibilityFrame = CGRect(origin: position, size: size)
            return CoordinateConversion.accessibilityToCocoa(
                accessibilityFrame: accessibilityFrame,
                primaryScreenBounds: primaryScreenBounds
            )
        }
    }

    // MARK: - ZoneClickInterceptorDelegate

    func zoneClickInterceptor(_ interceptor: ZoneClickInterceptor, shouldConsumeClickAt location: CGPoint) -> Bool {
        // Don't intercept clicks when WinShot chooser is active - allow clicks to pass through
        if winShotChooserController.isActive {
            return false
        }

        guard let key = zoneKey(containingScreenPoint: location) else {
            return false
        }

        targetedZoneManager.setTargetedZone(key, reason: "control-command-click")
        return true
    }

}
