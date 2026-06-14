import Foundation
import AppKit
import ApplicationServices
import CoreGraphics

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
        if floatingDragHandler.draggingWindowId == windowId {
            // A floating-zone drag uses a separate handler and overlay manager from the
            // tiled coordinator above, so it needs its own teardown. Without this, a window
            // that disappears mid floating-drag (e.g. a Chrome tab tears out, or the window
            // is minimized while being dragged) leaves the blue zone overlays stuck on screen.
            floatingDragHandler.abortDrag()
        }

        // Capture floating-zone occupancy before any clearing happens, so we can apply
        // the floating-empty retarget rule below after the floating slot is cleared.
        let floatingScreenIdBeforeClear = floatingZoneCoordinator.occupants
            .first(where: { $0.value == windowId })?.key

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

        // Specification: when a floating zone is emptied (window minimized/closed) and the
        // current target is *another* floating zone, retarget to the now-empty floating zone.
        // Floating zones are "weaker" — they never steal targeting from tiling zones. Gated
        // by `retarget` to honor the explicit-reassignment exception (Launcher/DockMenu drops
        // pass `retarget: false`).
        if retarget,
           let emptiedFloatingScreenId = floatingScreenIdBeforeClear,
           let retargetScreenId = FloatingZoneEmptyRetargetPolicy.retargetScreenId(
               emptiedScreenId: emptiedFloatingScreenId,
               currentTarget: targetedZoneManager.targetedDestination
           ) {
            targetedZoneManager.setFloatingTarget(on: retargetScreenId, reason: reason)
        }

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

    func zoneClickInterceptor(
        _ interceptor: ZoneClickInterceptor,
        shouldConsumeClickAt location: CGPoint,
        modifiers: CGEventFlags,
        clickCount: Int
    ) -> Bool {
        // Don't intercept clicks when WinShot chooser is active - allow clicks to pass through
        if winShotChooserController.isActive {
            return false
        }

        // While CmdTab is visible, any left-click retargets a zone instead of dismissing
        // CmdTab; clicks on our own Zonogy UI pass through to those windows' own handlers;
        // clicks outside every zone fall back to dismissal. See SPECIFICATION-CMDTAB.md.
        if cmdTabController.isActive {
            return handleClickWhileCmdTabVisible(at: location)
        }

        // Not in CmdTab mode: only Control+Command-click is used for targeting.
        guard modifiers.contains([.maskCommand, .maskControl]) else {
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

        let trigger: String? = clickCount >= 2 ? "control-command-double-click" : nil
        // The border flash is driven by the retarget itself (see `retargetForUserGesture`).
        retargetForUserGesture(.tiled(key), reason: "control-command-click", openingLauncherWith: trigger)
        return true
    }

    /// Route a left-click while CmdTab is visible. Returns true if the event should be consumed.
    private func handleClickWhileCmdTabVisible(at location: CGPoint) -> Bool {
        // If the click lands on any of our own windows, let AppKit route it to that window
        // and do nothing here. Interactive zone UI (CmdTab rows, placeholder surface and its
        // ×/⌄ button, indicators, resize bars) dispatches its own mouseDown; passive overlays
        // (flash overlay, passive drag overlays) simply absorb the click. Either way,
        // retargeting or dismissing from here would fight that dispatch.
        if clickLandsOnOwnWindow(at: location) {
            return false
        }

        if let key = zoneKey(containingScreenPoint: location) {
            // A real change flashes via `targetedZoneDidChange`; flash here only when re-affirming the
            // already-targeted zone so the click is still confirmed without double-flashing.
            let wasAlreadyTargeted = targetedZoneManager.targetedDestination == .tiled(key)
            targetedZoneManager.setTargetedZone(key, reason: "cmdtab-click-retarget")
            if wasAlreadyTargeted {
                flashTargetFeedback(for: key)
            }
            return true
        }

        // Click didn't land on any Zonogy UI or any tiling zone (desktop, menu bar, dock,
        // full-screen space, or a managed window outside every zone): dismiss CmdTab. Other
        // dismiss paths (Escape, modifier release, full-screen pause) are unchanged.
        cmdTabController.cancel()
        return false
    }

    /// Returns true if the click location (in accessibility coordinates) falls on a visible
    /// window belonging to our own process.
    private func clickLandsOnOwnWindow(at accessibilityLocation: CGPoint) -> Bool {
        let axRect = CGRect(origin: accessibilityLocation, size: .zero)
        let cocoaPoint = CoordinateConversion.accessibilityToCocoa(
            accessibilityFrame: axRect,
            primaryScreenBounds: primaryScreenBounds
        ).origin

        for window in NSApp.windows {
            guard window.isVisible, !window.isMiniaturized else {
                continue
            }
            if window.frame.contains(cocoaPoint) {
                return true
            }
        }
        return false
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

    /// Runs `body` with the target-change border flash suppressed, restoring the prior state after.
    /// Used for operations whose retarget should not flash — e.g. creating a zone targets the new
    /// zone, but the appearing placeholder already draws the eye, so an extra flash looks wrong.
    func withTargetChangeFlashSuppressed(_ body: () -> Void) {
        let previous = suppressTargetChangeFlash
        suppressTargetChangeFlash = true
        defer { suppressTargetChangeFlash = previous }
        body()
    }

}
