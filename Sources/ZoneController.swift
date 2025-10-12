import Foundation
import AppKit

/// Manages the zones and their assignments
class ZoneController {
    struct RemovalResult {
        let removedWindowId: Int?
    }

    private var zones: [Zone] = []
    private let screenFrame: CGRect

    init(screenFrame: CGRect) {
        self.screenFrame = screenFrame
        // Start with 1 empty zone
        initializeZones(count: 1)
    }

    private func initializeZones(count: Int) {
        let frames = ZoneLayout.computeFrames(zoneCount: count, screenFrame: screenFrame)
        zones = frames.enumerated().map { index, frame in
            Zone(index: index + 1, frame: frame)
        }
        Logger.debug("Initialized \(count) zone(s)")
    }

    /// Get all zones
    var allZones: [Zone] {
        return zones
    }

    /// Get zone by index (1-based)
    func zone(at index: Int) -> Zone? {
        return zones.first { $0.index == index }
    }

    /// Add a new zone (up to max of 3)
    /// Returns the newly created zone, or nil if max reached
    func addZone() -> Zone? {
        guard zones.count < 3 else {
            Logger.debug("Cannot add zone: maximum of 3 zones reached")
            return nil
        }

        let newCount = zones.count + 1
        let assignments = zones.sorted { $0.index < $1.index }.map { $0.windowId } + [nil]
        recomputeLayout(zoneCount: newCount, preservingAssignments: assignments)
        Logger.debug("Added zone \(newCount)")
        return zones.last
    }

    /// Remove a zone at the specified index
    /// Returns removal metadata (including the window ID if any), or nil on failure
    func removeZone(at index: Int) -> RemovalResult? {
        guard zones.count > 1 else {
            Logger.debug("Cannot remove zone: must have at least 1 zone")
            return nil
        }

        guard let arrayIndex = zones.firstIndex(where: { $0.index == index }) else {
            Logger.debug("Cannot remove zone: zone \(index) not found")
            return nil
        }

        let removedZone = zones.remove(at: arrayIndex)
        let removedWindowId = removedZone.windowId

        let remainingAssignments = zones.sorted { $0.index < $1.index }.map { $0.windowId }
        let newCount = zones.count
        recomputeLayout(zoneCount: newCount, preservingAssignments: remainingAssignments)

        Logger.debug("Removed zone \(index), now have \(newCount) zone(s)")
        return RemovalResult(removedWindowId: removedWindowId)
    }

    /// Assign a window to a zone
    func assignWindow(windowId: Int, toZoneIndex zoneIndex: Int) {
        guard let zone = zone(at: zoneIndex) else {
            Logger.debug("Cannot assign window \(windowId): zone \(zoneIndex) not found")
            return
        }

        zone.windowId = windowId
        Logger.debug("Assigned window \(windowId) to zone \(zoneIndex)")
    }

    /// Remove a window from its zone
    func removeWindow(windowId: Int) {
        for zone in zones {
            if zone.windowId == windowId {
                zone.windowId = nil
                Logger.debug("Removed window \(windowId) from zone \(zone.index)")
                return
            }
        }
    }

    /// Find the zone that contains the specified window
    func zoneForWindow(windowId: Int) -> Zone? {
        return zones.first { $0.windowId == windowId }
    }

    /// Find an empty zone with the lowest index, or nil if all zones are occupied
    func findEmptyZone() -> Zone? {
        return zones.first { $0.isEmpty }
    }

    /// Find the zone with the highest index
    func highestIndexZone() -> Zone? {
        return zones.max(by: { $0.index < $1.index })
    }

    /// Recompute the layout for the current number of zones
    private func recomputeLayout(zoneCount: Int, preservingAssignments assignmentsParam: [Int?]? = nil) {
        let frames = ZoneLayout.computeFrames(zoneCount: zoneCount, screenFrame: screenFrame)

        let assignments: [Int?]
        if let provided = assignmentsParam {
            assignments = provided
        } else {
            assignments = zones.sorted { $0.index < $1.index }.map { $0.windowId }
        }

        zones = frames.enumerated().map { index, frame in
            let windowId = index < assignments.count ? assignments[index] : nil
            return Zone(index: index + 1, frame: frame, windowId: windowId)
        }
    }

    /// Force a layout recalculation (useful after screen size changes)
    func relayout() {
        recomputeLayout(zoneCount: zones.count)
        Logger.debug("Relayout complete for \(zones.count) zone(s)")
    }
}
