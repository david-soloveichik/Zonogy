import Foundation
import AppKit
import ApplicationServices

/// Zone indicator refresh: visual UI for zone targeting, add-zone, temporary zone, and resize handles.
extension AppController {

    private func indicatorFrame(for zone: Zone, controller: ZoneController, descriptor: ScreenDescriptor) -> CGRect {
        let screenBounds = descriptor.visibleScreenBounds.standardized
        let contentFrame = frameWithMargin(for: zone, in: controller).standardized
        let indicatorHeight: CGFloat = 6
        let minWidth: CGFloat = 40
        let targetWidth = max(minWidth, contentFrame.width / 3)
        let clampedWidth = min(targetWidth, contentFrame.width)

        var originX = contentFrame.midX - clampedWidth / 2
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
                let midpoint = (gapTop + gapBottom) / 2
                originY = midpoint - indicatorHeight / 2
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
        // Refresh zone indicators
        var descriptors: [ZoneIndicatorDescriptor] = []

        for (screenId, context) in screenContexts {
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
                let descriptor = ZoneIndicatorDescriptor(
                    key: key,
                    cocoaFrame: frame,
                    isTargeted: key == targetedZoneKey
                )
                descriptors.append(descriptor)
            }
        }

        if descriptors.isEmpty {
            indicatorManager.tearDown()
        } else {
            indicatorManager.present(over: descriptors)
        }

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
        let indicatorHeight = bounds.height / 3

        // Position on the right edge, vertically centered
        let originX = bounds.maxX - indicatorWidth
        let originY = bounds.midY - indicatorHeight / 2

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

        let width = min(max(bounds.width / 3, 80), bounds.width)
        let height: CGFloat = EdgeIndicatorPillSizing.baseThickness
        var originX = bounds.midX - width / 2
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

    internal func refreshResizeHandles() {
        var descriptors: [ZoneSeparatorDescriptor] = []
        let activeState = activeFitState
        let shouldIgnoreActiveFitOverlap: Bool = {
            guard let placeholderClickTimestamp = lastPlaceholderClickTimestamp else {
                return false
            }
            let lastMouseDownTimestamp = ProcessInfo.processInfo.systemUptime - MouseButtons.secondsSinceLastLeftMouseDown()
            return abs(lastMouseDownTimestamp - placeholderClickTimestamp) <= 0.05
        }()

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

            let separators = context.zoneController.separators()

            for sep in separators {
                var frame = sep.frame

                if !shouldIgnoreActiveFitOverlap,
                   let state = activeState,
                   state.zoneKey.screenId == screenId {
                    let activeFrame = state.revealFrame.standardized

                    switch sep.orientation {
                    case .vertical:
                        // Separator between zone 1 and zones 2/3 (index 0) should
                        // not extend into the ActiveFit reveal frame.
                        if sep.index == 0 {
                            let originalFrame = frame.standardized
                            let intersection = originalFrame.intersection(activeFrame).standardized
                            if !intersection.isNull, intersection.height > 0 {
                                let topGap = max(0, intersection.minY - originalFrame.minY)
                                let bottomGap = max(0, originalFrame.maxY - intersection.maxY)
                                let maxGap = max(topGap, bottomGap)

                                // If the ActiveFit window fully covers the separator,
                                // hide this handle entirely.
                                guard maxGap > 0 else {
                                    continue
                                }

                                if topGap >= bottomGap {
                                    frame = CGRect(
                                        x: originalFrame.minX,
                                        y: originalFrame.minY,
                                        width: originalFrame.width,
                                        height: topGap
                                    )
                                } else {
                                    frame = CGRect(
                                        x: originalFrame.minX,
                                        y: intersection.maxY,
                                        width: originalFrame.width,
                                        height: bottomGap
                                    )
                                }
                            }
                        }

                    case .horizontal:
                        // Hide the separator between zones 2 and 3 (index 1) if it
                        // would overlap the ActiveFit reveal frame.
                        if sep.index == 1 {
                            if frame.intersects(activeFrame) {
                                continue
                            }
                        }
                    }
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
