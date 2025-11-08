import Foundation
import AppKit
import ApplicationServices

/// Zone lifecycle operations: zone/window commands, placement, sync, and indicator refresh.
extension AppController {
    func addZone() {
        let screenId = activeScreenId()
        addZone(on: screenId)
    }

    internal func addZone(on screenId: CGDirectDisplayID) {
        guard let context = screenContexts[screenId],
              let newZone = context.zoneController.addZone() else {
            print("Failed to add zone (max 3 zones)")
            return
        }
        syncWindowsToZones()
        let newZoneKey = zoneKey(for: screenId, index: newZone.index)
        if shouldRetarget(to: newZoneKey) {
            targetedZoneManager.setTargetedZone(newZoneKey, reason: "zone-added")
        } else {
            targetedZoneManager.ensureTargetedZone(reason: "zone-added")
        }
        print("Added zone \(newZone.index) on \(context.descriptor.localizedName)")
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
        if let currentTarget, currentTarget.screenId == screenId {
            if currentTarget.index == index {
                pendingTargetedKey = targetedZoneManager.fallbackTargetedZone(preferredScreenId: screenId)
            } else if currentTarget.index > index {
                pendingTargetedKey = ZoneKey(screenId: screenId, index: currentTarget.index - 1)
            }
        }

        if let pendingTargetedKey {
            targetedZoneManager.setTargetedZone(pendingTargetedKey, reason: "zone-removed")
        }

        if let removedWindowId = removalResult.removedWindowId,
           let managed = windowController.window(withId: removedWindowId) {
            windowPlacementManager.handleWindowAfterZoneRemoval(managed, preferredScreenId: screenId)
        }

        syncWindowsToZones()

        if pendingTargetedKey == nil {
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

    func createWindow() {
        let managed = windowController.createTestWindow(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        windowPlacementManager.placeNewWindow(managed)
        print("Created window \(managed.windowId)")
    }

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

        windowController.minimizeWindow(managed)

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

        if let zoneIndex = managed.zoneIndex,
           let screenId = managed.screenDisplayId,
           let zone = screenContexts[screenId]?.zoneController.zone(at: zoneIndex),
           zone.windowId == managed.windowId {
            syncWindowsToZones()
            print("Window \(managed.windowId) is already managed in zone \(zoneIndex)")
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




    private func indicatorFrame(for zone: Zone, descriptor: ScreenDescriptor) -> CGRect {
        let zoneFrame = descriptor.screenToCocoa(zone.frame).standardized
        let bounds = descriptor.cocoaBounds.standardized

        let indicatorHeight: CGFloat = 6
        let minWidth: CGFloat = 40
        let targetWidth = max(minWidth, zoneFrame.width / 3)
        let clampedWidth = min(targetWidth, zoneFrame.width)

        var originX = zoneFrame.midX - clampedWidth / 2
        originX = max(bounds.minX, min(originX, bounds.maxX - clampedWidth))

        let offset: CGFloat = 2
        // Always position the indicator inside the zone at the top with consistent offset
        // This ensures all zones have the same visual treatment
        var originY = zoneFrame.maxY - indicatorHeight - offset

        // Ensure the indicator stays within bounds
        if originY < bounds.minY {
            originY = bounds.minY
        }
        if originY + indicatorHeight > bounds.maxY {
            originY = bounds.maxY - indicatorHeight
        }

        return CGRect(x: originX, y: originY, width: clampedWidth, height: indicatorHeight)
    }

    internal func refreshIndicators() {
        // Refresh zone indicators
        var descriptors: [ZoneIndicatorDescriptor] = []

        for (screenId, context) in screenContexts {
            let screenDescriptor = context.descriptor
            for zone in context.zoneController.allZones {
                let key = ZoneKey(screenId: screenId, index: zone.index)
                let frame = indicatorFrame(for: zone, descriptor: screenDescriptor)
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

        for (screenId, context) in screenContexts {
            let zoneCount = context.zoneController.allZones.count
            // Only show the indicator if there are fewer than 3 zones
            guard zoneCount < 3 else { continue }

            let screenDescriptor = context.descriptor
            let frame = addZoneIndicatorFrame(for: screenDescriptor)
            guard frame.width > 0, frame.height > 0 else {
                continue
            }
            let descriptor = AddZoneIndicatorDescriptor(
                screenId: screenId,
                frame: frame
            )
            addZoneDescriptors.append(descriptor)
        }

        if addZoneDescriptors.isEmpty {
            addZoneIndicatorManager.tearDown()
        } else {
            addZoneIndicatorManager.present(for: addZoneDescriptors)
        }
    }

    private func addZoneIndicatorFrame(for descriptor: ScreenDescriptor) -> CGRect {
        let bounds = descriptor.cocoaBounds.standardized

        // Width: match the height of zone indicators (6px)
        let indicatorWidth: CGFloat = 6

        // Height: 1/3 of screen height
        let indicatorHeight = bounds.height / 3

        // Position on the right edge, vertically centered
        let originX = bounds.maxX - indicatorWidth
        let originY = bounds.midY - indicatorHeight / 2

        return CGRect(x: originX, y: originY, width: indicatorWidth, height: indicatorHeight)
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
            if !assignedWindowIds.contains(window.windowId) {
                clearManagedWindowZone(window)
            }
        }

        targetedZoneManager.ensureTargetedZone(reason: "sync")
        refreshIndicators()
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
        zoneFrame = clamp(frame: zoneFrame, to: context.zoneController.layoutBounds)
        return zoneFrame
    }

    internal func applyPlaceholderResize(zoneKey: ZoneKey, placeholderFrame: CGRect, finalize: Bool) {
        guard let context = screenContexts[zoneKey.screenId],
              let descriptor = descriptor(for: zoneKey.screenId) else {
            return
        }

        let screenContext = PlaceholderCoordinatorScreenContext(
            descriptor: descriptor,
            zoneController: context.zoneController,
            displayFrameForZone: { zone in
                self.frameWithMargin(for: zone, in: context.zoneController)
            },
            placeholderToZoneFrame: { frame, zone in
                self.zoneFrame(fromContentFrame: frame, for: zone, in: context)
            }
        )

        placeholderCoordinator.applyResize(zoneKey: zoneKey, placeholderFrame: placeholderFrame, context: screenContext, finalize: finalize)
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

}
