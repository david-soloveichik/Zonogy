import AppKit

/// Bridges gesture-modifier external drags over tiling windows, placeholders, and floating windows
/// into zone drop behavior, and passes Shift external drags through the placeholders.
extension AppController {
    var isManagedWindowDragInProgress: Bool {
        dragDropCoordinator.isDragging || floatingDragHandler.isActive
    }

    func setPlaceholderExternalDragPassThrough(_ enabled: Bool) {
        placeholderCoordinator.setExternalDragPassThrough(enabled)
    }

    func shouldBeginExternalZoneDropInterception(cursorPoint: CGPoint) -> Bool {
        guard resolveAddZoneDropTarget(cursorPoint: cursorPoint) == nil,
              resolveFloatingDropTarget(cursorPoint: cursorPoint) == nil else {
            return false
        }

        // A floating window takes precedence over the tiled windows beneath it.
        if floatingWindowDropScreenId(containing: cursorPoint) != nil {
            return true
        }

        if let (managed, _) = tiledManagedWindowUnderCursor(cursorPoint: cursorPoint),
           managed.zoneIndex != nil,
           !managed.isInFloatingZone,
           let screenId = managed.screenDisplayId ?? detectScreenId(for: managed) {
            return !isScreenPausedForFullScreen(screenId)
        }

        guard let emptyZoneKey = resolveEmptyTilingZoneUnderCursor(cursorPoint: cursorPoint),
              placeholderCoordinator.hasPlaceholder(for: emptyZoneKey),
              PlaceholderExternalDragPolicy.shouldPromotePlaceholderToInterceptedOverlay(
                gestureModifiersHeld: shouldApplyGestureModifierExternalDrag(),
                hasObservedRealPlaceholderExternalDrag: hasObservedRealPlaceholderExternalDragThisGesture
              ) else {
            return false
        }

        return !isScreenPausedForFullScreen(emptyZoneKey.screenId)
    }

    func resolveInterceptedExternalDropDestination(cursorPoint: CGPoint) -> TargetedZoneManager.TargetedDestination? {
        guard resolveAddZoneDropTarget(cursorPoint: cursorPoint) == nil,
              resolveFloatingDropTarget(cursorPoint: cursorPoint) == nil else {
            return nil
        }

        // A floating window takes precedence over the tiling zone beneath it.
        if let screenId = floatingWindowDropScreenId(containing: cursorPoint) {
            return .floating(screenId: screenId)
        }

        guard let screenId = screenId(containingAccessibilityPoint: cursorPoint),
              !isScreenPausedForFullScreen(screenId),
              let context = screenContexts[screenId] else {
            return nil
        }

        // Once interception has started, mirror tiled-window drags: any visible tiling
        // zone under the cursor on the cursor's current screen is a valid drop target.
        let descriptor = context.descriptor
        for zone in context.zoneController.allZones {
            let accessibilityFrame = descriptor.screenToAccessibility(zone.frame)
            if accessibilityFrame.contains(cursorPoint) {
                return .tiled(ZoneKey(screenId: screenId, index: zone.index))
            }
        }

        return nil
    }

    /// The tiling zones' overlays for an external drag over them.
    func externalDropOverlayDescriptors() -> [ZoneOverlayDescriptor] {
        var descriptors: [ZoneOverlayDescriptor] = []

        for (screenId, context) in screenContexts {
            if isScreenPausedForFullScreen(screenId) {
                continue
            }

            let descriptor = context.descriptor
            for zone in context.zoneController.allZones {
                let overlayFrame = zone.isEmpty
                    ? frameWithMargin(for: zone, in: context.zoneController)
                    : zone.frame
                descriptors.append(
                    ZoneOverlayDescriptor(
                        key: .tiled(ZoneKey(screenId: screenId, index: zone.index)),
                        cocoaFrame: descriptor.screenToCocoa(overlayFrame),
                        isEmpty: zone.isEmpty
                    )
                )
            }
        }

        return descriptors
    }

    /// The overlays for an intercepted gesture-modifier external drag: the tiling zones', then the
    /// floating windows' (drawn above), since the modifiers make floating windows destinations too.
    func interceptedExternalDropOverlayDescriptors() -> [ZoneOverlayDescriptor] {
        externalDropOverlayDescriptors() + floatingWindowDropAreas().sorted { $0.key < $1.key }.map {
            ZoneOverlayDescriptor.floatingWindow(
                on: $0.key,
                accessibilityFrame: $0.value,
                primaryScreenBounds: primaryScreenBounds
            )
        }
    }

    /// The display whose floating window contains `cursorPoint`.
    func floatingWindowDropScreenId(containing cursorPoint: CGPoint) -> CGDirectDisplayID? {
        floatingWindowDropAreas().first(where: { $0.value.contains(cursorPoint) })?.key
    }
}

extension AppController {
    func dragOverlayManager(
        _ manager: DragOverlayManager,
        shouldAcceptExternalDropFor key: TargetedZoneManager.TargetedDestination
    ) -> Bool {
        guard shouldApplyGestureModifierExternalDrag(),
              !isManagedWindowDragInProgress,
              ExternalDropParser.canAccept(NSPasteboard(name: .drag)),
              let cursorPoint = currentCursorAccessibilityPoint(),
              resolveInterceptedExternalDropDestination(cursorPoint: cursorPoint) == key else {
            return false
        }

        return true
    }

    func dragOverlayManager(
        _ manager: DragOverlayManager,
        didReceiveExternalDrop items: [ExternalDropItem],
        for key: TargetedZoneManager.TargetedDestination
    ) {
        let screenIndex = screenContextStore.loggingIndex(for: key.screenId)
        switch key {
        case .floating(let screenId):
            // The floating window stays until the opened item's window replaces it, taking over
            // its frame.
            Logger.debug("External drop accepted for the floating window on screen \(screenIndex) with \(items.count) item(s)")
            openExternalDropItems(items, inFloatingZoneOn: screenId, reason: "floating-window-drop")
        case .tiled(let key):
            Logger.debug(
                "External zone drop accepted for zone \(key.index) on screen \(screenIndex) with \(items.count) item(s)"
            )
            if let context = screenContexts[key.screenId],
               let zone = context.zoneController.zone(at: key.index),
               zone.isEmpty {
                placeholderReceivedExternalDrop(screenId: key.screenId, zoneIndex: key.index, items: items)
            } else {
                occupiedZoneReceivedExternalDrop(screenId: key.screenId, zoneIndex: key.index, items: items)
            }
        }
    }
}
