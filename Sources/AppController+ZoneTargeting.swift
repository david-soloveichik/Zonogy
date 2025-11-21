import Foundation
import AppKit
import ApplicationServices

/// Targeted zone bookkeeping, manual window removal, and zone click interception.
extension AppController {
    func zoneController(for screenId: CGDirectDisplayID) -> ZoneController? {
        screenContexts[screenId]?.zoneController
    }

    internal func removeWindowFromAllZones(windowId: Int, reason: String = "unspecified") {
        var removed = false
        var emptyZoneKey: ZoneKey?

        if dragDropCoordinator.currentDragWindowId == windowId {
            // Ensure overlays go away when the dragged window disappears.
            dragDropCoordinator.tearDownDragSession()
        }

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

        if let emptyZoneKey = emptyZoneKey {
            targetedZoneManager.setTargetedZone(emptyZoneKey, reason: reason)
        }

        clearTemporaryZone(for: windowId, minimize: false, reason: reason)

        if !removed, reason != "place-new-window" {
            Logger.debug("Requested removal of window \(windowId) from all zones but none were assigned (reason: \(reason))")
        }
    }

    /// Work around macOS missing focus notifications when an app's final managed window closes or minimizes.
    internal func triggerActivationWorkaroundIfNeeded(pid: pid_t, excludingWindowIds: Set<Int>, reason: String) {
        guard pid != getpid() else {
            return
        }

        let otherManagedExists = windowController.allWindows.contains { candidate in
            guard case .accessibility(_, let otherPid, _) = candidate.backing,
                  otherPid == pid else {
                return false
            }
            if excludingWindowIds.contains(candidate.windowId) {
                return false
            }
            if candidate.isPlaceholder {
                return false
            }
            if candidate.isMinimized {
                return false
            }
            return true
        }

        if otherManagedExists {
            return
        }

        let targetApplication = NSRunningApplication(processIdentifier: pid)
        let latticeApplication = NSRunningApplication(processIdentifier: getpid())

        guard let targetApplication else {
            Logger.debug("Activation workaround skipped: unable to resolve NSRunningApplication for pid \(pid)")
            return
        }

        // Check if the target application is frontmost (as per updated specification)
        guard targetApplication.isActive else {
            Logger.debug("Activation workaround skipped: pid \(pid) is not frontmost (reason: \(reason))")
            return
        }

        Logger.debug("Activation workaround: activation sequence queued for pid \(pid) (reason: \(reason))")

        let performActivation = {
            if let latticeApplication {
                let selfResult = latticeApplication.activate(options: [.activateIgnoringOtherApps])
                Logger.debug("Activation workaround: activated Zonogy before pid \(pid) (result: \(selfResult))")
            } else {
                Logger.debug("Activation workaround: unable to resolve Zonogy application for pre-activation")
            }

            // Add small delay to allow OS to process the first activation
            DispatchQueue.main.asyncAfter(deadline: .now()) {
                let targetResult = targetApplication.activate(options: [.activateIgnoringOtherApps])
                Logger.debug("Activation workaround: reactivated pid \(pid) (result: \(targetResult))")
            }
        }

        if Thread.isMainThread {
            performActivation()
        } else {
            DispatchQueue.main.async(execute: performActivation)
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
        if zoneIndex != nil {
            clearTemporaryZone(for: managed.windowId, minimize: false, reason: "assigned-to-tiled-zone")
            let key = ZoneKey(screenId: screenId, index: zoneIndex!)
            liveZoneAssignments = liveZoneAssignments.filter { $0.value.identity.windowId != managed.windowId || $0.key == key }
            liveZoneAssignments[key] = ZoneAssignmentSnapshot(
                zoneKey: key,
                identity: .make(from: managed)
            )
        }
        activeFitHandleAssignmentChange(managed: managed, screenId: screenId, zoneIndex: zoneIndex)
    }

    internal func clearManagedWindowZone(_ managed: ManagedWindow) {
        managed.zoneIndex = nil
        managed.screenDisplayId = nil
        activeFitClearForWindowIfNeeded(windowId: managed.windowId, restoreToZone: false, reason: "assignment-cleared")
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
        guard let key = zoneKey(containingScreenPoint: location) else {
            return false
        }

        targetedZoneManager.setTargetedZone(key, reason: "control-command-click")
        return true
    }

}
