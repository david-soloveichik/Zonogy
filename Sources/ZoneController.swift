import Foundation
import AppKit

/// Manages the zones and their assignments
class ZoneController {
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
        recomputeLayout(zoneCount: newCount)
        Logger.debug("Added zone \(newCount)")
        return zones.last
    }

    /// Remove a zone at the specified index
    /// Returns true if successful, false if it's the last zone or zone is not empty
    func removeZone(at index: Int) -> Bool {
        guard zones.count > 1 else {
            Logger.debug("Cannot remove zone: must have at least 1 zone")
            return false
        }

        guard let targetZone = zone(at: index) else {
            Logger.debug("Cannot remove zone: zone \(index) not found")
            return false
        }

        guard targetZone.isEmpty else {
            Logger.debug("Cannot remove zone \(index): zone is not empty")
            return false
        }

        // Remove the zone
        zones.removeAll { $0.index == index }

        // Reindex and recompute layout
        let newCount = zones.count
        recomputeLayout(zoneCount: newCount)

        Logger.debug("Removed zone \(index), now have \(newCount) zone(s)")
        return true
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
    private func recomputeLayout(zoneCount: Int) {
        let frames = ZoneLayout.computeFrames(zoneCount: zoneCount, screenFrame: screenFrame)

        // Store the window assignments before reindexing
        var windowAssignments: [(windowId: Int, oldIndex: Int)] = []
        for zone in zones {
            if let windowId = zone.windowId {
                windowAssignments.append((windowId, zone.index))
            }
        }

        // Create new zones with updated indices and frames
        zones = frames.enumerated().map { index, frame in
            Zone(index: index + 1, frame: frame)
        }

        // Restore window assignments where possible (by matching old indices to new ones)
        for assignment in windowAssignments {
            // Try to keep windows in their same relative positions
            if assignment.oldIndex <= zones.count {
                zones[assignment.oldIndex - 1].windowId = assignment.windowId
            }
        }
    }

    /// Force a layout recalculation (useful after screen size changes)
    func relayout() {
        recomputeLayout(zoneCount: zones.count)
        Logger.debug("Relayout complete for \(zones.count) zone(s)")
    }
}
