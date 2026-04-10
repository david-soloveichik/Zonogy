import Foundation
import AppKit
import ApplicationServices

/// Targeted zone bookkeeping, manual window removal, and zone click interception.
extension AppController {
    func zoneController(for screenId: CGDirectDisplayID) -> ZoneController? {
        screenContexts[screenId]?.zoneController
    }

    internal func removeWindowFromAllZones(
        windowId: Int,
        reason: String = "unspecified",
        retarget: Bool = true,
        logIfUnassigned: Bool = true
    ) {
        if dragDropCoordinator.currentDragWindowId == windowId {
            // Ensure overlays go away when the dragged window disappears.
            dragDropCoordinator.tearDownDragSession()
        }

        // Clear the window's record of its zone assignment (ManagedWindow -> Zone)
        if let managed = windowController.window(withId: windowId) {
            clearManagedWindowZone(managed)
        }

        var removed = false
        var emptyZoneKey: ZoneKey?

        // Clear each zone's record of this window (Zone -> ManagedWindow)
        for (screenId, context) in screenContexts {
            if let zone = context.zoneController.zoneForWindow(windowId: windowId) {
                Logger.debug(
                    "Removing window \(windowId) from zone \(zone.index) on \(context.descriptor.localizedName) [\(screenId)] (reason: \(reason))"
                )
                context.zoneController.removeWindow(windowId: windowId)
                removed = true
                // Specification: Whenever a tiling zone becomes empty, target that zone.
                emptyZoneKey = ZoneKey(screenId: screenId, index: zone.index)
            } else {
                context.zoneController.removeWindow(windowId: windowId)
            }
        }

        if retarget, let emptyZoneKey = emptyZoneKey {
            targetedZoneManager.setTargetedZone(emptyZoneKey, reason: reason)
            // Auto-show Launcher if the emptied zone is now the targeted zone.
            // This handles the case where the zone was already targeted (setTargetedZone returns early).
            autoShowLauncherIfEmptyTargetedTiledZone()
        }

        clearFloatingZone(for: windowId, minimize: false, reason: reason)

        if !removed, logIfUnassigned {
            Logger.debug("Requested removal of window \(windowId) from all zones but none were assigned (reason: \(reason))")
        }
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
            if isScreenPausedForFullScreen(screenId) {
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
            clearFloatingZone(for: managed.windowId, minimize: false, reason: "assigned-to-tiled-zone")
        }
        activeFitHandleAssignmentChange(managed: managed, screenId: screenId, zoneIndex: zoneIndex)
    }

    internal func clearManagedWindowZone(_ managed: ManagedWindow) {
        clearRememberedManualResizeSize(for: managed.windowId, reason: "assignment-cleared")
        managed.zoneIndex = nil
        managed.screenDisplayId = nil
        managed.isInFloatingZone = false
        clearRevealModeForWindow(windowId: managed.windowId, transitionToRest: false, reason: "assignment-cleared")
        activeFitClearSuppressionForWindow(managed.windowId)
    }

    internal func detectScreenId(for managed: ManagedWindow) -> CGDirectDisplayID? {
        if let existing = managed.screenDisplayId, screenContexts[existing] != nil {
            return existing
        }

        guard let cocoaFrame = cocoaFrame(for: managed) else {
            return nil
        }

        if let screenId = screenIdForCocoaFrame(cocoaFrame) {
            return screenId
        }

        // Fallback: check if the frame origin is contained in any screen
        for (screenId, context) in screenContexts {
            if context.descriptor.cocoaBounds.contains(cocoaFrame.origin) {
                return screenId
            }
        }

        return nil
    }

    internal func detectScreenId(for element: AXUIElement) -> CGDirectDisplayID? {
        guard let position = ManagedWindow.copyCGPointValue(element: element, attribute: kAXPositionAttribute as CFString),
              let size = ManagedWindow.copyCGSizeValue(element: element, attribute: kAXSizeAttribute as CFString) else {
            return nil
        }

        let accessibilityFrame = CGRect(origin: position, size: size)
        let cocoaFrame = CoordinateConversion.accessibilityToCocoa(
            accessibilityFrame: accessibilityFrame,
            primaryScreenBounds: primaryScreenBounds
        )

        if let screenId = screenIdForCocoaFrame(cocoaFrame) {
            return screenId
        }

        for (screenId, context) in screenContexts {
            if context.descriptor.cocoaBounds.contains(cocoaFrame.origin) {
                return screenId
            }
        }

        return nil
    }

    /// Returns the screen ID that has the largest intersection with the given Cocoa frame.
    /// Returns nil if the frame doesn't intersect any screen.
    internal func screenIdForCocoaFrame(_ cocoaFrame: CGRect) -> CGDirectDisplayID? {
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

        return largestArea > 0 ? bestId : nil
    }

    internal func cocoaFrame(for managed: ManagedWindow) -> CGRect? {
        let element = managed.backing.element
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

    // MARK: - ZoneClickInterceptorDelegate

    func zoneClickInterceptor(_ interceptor: ZoneClickInterceptor, shouldConsumeClickAt location: CGPoint) -> Bool {
        // Don't intercept clicks when WinShot chooser is active - allow clicks to pass through
        if winShotChooserController.isActive {
            return false
        }

        // CmdTab: while the CmdTab overlay is visible, disable Control-Command click targeting
        // to avoid conflicts with CmdTab interactions.
        if cmdTabController.isActive {
            return false
        }

        // Ctrl+Cmd-click on the Add Zone pill should behave like a regular left-click.
        for (screenId, hitArea) in addIndicatorTracker.hitAreas {
            if hitArea.contains(location) {
                addZoneIndicatorManager(addZoneIndicatorManager, didClickIndicatorFor: screenId)
                return true
            }
        }

        // Ctrl+Cmd-click on the Floating Zone indicator should behave like a regular left-click.
        for (screenId, hitArea) in floatingIndicatorTracker.hitAreas {
            if hitArea.contains(location) {
                let wasAlreadyTargeted = targetedFloatingScreenId == screenId
                floatingZoneIndicatorActivated(screenId: screenId, wasAlreadyTargeted: wasAlreadyTargeted, isDoubleClick: false)
                return true
            }
        }

        if shouldPassThroughControlCommandClick(at: location) {
            return false
        }

        guard let key = zoneKey(containingScreenPoint: location) else {
            return false
        }

        targetedZoneManager.setTargetedZone(key, reason: "control-command-click")
        flashTargetFeedback(for: key)
        return true
    }

    func flashTargetFeedback(for key: ZoneKey) {
        if placeholderCoordinator.hasPlaceholder(for: key) {
            placeholderCoordinator.flashPlaceholderBorder(for: key)
        } else if let context = screenContexts[key.screenId],
                  let zone = context.zoneController.zone(at: key.index) {
            let screenFrame = frameWithMargin(for: zone, in: context.zoneController)
            let cocoaFrame = context.descriptor.screenToCocoa(screenFrame)
            zoneFlashOverlay.flash(at: cocoaFrame)
        }
    }

}
