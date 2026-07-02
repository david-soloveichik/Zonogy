import Foundation
import AppKit

/// Initial window seeding at launch and accessibility-grant restart.
extension AppController {
    /// Restarts the app after accessibility permissions are granted.
    /// This ensures all global input interceptors (DockMenus, ZoneClickInterceptor,
    /// external zone-drop interception, CmdTabKeyInterceptor) initialize correctly
    /// with the new permissions.
    func restartAfterAccessibilityGranted() {
        Logger.debug("Accessibility permission granted - restarting app")

        let bundleURL = Bundle.main.bundleURL
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true

        NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        }
    }

    internal func prepareExistingApplicationWindows() {
        var windowsByScreen: [CGDirectDisplayID: [ManagedWindow]] = [:]
        let visibleBundleIds = bundleIdsWithVisibleWindows()

        for application in NSWorkspace.shared.runningApplications {
            guard shouldManage(application: application, visibleBundleIds: visibleBundleIds) else {
                continue
            }

            let windows = captureWindows(for: application, notifyDelegate: false, allowExisting: false)
            for window in windows {
                // Skip minimized windows from zone placement - they're tracked for the launcher
                // but shouldn't be placed into zones during startup.
                // Use AX query since windows don't have zone assignments yet.
                guard !window.isMinimizedPerAccessibility else { continue }

                let resolvedScreenId = detectScreenId(for: window) ?? primaryScreenId
                guard screenContexts[resolvedScreenId] != nil else {
                    continue
                }
                windowsByScreen[resolvedScreenId, default: []].append(window)
            }
        }

        let orderedScreenIds = startupScreenProcessingOrder()
        for screenId in orderedScreenIds {
            guard let context = screenContexts[screenId] else {
                continue
            }

            let windows = windowsByScreen[screenId] ?? []
            let desiredZoneCount = max(1, min(windows.count, context.zoneController.layoutStyle.maxZoneCount))
            let removedWindowIds = context.zoneController.setZoneCount(to: desiredZoneCount)

            // Clear placeholders when zone count changes
            if !removedWindowIds.isEmpty {
                placeholderCoordinator.clearPlaceholdersForScreen(screenId)
            }

            for removedId in removedWindowIds {
                if let removedWindow = windowController.window(withId: removedId) {
                    clearManagedWindowZone(removedWindow)
                    minimizeWindowProgrammatically(removedWindow, reason: "startup-trim-zone-count")
                }
            }

            var unassignedWindows = windows
            let zoneOrder = context.zoneController.allZones.sorted { $0.index < $1.index }
            let screenFrames = startupScreenFrames(for: windows, descriptor: context.descriptor)

            for zone in zoneOrder {
                guard !unassignedWindows.isEmpty else {
                    break
                }

                let selectedIndex = selectStartupWindowIndex(
                    for: zone,
                    from: unassignedWindows,
                    screenFrames: screenFrames,
                    descriptor: context.descriptor
                )

                let selectedWindow = unassignedWindows.remove(at: selectedIndex)
                windowPlacementManager.placeNewWindow(selectedWindow, preferredScreenId: screenId)
            }

            for window in unassignedWindows {
                clearManagedWindowZone(window)
                minimizeWindowProgrammatically(window, reason: "startup-unassigned-window")
            }
        }
    }

    /// Compute the left edge of a window in screen coordinates for ordering.
    private func screenMinX(for managed: ManagedWindow, descriptor: ScreenDescriptor) -> CGFloat {
        guard let cocoaFrame = cocoaFrame(for: managed) else {
            return .greatestFiniteMagnitude
        }
        return descriptor.cocoaToScreen(cocoaFrame).minX
    }

    /// Ensure we iterate screens deterministically, covering every known context.
    private func startupScreenProcessingOrder() -> [CGDirectDisplayID] {
        var ordered = screenOrder
        for screenId in screenContexts.keys where !ordered.contains(screenId) {
            ordered.append(screenId)
        }
        return ordered
    }

    /// Cache window frames expressed in screen coordinates for startup ordering.
    private func startupScreenFrames(for windows: [ManagedWindow], descriptor: ScreenDescriptor) -> [Int: CGRect] {
        var frames: [Int: CGRect] = [:]
        for window in windows {
            guard let cocoaFrame = cocoaFrame(for: window) else {
                continue
            }
            frames[window.windowId] = descriptor.cocoaToScreen(cocoaFrame)
        }
        return frames
    }

    /// Choose a window for the specified zone based on overlap-first ordering.
    private func selectStartupWindowIndex(
        for zone: Zone,
        from windows: [ManagedWindow],
        screenFrames: [Int: CGRect],
        descriptor: ScreenDescriptor
    ) -> Int {
        var bestIndex = 0
        var bestArea: CGFloat = -1
        var bestLeft: CGFloat = .greatestFiniteMagnitude
        var bestWindowId = Int.max

        for (index, window) in windows.enumerated() {
            let area = startupOverlapArea(for: window.windowId, zone: zone, screenFrames: screenFrames)
            if area > bestArea {
                bestArea = area
                bestIndex = index
                bestLeft = screenFrames[window.windowId]?.minX ?? screenMinX(for: window, descriptor: descriptor)
                bestWindowId = window.windowId
                continue
            }

            if area == bestArea && area > 0 {
                let candidateLeft = screenFrames[window.windowId]?.minX ?? screenMinX(for: window, descriptor: descriptor)
                if candidateLeft < bestLeft || (candidateLeft == bestLeft && window.windowId < bestWindowId) {
                    bestIndex = index
                    bestLeft = candidateLeft
                    bestWindowId = window.windowId
                }
            }
        }

        if bestArea > 0 {
            return bestIndex
        }

        return leftMostStartupWindowIndex(from: windows, descriptor: descriptor)
    }

    /// Compute overlap area between a window and zone in screen coordinates.
    private func startupOverlapArea(
        for windowId: Int,
        zone: Zone,
        screenFrames: [Int: CGRect]
    ) -> CGFloat {
        guard let frame = screenFrames[windowId] else {
            return 0
        }
        let intersection = frame.intersection(zone.frame)
        if intersection.isNull || intersection.isEmpty {
            return 0
        }
        return intersection.width * intersection.height
    }

    /// Return the index of the left-most window among the provided list.
    private func leftMostStartupWindowIndex(from windows: [ManagedWindow], descriptor: ScreenDescriptor) -> Int {
        var bestIndex = 0
        var bestLeft = CGFloat.greatestFiniteMagnitude
        var bestWindowId = Int.max

        for (index, window) in windows.enumerated() {
            let leftX = screenMinX(for: window, descriptor: descriptor)
            if leftX < bestLeft || (leftX == bestLeft && window.windowId < bestWindowId) {
                bestIndex = index
                bestLeft = leftX
                bestWindowId = window.windowId
            }
        }

        return bestIndex
    }
}
