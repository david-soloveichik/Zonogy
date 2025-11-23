import Foundation
import AppKit
import ApplicationServices

/// Zone lifecycle operations: zone/window commands, placement, sync, and indicator refresh.
extension AppController {
    func addZone() {
        let screenId = activeScreenId()
        _ = addZone(on: screenId)
    }

    @discardableResult
    internal func addZone(on screenId: CGDirectDisplayID, announce: Bool = true) -> Zone? {
        guard let context = screenContexts[screenId],
              let newZone = context.zoneController.addZone() else {
            if announce {
                print("Failed to add zone (max 3 zones)")
            }
            return nil
        }
        syncWindowsToZones()
        activeFitRefreshAfterZoneTopologyChange(reason: "zone-added")
        let newZoneKey = zoneKey(for: screenId, index: newZone.index)
        if shouldRetarget(to: newZoneKey) {
            targetedZoneManager.setTargetedZone(newZoneKey, reason: "zone-added")
        } else {
            targetedZoneManager.ensureTargetedZone(reason: "zone-added")
        }
        if announce {
            print("Added zone \(newZone.index) on \(context.descriptor.localizedName)")
        }
        return newZone
    }

    func removeZone(at index: Int) {
        let screenId = activeScreenId()
        guard let context = screenContexts[screenId] else {
            print("Active screen not available")
            return
        }

        guard performRemoveZone(at: index, on: screenId, announce: true, context: context) != nil else {
            print("Failed to remove zone \(index)")
            return
        }
    }

    internal func performRemoveZone(
        at index: Int,
        on screenId: CGDirectDisplayID,
        announce: Bool,
        context: ScreenContext? = nil
    ) -> ZoneController.RemovalResult? {
        let context = context ?? screenContexts[screenId]
        guard let context else {
            return nil
        }

        guard let removalResult = context.zoneController.removeZone(at: index) else {
            return nil
        }

        // Clear placeholder mappings for this screen since zones are being reindexed
        // This prevents stale mappings from causing duplicate placeholders
        placeholderCoordinator.clearMappingsForScreen(screenId)

        let currentTarget = targetedZoneKey
        var pendingTargetedKey: ZoneKey?
        var shouldTargetTemporary = false
        if let currentTarget, currentTarget.screenId == screenId {
            if currentTarget.index == index {
                // The targeted zone is being removed, find a fallback on the same screen
                pendingTargetedKey = targetedZoneManager.fallbackTargetedZoneOnSameScreen(screenId: screenId)
                if pendingTargetedKey == nil {
                    // No empty zones on same screen, will target temporary zone
                    shouldTargetTemporary = true
                }
            } else if currentTarget.index > index {
                pendingTargetedKey = ZoneKey(screenId: screenId, index: currentTarget.index - 1)
            }
        }

        if let pendingTargetedKey {
            targetedZoneManager.setTargetedZone(pendingTargetedKey, reason: "zone-removed")
        } else if shouldTargetTemporary {
            targetedZoneManager.setTemporaryTarget(on: screenId, reason: "zone-removed-no-empty-same-screen")
        }

        if let removedWindowId = removalResult.removedWindowId,
           let managed = windowController.window(withId: removedWindowId) {
            windowPlacementManager.handleWindowAfterZoneRemoval(managed, preferredScreenId: screenId)
        }

        syncWindowsToZones()
        activeFitRefreshAfterZoneTopologyChange(reason: "zone-removed")

        if pendingTargetedKey == nil && !shouldTargetTemporary {
            targetedZoneManager.ensureTargetedZone(reason: "zone-removed")
        }

        if announce {
            print("Removed zone \(index) on \(context.descriptor.localizedName)")
        }
        return removalResult
    }

    func resizeZone(at index: Int, frame: CGRect) {
        let screenId = activeScreenId()
        guard let context = screenContexts[screenId] else {
            print("Active screen not available")
            return
        }

        guard let zone = context.zoneController.zone(at: index) else {
            print("Zone \(index) not found on \(context.descriptor.localizedName)")
            return
        }

        guard zone.isEmpty else {
            print("Zone \(index) is occupied; minimize or close its window before resizing.")
            return
        }

        if context.zoneController.resizeZone(at: index, to: frame) {
            syncWindowsToZones()
            if let updatedZone = context.zoneController.zone(at: index) {
                print("Resized zone \(index) on \(context.descriptor.localizedName) to \(updatedZone.frame)")
            } else {
                print("Zone \(index) resized")
            }
        } else {
            print("Failed to resize zone \(index)")
        }
    }

    // MARK: - Window Management

    func closeWindow(withId windowId: Int) {
        guard let managed = windowController.window(withId: windowId) else {
            print("Window \(windowId) not found")
            return
        }

        // Remove from zone
        removeWindowFromAllZones(windowId: windowId, reason: "close-command")

        // Close the window
        windowController.closeWindow(managed)

        // Sync to create placeholder if needed
        syncWindowsToZones()

        print("Closed window \(windowId)")
    }

    func minimizeWindow(withId windowId: Int) {
        guard let managed = windowController.window(withId: windowId) else {
            print("Window \(windowId) not found")
            return
        }

        minimizeWindowProgrammatically(managed, reason: "minimize-command")

        // Remove from zone and sync (delegate may not fire in CLI environment)
        removeWindowFromAllZones(windowId: windowId, reason: "minimize-command")
        syncWindowsToZones()

        print("Minimized window \(windowId)")
    }

    func unminimizeWindow(withId windowId: Int) {
        guard let managed = windowController.window(withId: windowId) else {
            print("Window \(windowId) not found")
            return
        }

        windowController.unminimizeWindow(managed)

        // Place the window using normal placement logic
        windowPlacementManager.placeNewWindow(managed)

        print("Unminimized window \(windowId)")
    }

    func captureFrontmostWindow() {
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           let bundleId = frontmost.bundleIdentifier,
           configuration.ignoredBundleIdentifiers.contains(bundleId) {
            print("Frontmost application \(bundleId) is configured to be ignored.")
            return
        }

        guard let managed = windowController.captureFrontmostWindow() else {
            print("No frontmost window available. Make sure Accessibility permissions are granted and another app has a visible window.")
            return
        }

        if let key = zoneKey(forManagedWindow: managed),
           let context = screenContexts[key.screenId],
           let zone = context.zoneController.zone(at: key.index),
           zone.windowId == managed.windowId {
            syncWindowsToZones()
            print("Window \(managed.windowId) is already managed in zone \(key.index)")
            return
        }

        windowPlacementManager.placeNewWindow(managed)
        print("Captured window \(managed.windowId)")
    }

    func validateApplication(pid: pid_t) {
        let pruned = validationRetryManager.validateWindowsForApplication(pid: pid, reason: "repl-command")
        if pruned.isEmpty {
            print("Validated pid \(pid): no destroyed windows detected")
        } else {
            print("Validated pid \(pid): pruned windows \(pruned)")
        }
    }

    // MARK: - Window Placement Logic




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

        // Width: match the height of zone indicators (6px)
        let indicatorWidth: CGFloat = 6

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
        let height: CGFloat = 6
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


    // MARK: - Synchronization

    /// Sync all windows to their zones, creating placeholders as needed
    internal func syncWindowsToZones(excluding excludedZones: Set<ZoneKey> = []) {
        let effectiveExcludedZones = excludedZones.union(dragExcludedZones)
        if isSyncingWindows {
            pendingSync = true
            pendingSyncExcludedZones.formUnion(effectiveExcludedZones)
            return
        }
        isSyncingWindows = true
        defer {
            isSyncingWindows = false
            if pendingSync {
                pendingSync = false
                let pendingExcluded = pendingSyncExcludedZones
                pendingSyncExcludedZones.removeAll()
                syncWindowsToZones(excluding: pendingExcluded)
            }
        }

        Logger.debug("Syncing windows to zones")

        let prunedWindowIds = windowController.pruneDestroyedExternalWindows()
        if !prunedWindowIds.isEmpty {
            for windowId in prunedWindowIds {
                removeWindowFromAllZones(windowId: windowId, reason: "sync-prune-destroyed")
            }
        }

        let existingWindows = windowController.allWindows
        var assignedWindowIds = Set<Int>()

        for screenId in screenOrder {
            guard let context = screenContexts[screenId],
                  let descriptor = descriptor(for: screenId) else {
                continue
            }
            let controller = context.zoneController

            for zone in controller.allZones {
                if let windowId = zone.windowId,
                   let managed = windowController.window(withId: windowId) {
                    let zoneKey = ZoneKey(screenId: screenId, index: zone.index)
                    if activeFitShouldSkipSync(for: zoneKey, windowId: windowId) {
                        Logger.debug("Sync skipping zone \(zone.index) on \(context.descriptor.localizedName) [\(screenId)] due to active ActiveFit window \(windowId)")
                        setManagedWindow(managed, screenId: screenId, zoneIndex: zone.index)
                        assignedWindowIds.insert(windowId)
                        continue
                    }
                    let displayFrame = frameWithMargin(for: zone, in: controller)
                    windowController.moveWindow(managed, to: displayFrame, on: descriptor)
                    setManagedWindow(managed, screenId: screenId, zoneIndex: zone.index)
                    assignedWindowIds.insert(windowId)
                }
            }
        }

        placeholderCoordinator.syncPlaceholders(
            existingWindows: existingWindows,
            screenOrder: screenOrder,
            excludedZones: effectiveExcludedZones,
            contextProvider: { screenId in
                guard let context = self.screenContexts[screenId],
                      let descriptor = self.descriptor(for: screenId) else {
                    return nil
                }
                let zoneController = context.zoneController
                return PlaceholderCoordinatorScreenContext(
                    descriptor: descriptor,
                    zoneController: zoneController,
                    displayFrameForZone: { zone in
                        self.frameWithMargin(for: zone, in: zoneController)
                    },
                    placeholderToZoneFrame: { frame, zone in
                        self.zoneFrame(fromContentFrame: frame, for: zone, in: context)
                    }
                )
            }
        )

        let placeholderCount = windowController.allWindows.filter { $0.isPlaceholder }.count

        // Calculate zone occupancy
        var occupiedZones = 0
        var emptyZones = 0
        for context in screenContexts.values {
            for zone in context.zoneController.allZones {
                if zone.isEmpty {
                    emptyZones += 1
                } else {
                    occupiedZones += 1
                }
            }
        }

        Logger.debug("Sync complete: assigned \(assignedWindowIds.count) window(s), placeholders \(placeholderCount), zones: \(occupiedZones) occupied, \(emptyZones) empty, excluded zones \(effectiveExcludedZones.count)")

        for window in windowController.allWindows where !window.isPlaceholder {
            if assignedWindowIds.contains(window.windowId) {
                continue
            }
            if isWindowInTemporaryZone(window.windowId) {
                continue
            }
            clearManagedWindowZone(window)
        }

        targetedZoneManager.ensureTargetedZone(reason: "sync")
        updateTemporaryZoneTargeting(reason: "sync")
        refreshIndicators()
        refreshResizeHandles()
    }

    func shouldDeferPlacementForNewWindow(_ managed: ManagedWindow, targetedZoneKey: ZoneKey?) -> Bool {
        // Chrome merges kill the dragged window until the drop completes; avoid evicting the sibling.
        guard let targetedZoneKey = targetedZoneKey else {
            return false
        }
        guard case .accessibility(_, let pid, _) = managed.backing else {
            return false
        }
        guard isLeftMouseButtonDown() else {
            return false
        }
        guard let context = screenContexts[targetedZoneKey.screenId],
              let zone = context.zoneController.zone(at: targetedZoneKey.index),
              let occupantId = zone.windowId,
              occupantId != managed.windowId,
              let occupant = windowController.window(withId: occupantId),
              !occupant.isPlaceholder,
              case .accessibility(_, let occupantPid, _) = occupant.backing,
              occupantPid == pid else {
            return false
        }
        return true
    }

    private func isLeftMouseButtonDown() -> Bool {
        if NSEvent.pressedMouseButtons & 0x1 != 0 {
            return true
        }
        return CGEventSource.buttonState(.combinedSessionState, button: .left)
    }

    /// Compute the frame used to render content inside a zone, honoring the spec margin
    internal func frameWithMargin(for zone: Zone, in controller: ZoneController) -> CGRect {
        let margins = zoneMargins(for: zone, in: controller)

        var left = margins.left
        var right = margins.right
        var top = margins.top
        var bottom = margins.bottom

        var frame = zone.frame.standardized

        let horizontalTotal = left + right
        if horizontalTotal > frame.width && frame.width > 0 {
            let scale = frame.width / horizontalTotal
            left *= scale
            right *= scale
        }

        let verticalTotal = top + bottom
        if verticalTotal > frame.height && frame.height > 0 {
            let scale = frame.height / verticalTotal
            top *= scale
            bottom *= scale
        }

        frame.origin.x += left
        frame.origin.y += top
        frame.size.width = max(0, frame.size.width - (left + right))
        frame.size.height = max(0, frame.size.height - (top + bottom))

        return frame
    }

    private func zoneMargins(for zone: Zone, in controller: ZoneController) -> ZoneEdgeMargins {
        let frame = zone.frame.standardized
        let bounds = controller.layoutBounds.standardized
        let neighbors = controller.allZones.filter { $0 !== zone }

        let fullMargin = zoneMargin
        let sharedMargin = zoneMargin / 2
        let tolerance = edgeAlignmentTolerance

        func verticalOverlap(with other: CGRect) -> CGFloat {
            let standardized = other.standardized
            return min(frame.maxY, standardized.maxY) - max(frame.minY, standardized.minY)
        }

        func horizontalOverlap(with other: CGRect) -> CGFloat {
            let standardized = other.standardized
            return min(frame.maxX, standardized.maxX) - max(frame.minX, standardized.minX)
        }

        let hasLeftNeighbor = neighbors.contains {
            abs($0.frame.standardized.maxX - frame.minX) <= tolerance && verticalOverlap(with: $0.frame) > 0
        }
        let hasRightNeighbor = neighbors.contains {
            abs($0.frame.standardized.minX - frame.maxX) <= tolerance && verticalOverlap(with: $0.frame) > 0
        }
        let hasTopNeighbor = neighbors.contains {
            abs($0.frame.standardized.maxY - frame.minY) <= tolerance && horizontalOverlap(with: $0.frame) > 0
        }
        let hasBottomNeighbor = neighbors.contains {
            abs($0.frame.standardized.minY - frame.maxY) <= tolerance && horizontalOverlap(with: $0.frame) > 0
        }

        let leftMargin: CGFloat
        if abs(frame.minX - bounds.minX) <= tolerance {
            leftMargin = fullMargin
        } else if hasLeftNeighbor {
            leftMargin = sharedMargin
        } else {
            leftMargin = fullMargin
        }

        let rightMargin: CGFloat
        if abs(frame.maxX - bounds.maxX) <= tolerance {
            rightMargin = fullMargin
        } else if hasRightNeighbor {
            rightMargin = sharedMargin
        } else {
            rightMargin = fullMargin
        }

        let topMargin: CGFloat
        if abs(frame.minY - bounds.minY) <= tolerance {
            topMargin = fullMargin
        } else if hasTopNeighbor {
            topMargin = sharedMargin
        } else {
            topMargin = fullMargin
        }

        let bottomMargin: CGFloat
        if abs(frame.maxY - bounds.maxY) <= tolerance {
            bottomMargin = fullMargin
        } else if hasBottomNeighbor {
            bottomMargin = sharedMargin
        } else {
            bottomMargin = fullMargin
        }

        return ZoneEdgeMargins(
            top: max(0, topMargin),
            left: max(0, leftMargin),
            bottom: max(0, bottomMargin),
            right: max(0, rightMargin)
        )
    }


    /// Convert a content frame (placeholder or occupant window) back into the zone frame.
    internal func zoneFrame(fromContentFrame frame: CGRect, for zone: Zone, in context: ScreenContext) -> CGRect {
        let margins = zoneMargins(for: zone, in: context.zoneController)

        var zoneFrame = frame.standardized
        zoneFrame.origin.x -= margins.left
        zoneFrame.origin.y -= margins.top
        zoneFrame.size.width += margins.left + margins.right
        zoneFrame.size.height += margins.top + margins.bottom
        let layoutBounds = context.zoneController.layoutBounds.standardized
        let pins = pinnedEdges(for: zone, in: context.zoneController)

        if pins.contains(.left) {
            let maxX = zoneFrame.maxX
            zoneFrame.origin.x = layoutBounds.minX
            zoneFrame.size.width = max(0, maxX - zoneFrame.origin.x)
        }

        if pins.contains(.right) {
            let minX = zoneFrame.minX
            zoneFrame.size.width = max(0, layoutBounds.maxX - minX)
        }

        if pins.contains(.top) {
            let maxY = zoneFrame.maxY
            zoneFrame.origin.y = layoutBounds.minY
            zoneFrame.size.height = max(0, maxY - zoneFrame.origin.y)
        }

        if pins.contains(.bottom) {
            let minY = zoneFrame.minY
            zoneFrame.size.height = max(0, layoutBounds.maxY - minY)
        }

        zoneFrame = clamp(frame: zoneFrame, to: layoutBounds)
        return zoneFrame
    }

    private struct ZoneEdgePinOptions: OptionSet {
        let rawValue: Int

        static let top = ZoneEdgePinOptions(rawValue: 1 << 0)
        static let bottom = ZoneEdgePinOptions(rawValue: 1 << 1)
        static let left = ZoneEdgePinOptions(rawValue: 1 << 2)
        static let right = ZoneEdgePinOptions(rawValue: 1 << 3)
    }

    private func pinnedEdges(for zone: Zone, in controller: ZoneController) -> ZoneEdgePinOptions {
        var pins: ZoneEdgePinOptions = []
        let zoneCount = controller.allZones.count

        if zone.index == 1 {
            pins.insert(.left)
        }

        if zoneCount >= 3 {
            if zone.index == 2 {
                pins.insert(.top)
            }
            if zone.index == 3 {
                pins.insert(.bottom)
            }
        }

        if zoneCount >= 2, zone.index >= 2 {
            pins.insert(.right)
        }

        return pins
    }

    private func clamp(frame: CGRect, to bounds: CGRect) -> CGRect {
        var normalized = frame.standardized

        let originX = max(bounds.minX, normalized.origin.x)
        let originY = max(bounds.minY, normalized.origin.y)
        let maxX = min(bounds.maxX, normalized.maxX)
        let maxY = min(bounds.maxY, normalized.maxY)

        normalized.origin = CGPoint(x: originX, y: originY)
        normalized.size.width = max(0, maxX - originX)
        normalized.size.height = max(0, maxY - originY)

        return normalized
    }

    // MARK: - ZoneResizeHandleManagerDelegate

    func resizeHandleDragged(screenId: CGDirectDisplayID, separatorIndex: Int, delta: CGPoint) {
        guard let context = screenContexts[screenId] else { return }
        
        let separators = context.zoneController.separators()
        guard let separator = separators.first(where: { $0.index == separatorIndex }) else { return }
        
        let scalarDelta: CGFloat
        switch separator.orientation {
        case .vertical:
            scalarDelta = delta.x
        case .horizontal:
            scalarDelta = delta.y
        }
        
        // Apply resize
        context.zoneController.resizeBySeparator(index: separatorIndex, delta: scalarDelta)
        
        // Sync windows and handles to new layout
        syncWindowsToZones()
    }

    internal func refreshResizeHandles() {
        var descriptors: [ZoneSeparatorDescriptor] = []
        
        for (screenId, context) in screenContexts {
            let separators = context.zoneController.separators()
            for sep in separators {
                descriptors.append(ZoneSeparatorDescriptor(
                    screenId: screenId,
                    index: sep.index,
                    orientation: sep.orientation,
                    frame: sep.frame
                ))
            }
        }
        
        resizeHandleManager.present(over: descriptors)
    }

    // MARK: - Keyboard Shortcuts

    /// Clear all zones on active screen. If zones are already empty, go to one-zone configuration.
    internal func clearOrResetZones() {
        clearOrResetZones(on: activeScreenId(), reason: "shortcut-active-screen")
    }

    /// Run the clear/reset shortcut on the screen containing the mouse cursor (fallback to active).
    internal func clearOrResetZonesAtCursor() {
        if let cursorScreenId = resolveCursorScreenId() {
            clearOrResetZones(on: cursorScreenId, reason: "shortcut-cursor-screen")
        } else {
            Logger.debug("Clear/reset zones (shortcut-cursor-screen): cursor outside managed displays, falling back to active screen")
            clearOrResetZones()
        }
    }

    private func clearOrResetZones(on screenId: CGDirectDisplayID, reason: String) {
        guard let context = screenContexts[screenId] else {
            Logger.debug("Clear/reset zones (\(reason)): screen context unavailable")
            return
        }

        let zones = context.zoneController.allZones
        let allEmpty = zones.allSatisfy { $0.isEmpty }
        let screenIndex = screenContextStore.loggingIndex(for: screenId)

        // Also empty the temporary zone on the selected screen
        temporaryZoneCoordinator.minimizeOccupant(on: screenId, reason: "clear-zones-shortcut")

        if allEmpty {
            Logger.debug("Clear/reset zones (\(reason)): all zones empty on screen \(screenIndex), resetting to 1 zone")
            let removedWindowIds = context.zoneController.setZoneCount(to: 1)

            for windowId in removedWindowIds {
                if let managed = windowController.window(withId: windowId) {
                    windowPlacementManager.handleWindowAfterZoneRemoval(managed, preferredScreenId: screenId)
                }
            }

            placeholderCoordinator.clearMappingsForScreen(screenId)

            syncWindowsToZones()
            activeFitRefreshAfterZoneTopologyChange(reason: "reset-to-one-zone")
        } else {
            Logger.debug("Clear/reset zones (\(reason)): minimizing all windows on screen \(screenIndex)")
            var minimizedCount = 0
            var minimizedWindowIds: [Int] = []

            for zone in zones {
                if let windowId = zone.windowId,
                   let managed = windowController.window(withId: windowId),
                   !managed.isPlaceholder {
                    minimizeWindowProgrammatically(managed, reason: "clear-zones-shortcut")
                    removeWindowFromAllZones(windowId: windowId, reason: "clear-zones-shortcut", retarget: false)
                    minimizedCount += 1
                    minimizedWindowIds.append(windowId)
                }
            }

            Logger.debug("Clear/reset zones (\(reason)): minimized \(minimizedCount) window(s) on screen \(screenIndex)")
            syncWindowsToZones()
        }

        // After any clear/minimize cycle on this screen, explicitly target zone 1 on that screen.
        if context.zoneController.zone(at: 1) != nil {
            targetedZoneManager.setTargetedZone(ZoneKey(screenId: screenId, index: 1), reason: "clear-zones-shortcut")
        } else {
            targetedZoneManager.ensureTargetedZone(reason: "clear-zones-shortcut-fallback")
        }
    }

    internal func resolveCursorScreenId() -> CGDirectDisplayID? {
        guard let cursorPoint = currentCursorAccessibilityPoint() else {
            return nil
        }

        for screenId in screenOrder {
            guard let context = screenContexts[screenId] else {
                continue
            }
            let descriptor = context.descriptor
            let screenBounds = descriptor.cocoaToScreen(descriptor.cocoaBounds)
            let accessibilityBounds = descriptor.screenToAccessibility(screenBounds)
            if accessibilityBounds.contains(cursorPoint) {
                return screenId
            }
        }

        return nil
    }

    /// Target the temporary zone, preferring the screen of the currently targeted normal zone
    internal func targetTemporaryZone() {
        guard let targetedZone = targetedZoneManager.targetedZoneKey else {
            Logger.debug("Target temporary zone: normal zone not targeted; shortcut ignored")
            return
        }

        let preferredScreenId: CGDirectDisplayID
        if screenContexts[targetedZone.screenId] != nil {
            preferredScreenId = targetedZone.screenId
        } else {
            let active = activeScreenId()
            if screenContexts[active] != nil {
                preferredScreenId = active
            } else {
                preferredScreenId = screenOrder.first ?? active
            }
        }

        let screenIndex = screenContextStore.loggingIndex(for: preferredScreenId)
        Logger.debug("Target temporary zone: setting temporary zone on screen \(screenIndex) as target")
        targetedZoneManager.setTemporaryTarget(on: preferredScreenId, reason: "shortcut-target-temporary")
    }

    /// Navigate up: from temporary zone to normal zone on same screen
    internal func navigateUp() {
        guard let targetedTemporaryScreenId = targetedZoneManager.targetedTemporaryScreenId else {
            Logger.debug("Navigate up: temporary zone not targeted, doing nothing")
            return
        }

        guard let context = screenContexts[targetedTemporaryScreenId] else {
            Logger.debug("Navigate up: no context for temporary zone screen")
            return
        }

        let zones = context.zoneController.allZones

        // Prefer empty tiling zone with lowest index
        let emptyZones = zones.filter { $0.isEmpty }.sorted { $0.index < $1.index }
        if let firstEmptyZone = emptyZones.first {
            let zoneKey = ZoneKey(screenId: targetedTemporaryScreenId, index: firstEmptyZone.index)
            Logger.debug("Navigate up: targeting empty zone \(firstEmptyZone.index) on screen \(screenContextStore.loggingIndex(for: targetedTemporaryScreenId))")
            targetedZoneManager.setTargetedZone(zoneKey, reason: "shortcut-navigate-up")
            return
        }

        // If no empty zone, target filled zone with highest index
        let filledZones = zones.filter { !$0.isEmpty }.sorted { $0.index > $1.index }
        if let firstFilledZone = filledZones.first {
            let zoneKey = ZoneKey(screenId: targetedTemporaryScreenId, index: firstFilledZone.index)
            Logger.debug("Navigate up: targeting filled zone \(firstFilledZone.index) on screen \(screenContextStore.loggingIndex(for: targetedTemporaryScreenId))")
            targetedZoneManager.setTargetedZone(zoneKey, reason: "shortcut-navigate-up")
            return
        }

        Logger.debug("Navigate up: no zones available on screen")
    }

    /// Navigate left: between zones or screens
    internal func navigateLeft() {
        // If temporary zone is targeted, go to temporary zone on screen to the left
        if let targetedTemporaryScreenId = targetedZoneManager.targetedTemporaryScreenId {
            navigateTemporaryZoneLeft(from: targetedTemporaryScreenId)
            return
        }

        // If normal zone is targeted, navigate to lower index or previous screen
        if let targetedKey = targetedZoneManager.targetedZoneKey {
            navigateNormalZoneLeft(from: targetedKey)
            return
        }

        Logger.debug("Navigate left: no zone targeted")
    }

    /// Navigate right: between zones or screens
    internal func navigateRight() {
        // If temporary zone is targeted, go to temporary zone on screen to the right
        if let targetedTemporaryScreenId = targetedZoneManager.targetedTemporaryScreenId {
            navigateTemporaryZoneRight(from: targetedTemporaryScreenId)
            return
        }

        // If normal zone is targeted, navigate to higher index or next screen
        if let targetedKey = targetedZoneManager.targetedZoneKey {
            navigateNormalZoneRight(from: targetedKey)
            return
        }

        Logger.debug("Navigate right: no zone targeted")
    }

    private func navigateTemporaryZoneLeft(from currentScreenId: CGDirectDisplayID) {
        let screens = screenOrderLeftToRight
        guard let currentIndex = screens.firstIndex(of: currentScreenId), currentIndex > 0 else {
            Logger.debug("Navigate left (temp): already at leftmost screen")
            return
        }

        let leftScreenId = screens[currentIndex - 1]
        Logger.debug("Navigate left (temp): targeting temporary zone on screen \(screenContextStore.loggingIndex(for: leftScreenId))")
        targetedZoneManager.setTemporaryTarget(on: leftScreenId, reason: "shortcut-navigate-left-temp")
    }

    private func navigateTemporaryZoneRight(from currentScreenId: CGDirectDisplayID) {
        let screens = screenOrderLeftToRight
        guard let currentIndex = screens.firstIndex(of: currentScreenId), currentIndex < screens.count - 1 else {
            Logger.debug("Navigate right (temp): already at rightmost screen")
            return
        }

        let rightScreenId = screens[currentIndex + 1]
        Logger.debug("Navigate right (temp): targeting temporary zone on screen \(screenContextStore.loggingIndex(for: rightScreenId))")
        targetedZoneManager.setTemporaryTarget(on: rightScreenId, reason: "shortcut-navigate-right-temp")
    }

    private func navigateNormalZoneLeft(from currentKey: ZoneKey) {
        guard let context = screenContexts[currentKey.screenId] else {
            Logger.debug("Navigate left (normal): no context for current screen")
            return
        }

        let zones = context.zoneController.allZones.sorted { $0.index < $1.index }

        // Try to find zone with lower index on same screen
        if let lowerZone = zones.last(where: { $0.index < currentKey.index }) {
            let newKey = ZoneKey(screenId: currentKey.screenId, index: lowerZone.index)
            Logger.debug("Navigate left (normal): targeting zone \(lowerZone.index) on same screen")
            targetedZoneManager.setTargetedZone(newKey, reason: "shortcut-navigate-left-normal")
            return
        }

        // If at first zone, wrap to previous screen
        let screens = screenOrderLeftToRight
        guard let currentScreenIndex = screens.firstIndex(of: currentKey.screenId), currentScreenIndex > 0 else {
            Logger.debug("Navigate left (normal): at first zone on first screen")
            return
        }

        let leftScreenId = screens[currentScreenIndex - 1]
        guard let leftContext = screenContexts[leftScreenId] else {
            Logger.debug("Navigate left (normal): no context for left screen")
            return
        }

        let leftZones = leftContext.zoneController.allZones.sorted { $0.index > $1.index }
        if let lastZone = leftZones.first {
            let newKey = ZoneKey(screenId: leftScreenId, index: lastZone.index)
            Logger.debug("Navigate left (normal): wrapping to zone \(lastZone.index) on screen \(screenContextStore.loggingIndex(for: leftScreenId))")
            targetedZoneManager.setTargetedZone(newKey, reason: "shortcut-navigate-left-normal-wrap")
        }
    }

    private func navigateNormalZoneRight(from currentKey: ZoneKey) {
        guard let context = screenContexts[currentKey.screenId] else {
            Logger.debug("Navigate right (normal): no context for current screen")
            return
        }

        let zones = context.zoneController.allZones.sorted { $0.index < $1.index }

        // Try to find zone with higher index on same screen
        if let higherZone = zones.first(where: { $0.index > currentKey.index }) {
            let newKey = ZoneKey(screenId: currentKey.screenId, index: higherZone.index)
            Logger.debug("Navigate right (normal): targeting zone \(higherZone.index) on same screen")
            targetedZoneManager.setTargetedZone(newKey, reason: "shortcut-navigate-right-normal")
            return
        }

        // If at last zone, wrap to next screen
        let screens = screenOrderLeftToRight
        guard let currentScreenIndex = screens.firstIndex(of: currentKey.screenId),
              currentScreenIndex < screens.count - 1 else {
            Logger.debug("Navigate right (normal): at last zone on last screen")
            return
        }

        let rightScreenId = screens[currentScreenIndex + 1]
        guard let rightContext = screenContexts[rightScreenId] else {
            Logger.debug("Navigate right (normal): no context for right screen")
            return
        }

        let rightZones = rightContext.zoneController.allZones.sorted { $0.index < $1.index }
        if let firstZone = rightZones.first {
            let newKey = ZoneKey(screenId: rightScreenId, index: firstZone.index)
            Logger.debug("Navigate right (normal): wrapping to zone \(firstZone.index) on screen \(screenContextStore.loggingIndex(for: rightScreenId))")
            targetedZoneManager.setTargetedZone(newKey, reason: "shortcut-navigate-right-normal-wrap")
        }
    }

    // MARK: - Event suppression helpers

    /// Suppress the *next* occurrence of the given events for specific windows. Entries self-expire after `timeout`.
    internal func suppressNextEvents(
        for windowIds: [Int],
        events: Set<AppController.SuppressedEvent>,
        timeout: TimeInterval = 3.0,
        reason: String
    ) {
        guard !windowIds.isEmpty, !events.isEmpty else { return }
        let deadline = Date().addingTimeInterval(timeout)
        for windowId in windowIds {
            var suppressions = eventSuppressions[windowId] ?? [:]
            for event in events {
                suppressions[event] = SuppressionEntry(remaining: 1, deadline: deadline)
            }
            eventSuppressions[windowId] = suppressions
        }
        let eventList = events.map { $0.rawValue }.joined(separator: ",")
        Logger.debug("Suppressing next events [\(eventList)] for windows \(windowIds) until \(deadline) (reason: \(reason))")
    }

    internal func isEventSuppressed(windowId: Int, event: AppController.SuppressedEvent) -> Bool {
        let now = Date()
        guard var suppressions = eventSuppressions[windowId],
              var entry = suppressions[event] else {
            return false
        }

        if entry.deadline < now || entry.remaining <= 0 {
            suppressions.removeValue(forKey: event)
            if suppressions.isEmpty {
                eventSuppressions.removeValue(forKey: windowId)
            } else {
                eventSuppressions[windowId] = suppressions
            }
            return false
        }

        entry.remaining -= 1
        suppressions[event] = entry.remaining > 0 ? entry : nil
        if suppressions[event] == nil {
            suppressions.removeValue(forKey: event)
        }
        if suppressions.isEmpty {
            eventSuppressions.removeValue(forKey: windowId)
        } else {
            eventSuppressions[windowId] = suppressions
        }

        Logger.debug("Suppressed event \(event.rawValue) for window \(windowId)")
        return true
    }

    // MARK: - Programmatic actions

    internal func minimizeWindowProgrammatically(
        _ managed: ManagedWindow,
        reason: String,
        suppressTimeout: TimeInterval = 3.0
    ) {
        suppressNextEvents(for: [managed.windowId], events: [.miniaturized], timeout: suppressTimeout, reason: reason)
        windowController.minimizeWindow(managed)
    }

    // Protocol convenience overload (no duration parameter)
    internal func minimizeWindowProgrammatically(
        _ managed: ManagedWindow,
        reason: String
    ) {
        minimizeWindowProgrammatically(managed, reason: reason, suppressTimeout: 3.0)
    }

    /// Minimizes the currently active/key window using Cmd-M shortcut override
    internal func minimizeActiveWindow() {
        // Try to get the frontmost managed window
        guard let (managed, pid) = managedWindowForFrontmostApplication(
            logPrefix: "minimizeActiveWindow"
        ) else {
            Logger.debug("minimizeActiveWindow: No eligible frontmost window to minimize")
            return
        }

        // Get window title for logging
        var windowTitle = "untitled"
        if case .accessibility(let element, _, _) = managed.backing {
            var value: AnyObject?
            if AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &value) == .success,
               let title = value as? String,
               !title.isEmpty {
                windowTitle = title
            }
        }

        Logger.debug(
            "minimizeActiveWindow: Minimizing window \(managed.windowId) from pid \(pid) " +
            "(\(windowTitle))"
        )

        minimizeWindowProgrammatically(managed, reason: "cmd-m-override")

        // Since we're suppressing the miniaturize notification to avoid feedback loops,
        // we need to manually handle the zone removal and placeholder creation
        removeWindowFromAllZones(windowId: managed.windowId, reason: "cmd-m-minimize", retarget: true)
        syncWindowsToZones()

        // Clear ActiveFit state if needed
        activeFitClearForWindowIfNeeded(windowId: managed.windowId, restoreToZone: false, reason: "cmd-m-minimize")
        activeFitClearSuppressionForWindow(managed.windowId)
    }

}