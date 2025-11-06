/// JSON API response formatting for socket server communication
import Cocoa

// MARK: - JSON API for Socket Server

extension AppController {

    /// Convert internal CGDirectDisplayID to user-friendly index (0,1,2...)
    /// Provides consistency with winmanmon's screen numbering
    private func getScreenIndex(for displayId: CGDirectDisplayID) -> Int? {
        return screenContextStore.screenIndex(for: displayId) ?? ScreenContextStore.screenIndex(for: displayId)
    }

    func addZoneJSON() -> [String: Any] {
        let screenId = activeScreenId()
        guard let context = screenContexts[screenId],
              let newZone = context.zoneController.addZone() else {
            return ["error": "Failed to add zone (max 3 zones)"]
        }
        syncWindowsToZones()
        return [
            "screen_display_id": screenId,
            "screen": getScreenIndex(for: screenId) as Any,
            "screen_name": context.descriptor.localizedName,
            "zone_index": newZone.index,
            "zone_count": context.zoneController.allZones.count
        ]
    }

    func removeZoneJSON(at index: Int) -> [String: Any] {
        let screenId = activeScreenId()
        guard let context = screenContexts[screenId],
              let removalResult = performRemoveZone(at: index, on: screenId, announce: false, context: context) else {
            return ["error": "Failed to remove zone \(index)"]
        }

        var response: [String: Any] = [
            "screen_display_id": screenId,
            "screen": getScreenIndex(for: screenId) as Any,
            "screen_name": context.descriptor.localizedName,
            "removed_index": index,
            "zone_count": context.zoneController.allZones.count,
            "removed_window_id": removalResult.removedWindowId as Any
        ]

        if let removedWindowId = removalResult.removedWindowId,
           let managed = windowController.window(withId: removedWindowId) {
            response["reassigned_window_id"] = managed.windowId
            response["reassigned_zone_index"] = managed.zoneIndex as Any
            response["reassigned_screen_display_id"] = managed.screenDisplayId as Any
            if let screenId = managed.screenDisplayId {
                response["reassigned_screen"] = getScreenIndex(for: screenId)
            }
        }

        return response
    }

    func resizeZoneJSON(at index: Int, frame: CGRect) -> [String: Any] {
        let screenId = activeScreenId()
        guard let context = screenContexts[screenId] else {
            return ["error": "Active screen not available"]
        }

        guard let zone = context.zoneController.zone(at: index) else {
            return ["error": "Zone \(index) not found on \(context.descriptor.localizedName)"]
        }

        guard zone.isEmpty else {
            return ["error": "Zone \(index) is occupied; minimize or close its window before resizing."]
        }

        guard context.zoneController.resizeZone(at: index, to: frame) else {
            return ["error": "Failed to resize zone \(index)"]
        }

        syncWindowsToZones()

        guard let updatedZone = context.zoneController.zone(at: index) else {
            return ["error": "Zone \(index) unavailable after resize"]
        }

        return [
            "screen_display_id": screenId,
            "screen": getScreenIndex(for: screenId) as Any,
            "screen_name": context.descriptor.localizedName,
            "zone_index": updatedZone.index,
            "frame": [
                "x": updatedZone.frame.origin.x,
                "y": updatedZone.frame.origin.y,
                "width": updatedZone.frame.width,
                "height": updatedZone.frame.height
            ],
            "zone_count": context.zoneController.allZones.count
        ]
    }

    func createWindowJSON() -> [String: Any] {
        let managed = windowController.createTestWindow(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        windowPlacementManager.placeNewWindow(managed)
        var result: [String: Any] = [
            "window_id": managed.windowId,
            "zone_index": managed.zoneIndex as Any,
            "screen_display_id": managed.screenDisplayId as Any
        ]
        if let screenId = managed.screenDisplayId {
            result["screen"] = getScreenIndex(for: screenId)
        }
        return result
    }

    func captureFrontmostWindowJSON() -> [String: Any] {
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           let bundleId = frontmost.bundleIdentifier,
           configuration.ignoredBundleIdentifiers.contains(bundleId) {
            return ["error": "Frontmost application \(bundleId) is configured to be ignored"]
        }

        guard let managed = windowController.captureFrontmostWindow() else {
            return ["error": "No frontmost window available or Accessibility permissions missing"]
        }

        if let zoneIndex = managed.zoneIndex,
           let screenId = managed.screenDisplayId,
           let zone = screenContexts[screenId]?.zoneController.zone(at: zoneIndex),
           zone.windowId == managed.windowId {
            syncWindowsToZones()
            return [
                "window_id": managed.windowId,
                "zone_index": zoneIndex,
                "screen_display_id": screenId,
                "screen": getScreenIndex(for: screenId) as Any,
                "screen_name": screenContexts[screenId]?.descriptor.localizedName as Any,
                "message": "Already managed"
            ]
        }

        windowPlacementManager.placeNewWindow(managed)

        var result: [String: Any] = [
            "window_id": managed.windowId,
            "zone_index": managed.zoneIndex as Any,
            "screen_display_id": managed.screenDisplayId as Any
        ]
        if let screenId = managed.screenDisplayId {
            result["screen"] = getScreenIndex(for: screenId)
        }
        return result
    }

    func closeWindowJSON(withId windowId: Int) -> [String: Any] {
        guard let managed = windowController.window(withId: windowId) else {
            return ["error": "Window \(windowId) not found"]
        }

        removeWindowFromAllZones(windowId: windowId, reason: "socket-close-window")
        windowController.closeWindow(managed)
        syncWindowsToZones()

        return ["window_id": windowId]
    }

    func minimizeWindowJSON(withId windowId: Int) -> [String: Any] {
        guard let managed = windowController.window(withId: windowId) else {
            return ["error": "Window \(windowId) not found"]
        }

        windowController.minimizeWindow(managed)
        removeWindowFromAllZones(windowId: windowId, reason: "socket-minimize")
        syncWindowsToZones()

        return ["window_id": windowId]
    }

    func unminimizeWindowJSON(withId windowId: Int) -> [String: Any] {
        guard let managed = windowController.window(withId: windowId) else {
            return ["error": "Window \(windowId) not found"]
        }

        windowController.unminimizeWindow(managed)
        windowPlacementManager.placeNewWindow(managed)

        var result: [String: Any] = [
            "window_id": windowId,
            "zone_index": managed.zoneIndex as Any,
            "screen_display_id": managed.screenDisplayId as Any
        ]
        if let screenId = managed.screenDisplayId {
            result["screen"] = getScreenIndex(for: screenId)
        }
        return result
    }

    func listZonesJSON() -> [String: Any] {
        let zones = screenOrder.flatMap { screenId -> [[String: Any]] in
            guard let context = screenContexts[screenId] else { return [] }
            return context.zoneController.allZones.map { zone in
                [
                    "screen_display_id": screenId,
                    "screen": getScreenIndex(for: screenId) as Any,
                    "screen_name": context.descriptor.localizedName,
                    "index": zone.index,
                    "window_id": zone.windowId as Any,
                    "frame": [
                        "x": zone.frame.origin.x,
                        "y": zone.frame.origin.y,
                        "width": zone.frame.width,
                        "height": zone.frame.height
                    ]
                ]
            }
        }
        return ["zones": zones]
    }

    func relayoutJSON() -> [String: Any] {
        for context in screenContexts.values {
            context.zoneController.relayout()
        }
        syncWindowsToZones()
        let screenSummaries = screenOrder.compactMap { screenId -> [String: Any]? in
            guard let context = screenContexts[screenId] else { return nil }
            return [
                "screen_display_id": screenId,
                "screen": getScreenIndex(for: screenId) as Any,
                "screen_name": context.descriptor.localizedName,
                "zone_count": context.zoneController.allZones.count
            ]
        }
        return ["screens": screenSummaries]
    }

    func windowInfoJSON(windowId: Int) -> [String: Any] {
        guard let managed = windowController.window(withId: windowId) else {
            return ["error": "Window \(windowId) not found"]
        }

        let type: String
        if managed.isPlaceholder {
            type = "placeholder"
        } else {
            switch managed.backing {
            case .appKit:
                type = "test"
            case .accessibility:
                type = "external"
            }
        }

        let screenId = managed.screenDisplayId ?? detectScreenId(for: managed)
        let screenDescriptor = screenId.flatMap { (id: CGDirectDisplayID) -> ScreenDescriptor? in
            descriptor(for: id)
        }
        let actualFrame: CGRect
        if let screenDescriptor {
            actualFrame = windowController.actualFrameInScreenCoordinates(for: managed, on: screenDescriptor)
        } else if let fallback = windowController.actualFrameInScreenCoordinates(for: managed) {
            actualFrame = fallback
        } else {
            actualFrame = .zero
        }

        var result: [String: Any] = [
            "window_id": windowId,
            "type": type,
            "is_placeholder": managed.isPlaceholder,
            "zone_index": managed.zoneIndex as Any,
            "actual_frame": [
                "x": actualFrame.origin.x,
                "y": actualFrame.origin.y,
                "width": actualFrame.width,
                "height": actualFrame.height
            ]
        ]

        var owningPid: pid_t?
        switch managed.backing {
        case .appKit:
            owningPid = getpid()
        case .accessibility(_, let pid, _):
            owningPid = pid
        }

        if let pid = owningPid {
            result["pid"] = Int(pid)

            if let application = NSRunningApplication(processIdentifier: pid) ?? (pid == getpid() ? NSRunningApplication.current : nil) {
                if let name = application.localizedName {
                    result["application_name"] = name
                }
                if let bundleId = application.bundleIdentifier {
                    result["bundle_identifier"] = bundleId
                }
            }
        }

        if let screenId, let screenDescriptor {
            result["screen_display_id"] = screenId
            result["screen"] = getScreenIndex(for: screenId)
            result["screen_name"] = screenDescriptor.localizedName
        }

        if let zoneIndex = managed.zoneIndex,
           let screenId = managed.screenDisplayId,
           let zone = screenContexts[screenId]?.zoneController.zone(at: zoneIndex) {
            result["zone_frame"] = [
                "x": zone.frame.origin.x,
                "y": zone.frame.origin.y,
                "width": zone.frame.width,
                "height": zone.frame.height
            ]
        }

        switch managed.backing {
        case .accessibility(_, _, let windowNumber?):
            result["window_number"] = windowNumber
        default:
            break
        }

        return result
    }

    func managedWindowsJSON() -> [String: Any] {
        let windows = windowController.allWindows
            .sorted { $0.windowId < $1.windowId }
            .map { managed -> [String: Any] in
                windowInfoJSON(windowId: managed.windowId)
            }

        var response: [String: Any] = ["windows": windows]

        if let targeted = targetedZoneKey,
           let descriptor = descriptor(for: targeted.screenId) {
            response["targeted_zone"] = [
                "screen_display_id": targeted.screenId,
                "screen": getScreenIndex(for: targeted.screenId) as Any,
                "screen_name": descriptor.localizedName,
                "index": targeted.index
            ]
        }

        return response
    }

    func validateApplicationJSON(pid: pid_t) -> [String: Any] {
        let prunedIds = validationRetryManager.validateWindowsForApplication(pid: pid, reason: "socket-request")
        return [
            "pid": Int(pid),
            "pruned_window_ids": prunedIds
        ]
    }

    func printFramesJSON() -> [String: Any] {
        let frames = windowController.allWindows.map { window -> [String: Any] in
            let type: String
            if window.isPlaceholder {
                type = "placeholder"
            } else {
                switch window.backing {
                case .appKit:
                    type = "test"
                case .accessibility:
                    type = "external"
                }
            }
            let screenId = window.screenDisplayId ?? detectScreenId(for: window)
            let screenDescriptor = screenId.flatMap { (id: CGDirectDisplayID) -> ScreenDescriptor? in
                descriptor(for: id)
            }
            let actualFrame: CGRect
            if let screenDescriptor {
                actualFrame = windowController.actualFrameInScreenCoordinates(for: window, on: screenDescriptor)
            } else if let fallback = windowController.actualFrameInScreenCoordinates(for: window) {
                actualFrame = fallback
            } else {
                actualFrame = .zero
            }
            var windowData: [String: Any] = [
                "window_id": window.windowId,
                "type": type,
                "is_placeholder": window.isPlaceholder,
                "screen_display_id": screenId as Any,
                "screen_name": screenDescriptor?.localizedName as Any,
                "frame": [
                    "x": actualFrame.origin.x,
                    "y": actualFrame.origin.y,
                    "width": actualFrame.width,
                    "height": actualFrame.height
                ]
            ]
            if let screenId = screenId {
                windowData["screen"] = getScreenIndex(for: screenId)
            }
            return windowData
        }
        return ["windows": frames]
    }
}