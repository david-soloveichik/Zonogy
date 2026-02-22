import Foundation
import AppKit
import ApplicationServices

/// Zone indicator refresh: visual UI for zone targeting, add-zone, temporary zone, and resize handles.
extension AppController {

    private func zoneIndicatorDescriptors(forScreens screenIds: Set<CGDirectDisplayID>? = nil) -> [ZoneIndicatorDescriptor] {
        var descriptors: [ZoneIndicatorDescriptor] = []

        for (screenId, context) in screenContexts {
            if let screenIds, !screenIds.contains(screenId) {
                continue
            }
            guard !isScreenPausedForFullScreen(screenId) else {
                continue
            }
            let screenDescriptor = context.descriptor
            for zone in context.zoneController.allZones {
                let key = ZoneKey(screenId: screenId, index: zone.index)
                let frame = indicatorFrame(for: zone, controller: context.zoneController, descriptor: screenDescriptor)
                guard frame.width > 0, frame.height > 0 else {
                    continue
                }
                descriptors.append(
                    ZoneIndicatorDescriptor(
                        key: key,
                        cocoaFrame: frame,
                        isTargeted: key == targetedZoneKey
                    )
                )
            }
        }

        return descriptors
    }

    internal func refreshZoneIndicators(forScreens screenIds: Set<CGDirectDisplayID>? = nil) {
        let descriptors = zoneIndicatorDescriptors(forScreens: screenIds)

        if let screenIds {
            indicatorManager.present(over: descriptors, forScreens: screenIds)
        } else if descriptors.isEmpty {
            indicatorManager.tearDown()
        } else {
            indicatorManager.present(over: descriptors)
        }
    }

    private func indicatorFrame(for zone: Zone, controller: ZoneController, descriptor: ScreenDescriptor) -> CGRect {
        let screenBounds = descriptor.visibleScreenBounds.standardized
        let contentFrame = frameWithMargin(for: zone, in: controller).standardized
        let indicatorHeight: CGFloat = 6
        let minWidth: CGFloat = 40
        let targetWidth = max(minWidth, (contentFrame.width / 3).rounded())
        let clampedWidth = min(targetWidth, contentFrame.width)

        var originX = (contentFrame.midX - clampedWidth / 2).rounded()
        originX = max(screenBounds.minX, min(originX, screenBounds.maxX - clampedWidth))

        let offset: CGFloat = 2
        let fallbackBottom = contentFrame.minY - offset
        var originY = fallbackBottom - indicatorHeight
        var usedGapPlacement = false

        if zone.index > 1, let previousZone = controller.zone(at: zone.index - 1) {
            let previousContentFrame = frameWithMargin(for: previousZone, in: controller).standardized
            let gapTop = previousContentFrame.maxY
            let gapBottom = contentFrame.minY

            if gapBottom > gapTop {
                let midpoint = ((gapTop + gapBottom) / 2).rounded()
                originY = (midpoint - indicatorHeight / 2).rounded()
                usedGapPlacement = true
            }
        }

        if originY < screenBounds.minY {
            originY = screenBounds.minY
        }
        if originY + indicatorHeight > screenBounds.maxY {
            originY = screenBounds.maxY - indicatorHeight
        }

        if !usedGapPlacement {
            let maxIndicatorBottom = fallbackBottom
            if originY + indicatorHeight > maxIndicatorBottom {
                originY = max(screenBounds.minY, maxIndicatorBottom - indicatorHeight)
            }
        }

        let indicatorFrame = CGRect(x: originX, y: originY, width: clampedWidth, height: indicatorHeight)
        return descriptor.screenToCocoa(indicatorFrame).standardized
    }

    internal func refreshIndicators() {
        refreshZoneIndicators()

        // Refresh add-zone indicators
        var addZoneDescriptors: [AddZoneIndicatorDescriptor] = []
        var newAddZoneHitAreas: [CGDirectDisplayID: CGRect] = [:]

        for (screenId, context) in screenContexts {
            guard !isScreenPausedForFullScreen(screenId) else {
                continue
            }
            let zoneCount = context.zoneController.allZones.count
            // Only show the indicator if there are fewer than 3 zones
            guard zoneCount < 3 else { continue }

            let screenDescriptor = context.descriptor
            guard let frames = addZoneIndicatorFrames(for: screenDescriptor) else {
                continue
            }
            let descriptor = AddZoneIndicatorDescriptor(
                screenId: screenId,
                frame: frames.cocoa
            )
            addZoneDescriptors.append(descriptor)
            newAddZoneHitAreas[screenId] = frames.accessibility
        }

        addIndicatorTracker.updateHitAreas(newAddZoneHitAreas)

        if addZoneDescriptors.isEmpty {
            addZoneIndicatorManager.updateDragHighlight(screenId: nil)
            addZoneIndicatorManager.tearDown()
        } else {
            addZoneIndicatorManager.present(for: addZoneDescriptors)
        }

        var temporaryDescriptors: [TemporaryZoneIndicatorDescriptor] = []
        var newTemporaryHitAreas: [CGDirectDisplayID: CGRect] = [:]
        for (screenId, context) in screenContexts {
            guard !isScreenPausedForFullScreen(screenId) else {
                continue
            }
            guard let frames = temporaryIndicatorFrames(for: context.descriptor) else {
                continue
            }
            let descriptor = TemporaryZoneIndicatorDescriptor(
                screenId: screenId,
                cocoaFrame: frames.cocoa,
                isTargeted: targetedTemporaryScreenId == screenId,
                isOccupied: temporaryZoneOccupant(on: screenId) != nil,
                isDragHighlighted: temporaryIndicatorTracker.highlightedScreenId == screenId
            )
            temporaryDescriptors.append(descriptor)
            newTemporaryHitAreas[screenId] = frames.accessibility
        }

        temporaryIndicatorTracker.updateHitAreas(newTemporaryHitAreas)

        if temporaryDescriptors.isEmpty {
            temporaryIndicatorTracker.setHighlightedScreen(nil)
            temporaryIndicatorManager.tearDown()
        } else {
            temporaryIndicatorManager.present(over: temporaryDescriptors)
        }
    }

    private func addZoneIndicatorFrames(for descriptor: ScreenDescriptor) -> (cocoa: CGRect, accessibility: CGRect)? {
        let bounds = descriptor.cocoaBounds.standardized
        guard bounds.width > 0, bounds.height > 0 else {
            return nil
        }

        // Width: match the default pill thickness used by edge indicators.
        let indicatorWidth: CGFloat = EdgeIndicatorPillSizing.baseThickness

        // Height: 1/3 of screen height
        let indicatorHeight = (bounds.height / 3).rounded()

        // Position on the right edge, vertically centered
        let originX = bounds.maxX - indicatorWidth
        let originY = (bounds.midY - indicatorHeight / 2).rounded()

        let cocoaFrame = CGRect(x: originX, y: originY, width: indicatorWidth, height: indicatorHeight).standardized
        let screenFrame = descriptor.cocoaToScreen(cocoaFrame).standardized
        let accessibilityFrame = descriptor.screenToAccessibility(screenFrame).standardized
        return (cocoa: cocoaFrame, accessibility: accessibilityFrame)
    }

    private func temporaryIndicatorFrames(for descriptor: ScreenDescriptor) -> (cocoa: CGRect, accessibility: CGRect)? {
        let bounds = descriptor.visibleScreenBounds.standardized
        guard bounds.width > 0, bounds.height > 0 else {
            return nil
        }

        let width = min(max((bounds.width / 3).rounded(), 80), bounds.width)
        let height: CGFloat = EdgeIndicatorPillSizing.baseThickness
        var originX = (bounds.midX - width / 2).rounded()
        originX = max(bounds.minX, min(originX, bounds.maxX - width))
        let originY = bounds.maxY - height
        let screenFrame = CGRect(x: originX, y: originY, width: width, height: height).standardized
        let cocoaFrame = descriptor.screenToCocoa(screenFrame).standardized
        let accessibilityFrame = descriptor.screenToAccessibility(screenFrame).standardized
        return (cocoa: cocoaFrame, accessibility: accessibilityFrame)
    }

    func addZoneIndicatorHitAreas() -> [CGDirectDisplayID: CGRect] {
        addIndicatorTracker.hitAreas
    }

    func updateAddZoneIndicatorHighlight(screenId: CGDirectDisplayID?) {
        if addIndicatorTracker.setHighlightedScreen(screenId) {
            addZoneIndicatorManager.updateDragHighlight(screenId: screenId)
        }
    }

    func temporaryIndicatorHitAreas() -> [CGDirectDisplayID: CGRect] {
        temporaryIndicatorTracker.hitAreas
    }

    func updateTemporaryIndicatorHighlight(screenId: CGDirectDisplayID?) {
        if temporaryIndicatorTracker.setHighlightedScreen(screenId) {
            temporaryIndicatorManager.updateDragHighlight(screenId: screenId)
        }
    }

    // MARK: - Resize Handles

    private struct FrontmostManagedWindowContext {
        let zoneKey: ZoneKey
        let frame: CGRect
    }

    private func frontmostManagedWindowContext(windowIdOverride: Int? = nil) -> FrontmostManagedWindowContext? {
        let windowId = windowIdOverride ?? currentFrontmostManagedWindowId
        guard !zoneResizeDragInProgress,
              let windowId,
              let managed = windowController.window(withId: windowId),
              let zoneKey = zoneKey(forManagedWindow: managed),
              let descriptor = descriptor(for: zoneKey.screenId) else {
            return nil
        }

        let frame = windowController.actualFrameInScreenCoordinates(for: managed, on: descriptor).standardized
        return FrontmostManagedWindowContext(zoneKey: zoneKey, frame: frame)
    }

    internal func refreshResizeHandles() {
        refreshResizeHandles(frontmostWindowIdOverride: nil)
    }

    internal func refreshResizeHandles(frontmostWindowIdOverride: Int?) {
        var descriptors: [ZoneSeparatorDescriptor] = []
        let activeState = activeFitState
        let frontmostManagedWindow = frontmostManagedWindowContext(windowIdOverride: frontmostWindowIdOverride)
        let windowOverlapAllowance: CGFloat = zoneMargin

        for (screenId, context) in screenContexts {
            if isScreenPausedForFullScreen(screenId) {
                continue
            }
            // When a screen's temporary zone holds a floating window,
            // hide all resize handles on that screen so they don't
            // overlap the temporary-zone UI.
            if temporaryZoneOccupant(on: screenId) != nil {
                continue
            }

            // When an unmanaged window has focus on this screen,
            // hide all resize handles on that screen to avoid overlapping it.
            if unmanagedFocusedWindowScreenId == screenId {
                continue
            }

            let frontmostManagedWindowOnScreen = frontmostManagedWindow?.zoneKey.screenId == screenId ? frontmostManagedWindow : nil
            let activeFitContext: ZoneResizeHandleAvoidanceContext? = {
                guard let state = activeState,
                      state.zoneKey.screenId == screenId else {
                    return nil
                }
                let avoidFrame = ZoneResizeHandleGeometry.insetAvoidanceFrame(
                    state.revealFrame,
                    by: windowOverlapAllowance
                )
                return ZoneResizeHandleAvoidanceContext(zoneIndex: state.zoneKey.index, avoidFrame: avoidFrame)
            }()

            let frontmostManagedContext: ZoneResizeHandleAvoidanceContext? = {
                guard let frontmostManagedWindowOnScreen else {
                    return nil
                }
                let avoidFrame = ZoneResizeHandleGeometry.insetAvoidanceFrame(
                    frontmostManagedWindowOnScreen.frame,
                    by: windowOverlapAllowance
                )
                return ZoneResizeHandleAvoidanceContext(
                    zoneIndex: frontmostManagedWindowOnScreen.zoneKey.index,
                    avoidFrame: avoidFrame
                )
            }()

            let separators = context.zoneController.separators()

            for sep in separators {
                guard let frame = ZoneResizeHandleVisibilityPolicy.adjustedSeparatorFrame(
                    sep,
                    activeFitContext: activeFitContext,
                    frontmostManagedContext: frontmostManagedContext
                ) else {
                    continue
                }

                descriptors.append(ZoneSeparatorDescriptor(
                    screenId: screenId,
                    index: sep.index,
                    orientation: sep.orientation,
                    frame: frame,
                    screenCocoaBounds: context.descriptor.cocoaBounds
                ))
            }
        }

        resizeHandleManager.present(over: descriptors)
    }
}
