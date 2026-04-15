import AppKit
import ApplicationServices
import Foundation

/// Shared explicit-drop helpers for cursor-driven drags initiated by Launcher and DockMenus.
extension AppController {
    internal func beginCursorDrivenWindowDrag(for window: LauncherWindowItem) -> Bool {
        guard let managedWindowId = window.managedWindowId,
              let managed = windowController.window(withId: managedWindowId) else {
            Logger.debug("Cursor-driven drop: cannot begin window drag - window not managed")
            return false
        }

        let originZoneKey = zoneKey(forManagedWindow: managed)
        let originScreenId = detectScreenId(for: managed)
        let originatedFromFloating = isWindowInFloatingZone(managed.windowId)

        dragDropCoordinator.beginCursorDrivenDragSession(
            windowId: managedWindowId,
            originZoneKey: originZoneKey,
            originScreenId: originScreenId,
            originatedFromFloating: originatedFromFloating
        )
        return true
    }

    internal func beginCursorDrivenLaunchTargetDrag(zoneDropPolicy: CursorDrivenZoneDropPolicy = .allZones) {
        dragDropCoordinator.beginCursorDrivenDragSession(
            windowId: nil,
            originZoneKey: nil,
            originScreenId: nil,
            zoneDropPolicy: zoneDropPolicy
        )
    }

    @discardableResult
    internal func performCursorDrivenManagedWindowDrop(
        for window: LauncherWindowItem,
        cursorPointAX: CGPoint?,
        reason: String
    ) -> Bool {
        let target = dragDropCoordinator.endCursorDrivenDragSession(cursorPointAX: cursorPointAX)
        return performCursorDrivenManagedWindowDrop(for: window, target: target, reason: reason)
    }

    @discardableResult
    internal func performCursorDrivenManagedWindowDrop(
        for window: LauncherWindowItem,
        target: DragDropCoordinator.CursorDrivenDropTarget,
        reason: String
    ) -> Bool {
        switch target {
        case .tilingZone(let zoneKey):
            return placeManagedWindowItem(window, intoTilingZone: zoneKey, reason: reason)
        case .floatingZone(let screenId):
            return placeManagedWindowItem(window, intoFloatingZone: screenId, reason: reason)
        case .addZone(let screenId):
            guard let newZone = addZone(on: screenId, announce: false, promoteFloatingOccupant: false) else {
                Logger.debug("Cursor-driven drop: cannot add zone on screen \(screenContextStore.loggingIndex(for: screenId))")
                return false
            }
            return placeManagedWindowItem(
                window,
                intoTilingZone: ZoneKey(screenId: screenId, index: newZone.index),
                reason: reason
            )
        case .cancelled:
            Logger.debug("Cursor-driven drop: window drag cancelled")
            return false
        }
    }

    @discardableResult
    internal func performCursorDrivenAppDrop(
        for appURL: URL,
        cursorPointAX: CGPoint?,
        reason: String
    ) -> Bool {
        let target = dragDropCoordinator.endCursorDrivenDragSession(cursorPointAX: cursorPointAX)
        guard applyCursorDrivenLaunchTarget(target, reason: reason) else {
            Logger.debug("Cursor-driven drop: app drag cancelled for \(appURL.lastPathComponent)")
            return false
        }

        performDefaultLauncherAction(for: appURL)
        return true
    }

    @discardableResult
    internal func performCursorDrivenLaunchableDrop(
        items: [ExternalDropItem],
        cursorPointAX: CGPoint?,
        reason: String
    ) -> Bool {
        let target = dragDropCoordinator.endCursorDrivenDragSession(cursorPointAX: cursorPointAX)
        guard !items.isEmpty else {
            Logger.debug("Cursor-driven drop: launchable drag had no items")
            return false
        }

        switch target {
        case .tilingZone(let zoneKey):
            let clearExistingOccupant = zoneOccupantWindowId(for: zoneKey) != nil
            handleExternalDrop(
                into: zoneKey,
                items: items,
                clearExistingOccupant: clearExistingOccupant,
                reason: reason
            )
            return true
        case .floatingZone(let screenId):
            targetedZoneManager.setFloatingTarget(on: screenId, reason: reason)
            openExternalDropItems(items)
            return true
        case .addZone(let screenId):
            if let zone = addZone(on: screenId, announce: false, promoteFloatingOccupant: false) {
                let newZoneKey = zoneKey(for: screenId, index: zone.index)
                targetedZoneManager.setTargetedZone(newZoneKey, reason: reason)
            } else {
                Logger.debug("Cursor-driven drop: add-zone launchable drop hit max zones on screen \(screenContextStore.loggingIndex(for: screenId))")
            }
            openExternalDropItems(items)
            return true
        case .cancelled:
            Logger.debug("Cursor-driven drop: launchable drag cancelled")
            return false
        }
    }

    @discardableResult
    internal func applyCursorDrivenLaunchTarget(
        _ target: DragDropCoordinator.CursorDrivenDropTarget,
        reason: String
    ) -> Bool {
        switch target {
        case .tilingZone(let zoneKey):
            targetedZoneManager.setTargetedZone(zoneKey, reason: reason)
            return true
        case .floatingZone(let screenId):
            targetedZoneManager.setFloatingTarget(on: screenId, reason: reason)
            return true
        case .addZone(let screenId):
            guard let newZone = addZone(on: screenId, announce: false, promoteFloatingOccupant: false) else {
                Logger.debug("Cursor-driven drop: cannot add zone on screen \(screenContextStore.loggingIndex(for: screenId))")
                return false
            }
            targetedZoneManager.setTargetedZone(ZoneKey(screenId: screenId, index: newZone.index), reason: reason)
            return true
        case .cancelled:
            return false
        }
    }

    private func placeManagedWindowItem(
        _ window: LauncherWindowItem,
        intoTilingZone zoneKey: ZoneKey,
        reason: String
    ) -> Bool {
        guard let managed = managedWindow(from: window) else {
            Logger.debug("Cursor-driven drop: cannot place window into tiling zone - window not managed")
            return false
        }

        guard let context = screenContexts[zoneKey.screenId],
              let descriptor = descriptor(for: zoneKey.screenId),
              let zone = context.zoneController.zone(at: zoneKey.index) else {
            Logger.debug("Cursor-driven drop: target tiling zone not found")
            return false
        }

        let displayFrame = frameWithMargin(for: zone, in: context.zoneController)
        if !managed.isPlacedInZone {
            prePositionMinimizedManagedWindowForExplicitDrop(managed, to: displayFrame, on: descriptor, reason: reason)
            suppressNextEvents(for: [managed.windowId], events: [.deminiaturized], reason: "\(reason)-unminimize")
            windowController.unminimizeWindow(managed)
        }

        placeWindowIntoZone(managed, zoneKey: zoneKey)
        return true
    }

    private func placeManagedWindowItem(
        _ window: LauncherWindowItem,
        intoFloatingZone screenId: CGDirectDisplayID,
        reason: String
    ) -> Bool {
        guard let managed = managedWindow(from: window) else {
            Logger.debug("Cursor-driven drop: cannot place window into floating zone - window not managed")
            return false
        }

        if !managed.isPlacedInZone {
            suppressNextEvents(for: [managed.windowId], events: [.deminiaturized], reason: "\(reason)-unminimize")
            windowController.unminimizeWindow(managed)
        }

        removeWindowFromAllZones(windowId: managed.windowId, reason: reason, retarget: false)
        assignWindowToFloatingZone(managed, on: screenId, centerWindow: true, reason: reason)
        syncWindowsToZones(recentlyPlacedInFloatingZone: managed.windowId)
        refreshIndicators()
        return true
    }

    private func managedWindow(from window: LauncherWindowItem) -> ManagedWindow? {
        guard let managedWindowId = window.managedWindowId else {
            return nil
        }
        return windowController.window(withId: managedWindowId)
    }

    private func zoneOccupantWindowId(for key: ZoneKey) -> Int? {
        guard let context = screenContexts[key.screenId],
              let zone = context.zoneController.zone(at: key.index) else {
            return nil
        }
        return zone.occupantWindowId
    }

    private func prePositionMinimizedManagedWindowForExplicitDrop(
        _ managed: ManagedWindow,
        to screenFrame: CGRect,
        on screen: ScreenDescriptor,
        reason: String
    ) {
        let effectiveScreenFrame = windowController.resolvedTargetScreenFrame(
            for: managed,
            requestedFrame: screenFrame,
            on: screen
        )
        let element = managed.backing.element
        let accessibilityFrame = screen.screenToAccessibility(effectiveScreenFrame)

        var position = accessibilityFrame.origin
        if let positionValue = AXValueCreate(.cgPoint, &position) {
            AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, positionValue)
        }

        var size = accessibilityFrame.size
        if let sizeValue = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue)
        }

        Logger.debug("Cursor-driven drop: pre-positioned minimized window \(managed.windowId) to \(effectiveScreenFrame) before unminimizing (reason: \(reason))")
    }
}
