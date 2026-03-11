import AppKit

/// Bridges Control-Command external drags over tiling windows and placeholders into zone placeholder behavior.
extension AppController {
    var isManagedWindowDragInProgress: Bool {
        dragDropCoordinator.isDragging || floatingDragHandler.isActive
    }

    func shouldBeginExternalZoneDropInterception(cursorPoint: CGPoint) -> Bool {
        if let (managed, _) = tiledManagedWindowUnderCursor(cursorPoint: cursorPoint),
           managed.zoneIndex != nil,
           !managed.isInFloatingZone,
           let screenId = managed.screenDisplayId ?? detectScreenId(for: managed) {
            return !isScreenPausedForFullScreen(screenId)
        }

        guard let emptyZoneKey = resolveEmptyTilingZoneUnderCursor(cursorPoint: cursorPoint),
              placeholderCoordinator.hasPlaceholder(for: emptyZoneKey),
              PlaceholderExternalDragPolicy.shouldPromotePlaceholderToInterceptedOverlay(
                isControlCommandHeld: NSEvent.modifierFlags.contains(.command) && NSEvent.modifierFlags.contains(.control),
                hasObservedRealPlaceholderExternalDrag: hasObservedRealPlaceholderExternalDragThisGesture
              ) else {
            return false
        }

        return !isScreenPausedForFullScreen(emptyZoneKey.screenId)
    }

    func resolveInterceptedExternalDropZoneKey(cursorPoint: CGPoint) -> ZoneKey? {
        guard let screenId = resolveCursorScreenId(),
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
                return ZoneKey(screenId: screenId, index: zone.index)
            }
        }

        return nil
    }

    func externalDropOverlayDescriptors() -> [ZoneOverlayDescriptor] {
        var descriptors: [ZoneOverlayDescriptor] = []

        for (screenId, context) in screenContexts {
            if isScreenPausedForFullScreen(screenId) {
                continue
            }

            let descriptor = context.descriptor
            for zone in context.zoneController.allZones {
                descriptors.append(
                    ZoneOverlayDescriptor(
                        key: ZoneKey(screenId: screenId, index: zone.index),
                        cocoaFrame: descriptor.screenToCocoa(zone.frame),
                        isEmpty: zone.isEmpty
                    )
                )
            }
        }

        return descriptors
    }
}

extension AppController {
    func dragOverlayManager(_ manager: DragOverlayManager, shouldAcceptExternalDropFor key: ZoneKey) -> Bool {
        guard NSEvent.modifierFlags.contains(.command),
              NSEvent.modifierFlags.contains(.control),
              !isManagedWindowDragInProgress,
              ExternalDropParser.canAccept(NSPasteboard(name: .drag)),
              let cursorPoint = currentCursorAccessibilityPoint(),
              resolveInterceptedExternalDropZoneKey(cursorPoint: cursorPoint) == key else {
            return false
        }

        return true
    }

    func dragOverlayManager(_ manager: DragOverlayManager, didReceiveExternalDrop items: [ExternalDropItem], for key: ZoneKey) {
        let screenIndex = screenContextStore.loggingIndex(for: key.screenId)
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
