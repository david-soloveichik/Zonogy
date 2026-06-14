import Foundation
import AppKit
import ApplicationServices

/// Zone indicator refresh: visual UI for zone targeting, add-zone, floating zone, and resize handles.
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
                // Only show the indicator for the targeted zone.
                guard key == targetedZoneKey else { continue }
                let frame = indicatorFrame(for: zone, controller: context.zoneController, descriptor: screenDescriptor)
                guard frame.width > 0, frame.height > 0 else {
                    continue
                }
                descriptors.append(
                    ZoneIndicatorDescriptor(
                        key: key,
                        cocoaFrame: frame,
                        isTargeted: true
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
        placeholderCoordinator.setTargetedZone(targetedZoneKey)

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

        var floatingDescriptors: [FloatingZoneIndicatorDescriptor] = []
        var newFloatingHitAreas: [CGDirectDisplayID: CGRect] = [:]
        for (screenId, context) in screenContexts {
            guard !isScreenPausedForFullScreen(screenId) else {
                continue
            }
            guard let frames = floatingIndicatorFrames(for: context.descriptor) else {
                continue
            }
            let descriptor = FloatingZoneIndicatorDescriptor(
                screenId: screenId,
                cocoaFrame: frames.cocoa,
                isTargeted: targetedFloatingScreenId == screenId,
                isOccupied: floatingZoneOccupant(on: screenId) != nil,
                isDragHighlighted: floatingIndicatorTracker.highlightedScreenId == screenId
            )
            floatingDescriptors.append(descriptor)
            newFloatingHitAreas[screenId] = frames.accessibility
        }

        floatingIndicatorTracker.updateHitAreas(newFloatingHitAreas)

        if floatingDescriptors.isEmpty {
            floatingIndicatorTracker.setHighlightedScreen(nil)
            floatingIndicatorManager.tearDown()
        } else {
            floatingIndicatorManager.present(over: floatingDescriptors)
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

    /// Canonical Cocoa and global (accessibility-coordinate) frames of a screen's floating-zone bar.
    internal func floatingIndicatorFrames(for descriptor: ScreenDescriptor) -> (cocoa: CGRect, accessibility: CGRect)? {
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

    func floatingIndicatorHitAreas() -> [CGDirectDisplayID: CGRect] {
        floatingIndicatorTracker.hitAreas
    }

    func updateFloatingIndicatorHighlight(screenId: CGDirectDisplayID?) {
        if floatingIndicatorTracker.setHighlightedScreen(screenId) {
            floatingIndicatorManager.updateDragHighlight(screenId: screenId)
        }
    }

    // MARK: - Resize Handles

    fileprivate struct FrontmostManagedWindowContext {
        let windowId: Int
        let zoneKey: ZoneKey
        let frame: CGRect
    }

    private func tiledManagedWindowContexts(
        context: ScreenContext,
        excluding excludedWindowIds: Set<Int>,
        windowOverlapAllowance: CGFloat
    ) -> [ZoneResizeHandleAvoidanceContext] {
        context.zoneController.allZones.compactMap { zone in
            guard let windowId = zone.occupantWindowId,
                  !excludedWindowIds.contains(windowId),
                  let managed = windowController.window(withId: windowId) else {
                return nil
            }
            let frame = windowController.actualFrameInScreenCoordinates(for: managed, on: context.descriptor)
            let avoidFrame = ZoneResizeHandleGeometry.insetAvoidanceFrame(
                frame,
                by: windowOverlapAllowance
            )
            return ZoneResizeHandleAvoidanceContext(zoneIndex: zone.index, avoidFrame: avoidFrame)
        }
    }

    private func adjacentPlaceholderFrames(
        for separator: ZoneLayout.Separator,
        on screenId: CGDirectDisplayID,
        context: ScreenContext
    ) -> [CGRect] {
        let zoneIndices: [Int]

        switch (context.zoneController.allZones.count, separator.orientation, separator.index) {
        case (2, .vertical, 0):
            zoneIndices = [1, 2]
        case (3, .vertical, 0):
            zoneIndices = [1, 2, 3]
        case (3, .horizontal, 1):
            zoneIndices = [2, 3]
        default:
            zoneIndices = []
        }

        return zoneIndices.compactMap { zoneIndex in
            let key = zoneKey(for: screenId, index: zoneIndex)
            guard placeholderCoordinator.hasPlaceholder(for: key),
                  let zone = context.zoneController.zone(at: zoneIndex) else {
                return nil
            }
            return frameWithMargin(for: zone, in: context.zoneController)
        }
    }

    private func pinnedResizeHandleContext(
        for separator: ZoneLayout.Separator,
        on screenId: CGDirectDisplayID,
        context: ScreenContext
    ) -> ZoneResizeHandlePinnedContext? {
        guard isResizeHandlePinnedModeActive(on: screenId) else {
            return nil
        }
        return ZoneResizeHandlePinnedContext(
            separator: separator,
            adjacentPlaceholderFrames: adjacentPlaceholderFrames(
                for: separator,
                on: screenId,
                context: context
            )
        )
    }

    /// Outcome of resolving the frontmost managed window for resize-bar avoidance.
    /// The `.none` case carries a short reason so the log can explain why no avoidance frame
    /// was applied (and hence why a bar may have remained visible).
    fileprivate enum FrontmostManagedWindowResolution {
        case resolved(FrontmostManagedWindowContext)
        case none(reason: String)
    }

    fileprivate func resolveFrontmostManagedWindow(windowIdOverride: Int? = nil) -> FrontmostManagedWindowResolution {
        if zoneResizeDragInProgress {
            return .none(reason: "zone-resize-drag-in-progress")
        }
        guard let windowId = windowIdOverride ?? currentFrontmostManagedWindowId else {
            return .none(reason: "no-frontmost-id")
        }
        guard let managed = windowController.window(withId: windowId) else {
            return .none(reason: "window-not-tracked:\(windowId)")
        }
        guard let zoneKey = zoneKey(forManagedWindow: managed) else {
            return .none(reason: "window-not-in-zone:\(windowId)")
        }
        guard let descriptor = descriptor(for: zoneKey.screenId) else {
            return .none(reason: "no-descriptor-for-screen:displayId=\(zoneKey.screenId)")
        }
        let frame = windowController.actualFrameInScreenCoordinates(for: managed, on: descriptor).standardized
        return .resolved(FrontmostManagedWindowContext(windowId: windowId, zoneKey: zoneKey, frame: frame))
    }

    internal func refreshResizeHandles() {
        refreshResizeHandles(frontmostWindowIdOverride: nil)
    }

    internal func refreshResizeHandles(frontmostWindowIdOverride: Int?) {
        prunePinnedResizeBarScreens(reason: "refresh")
        var descriptors: [ZoneSeparatorDescriptor] = []
        let activeState = activeFitState
        let frontmostResolution = resolveFrontmostManagedWindow(windowIdOverride: frontmostWindowIdOverride)
        let frontmostManagedWindow: FrontmostManagedWindowContext? = {
            if case let .resolved(context) = frontmostResolution { return context }
            return nil
        }()
        let frontmostNoneReason: String? = {
            if case let .none(reason) = frontmostResolution { return reason }
            return nil
        }()
        let windowOverlapAllowance: CGFloat = zoneMargin

        for (screenId, context) in screenContexts {
            let screenLabel = screenContextStore.logDescription(for: screenId)
            if isScreenPausedForFullScreen(screenId) {
                emitResizeHandleLogIfChanged(
                    screenId: screenId,
                    lines: ["ResizeBars refresh skipped on \(screenLabel): full-screen-paused"]
                )
                continue
            }
            // Unmanaged focus always suppresses resize bars on that screen to avoid overlapping
            // windows we do not control; pinned mode remains armed but does not override this.
            if unmanagedFocusedWindowScreenId == screenId {
                emitResizeHandleLogIfChanged(
                    screenId: screenId,
                    lines: ["ResizeBars refresh skipped on \(screenLabel): unmanaged-window-focused"]
                )
                continue
            }
            let pinnedModeActive = isResizeHandlePinnedModeActive(on: screenId)

            // When the floating zone is occupied, hide only the bars that
            // the floating window actually overlaps (not all bars on the screen).
            // During a resize drag the dragged bar stays visible.
            let floatingZoneContext: ZoneResizeHandleFloatingZoneContext? = {
                guard !zoneResizeDragInProgress,
                      let occupant = floatingZoneOccupant(on: screenId) else {
                    return nil
                }
                let frame = windowController.actualFrameInScreenCoordinates(for: occupant, on: context.descriptor)
                let avoidFrame = ZoneResizeHandleGeometry.insetAvoidanceFrame(
                    frame,
                    by: windowOverlapAllowance
                )
                return ZoneResizeHandleFloatingZoneContext(avoidFrame: avoidFrame)
            }()

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

            let managedContexts: [ZoneResizeHandleAvoidanceContext] = {
                if pinnedModeActive {
                    var excludedWindowIds: Set<Int> = []
                    if let activeState, activeState.zoneKey.screenId == screenId {
                        excludedWindowIds.insert(activeState.windowId)
                    }
                    return tiledManagedWindowContexts(
                        context: context,
                        excluding: excludedWindowIds,
                        windowOverlapAllowance: windowOverlapAllowance
                    )
                }

                guard let frontmostManagedWindowOnScreen else {
                    return []
                }
                let avoidFrame = ZoneResizeHandleGeometry.insetAvoidanceFrame(
                    frontmostManagedWindowOnScreen.frame,
                    by: windowOverlapAllowance
                )
                return [
                    ZoneResizeHandleAvoidanceContext(
                        zoneIndex: frontmostManagedWindowOnScreen.zoneKey.index,
                        avoidFrame: avoidFrame
                    )
                ]
            }()

            var logLines: [String] = [
                "ResizeBars refresh on \(screenLabel): " +
                "frontmost=\(formatFrontmostForLog(onScreenContext: frontmostManagedWindowOnScreen, global: frontmostManagedWindow, globalNoneReason: frontmostNoneReason, screenId: screenId)); " +
                "floating=\(formatAvoidFrameForLog(floatingZoneContext?.avoidFrame)); " +
                "activeFit=\(formatActiveFitForLog(activeFitContext)); " +
                "pinned=\(pinnedModeActive ? "yes" : "no"); " +
                "managedAvoid=\(formatManagedContextsForLog(managedContexts))"
            ]

            let separators = context.zoneController.separators()

            for sep in separators {
                let pinnedContext = pinnedResizeHandleContext(
                    for: sep,
                    on: screenId,
                    context: context
                )
                let orientationLabel = sep.orientation == .vertical ? "v" : "h"
                let originalFrame = sep.frame
                guard let frame = ZoneResizeHandleVisibilityPolicy.adjustedSeparatorFrame(
                    sep,
                    activeFitContext: activeFitContext,
                    managedContexts: managedContexts,
                    floatingZoneContext: floatingZoneContext,
                    pinnedContext: pinnedContext
                ) else {
                    logLines.append(
                        "  separator \(orientationLabel)#\(sep.index) @\(formatRectForLog(originalFrame)) -> hidden"
                    )
                    continue
                }

                let outcome: String
                if frame.equalTo(originalFrame.standardized) {
                    outcome = "kept"
                } else {
                    outcome = "clipped to \(formatRectForLog(frame))"
                }
                logLines.append(
                    "  separator \(orientationLabel)#\(sep.index) @\(formatRectForLog(originalFrame)) -> \(outcome)"
                )

                descriptors.append(ZoneSeparatorDescriptor(
                    screenId: screenId,
                    index: sep.index,
                    orientation: sep.orientation,
                    frame: frame,
                    screenCocoaBounds: context.descriptor.cocoaBounds
                ))
            }

            emitResizeHandleLogIfChanged(screenId: screenId, lines: logLines)
        }

        resizeHandleManager.present(over: descriptors)
    }

    // MARK: - Resize-handle log formatters

    /// Logs the supplied lines only when the per-screen fingerprint changed since the previous refresh.
    /// Refreshes that produce identical inputs and per-separator outcomes are suppressed so the
    /// log stays readable during sync/focus bursts.
    fileprivate func emitResizeHandleLogIfChanged(screenId: CGDirectDisplayID, lines: [String]) {
        let fingerprint = lines.joined(separator: "\n")
        if lastLoggedResizeHandleFingerprint[screenId] == fingerprint {
            return
        }
        lastLoggedResizeHandleFingerprint[screenId] = fingerprint
        for line in lines {
            Logger.debug(line)
        }
    }

    fileprivate func formatRectForLog(_ rect: CGRect) -> String {
        String(format: "(%.0f,%.0f,%.0f,%.0f)", rect.minX, rect.minY, rect.width, rect.height)
    }

    fileprivate func formatAvoidFrameForLog(_ rect: CGRect?) -> String {
        guard let rect else { return "none" }
        return formatRectForLog(rect)
    }

    fileprivate func formatActiveFitForLog(_ context: ZoneResizeHandleAvoidanceContext?) -> String {
        guard let context else { return "none" }
        return "zone \(context.zoneIndex) @\(formatRectForLog(context.avoidFrame))"
    }

    fileprivate func formatManagedContextsForLog(_ contexts: [ZoneResizeHandleAvoidanceContext]) -> String {
        guard !contexts.isEmpty else { return "none" }
        let pieces = contexts.map { "zone \($0.zoneIndex) @\(formatRectForLog($0.avoidFrame))" }
        return "[\(pieces.joined(separator: ", "))]"
    }

    /// Formats the frontmost-managed-window status for the per-screen header log.
    /// Reports either the on-screen frontmost frame, or — if the globally resolved frontmost is on a
    /// different screen / unresolved — the reason so we can tell why no managed avoid frame applies here.
    fileprivate func formatFrontmostForLog(
        onScreenContext: FrontmostManagedWindowContext?,
        global: FrontmostManagedWindowContext?,
        globalNoneReason: String?,
        screenId: CGDirectDisplayID
    ) -> String {
        if let onScreenContext {
            return "window \(onScreenContext.windowId) @\(formatRectForLog(onScreenContext.frame))"
        }
        if let global {
            let otherLabel = screenContextStore.logDescription(for: global.zoneKey.screenId)
            return "off-screen(window \(global.windowId) on \(otherLabel))"
        }
        return "none(\(globalNoneReason ?? "unknown"))"
    }
}
