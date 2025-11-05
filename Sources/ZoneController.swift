import Foundation
import AppKit

/// Manages the zones and their assignments
class ZoneController {
    struct RemovalResult {
        let removedWindowId: Int?
    }

    private var zones: [Zone] = []
    private var layout = ZoneLayout()
    private var screenFrame: CGRect

    init(screenFrame: CGRect, initialZoneCount: Int = 1) {
        self.screenFrame = screenFrame
        initializeZones(count: initialZoneCount)
    }

    /// Update the underlying screen frame and recompute layout if it changed.
    func updateScreenFrame(_ newFrame: CGRect) {
        guard screenFrame != newFrame else {
            return
        }
        screenFrame = newFrame
        relayout()
    }

    private func initializeZones(count: Int) {
        let zoneCount = clampedZoneCount(count)
        let frames = layout.frames(for: zoneCount, screenFrame: screenFrame)
        zones = frames.enumerated().map { index, frame in
            Zone(index: index + 1, frame: frame)
        }
        Logger.debug("Initialized \(zoneCount) zone(s)")
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

    /// Force the number of zones to the specified count (clamped to 1...3).
    /// - Returns: Window IDs removed due to a reduction in zone count.
    @discardableResult
    func setZoneCount(to desiredCount: Int) -> [Int] {
        let clampedCount = clampedZoneCount(desiredCount)
        guard clampedCount != zones.count else {
            return []
        }

        let sortedZones = zones.sorted { $0.index < $1.index }
        var assignments: [Int?]
        var removedWindowIds: [Int] = []

        if clampedCount < sortedZones.count {
            assignments = sortedZones.prefix(clampedCount).map { $0.windowId }
            removedWindowIds = sortedZones.dropFirst(clampedCount).compactMap { $0.windowId }
        } else {
            assignments = sortedZones.map { $0.windowId }
            if clampedCount > assignments.count {
                assignments.append(contentsOf: Array(repeating: nil, count: clampedCount - assignments.count))
            }
        }

        recomputeLayout(zoneCount: clampedCount, preservingAssignments: assignments)
        Logger.debug("Adjusted zone count to \(clampedCount)")
        return removedWindowIds
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

    /// Find an empty zone with the highest index, or nil if none are empty
    func highestIndexEmptyZone() -> Zone? {
        return zones.filter { $0.isEmpty }.max(by: { $0.index < $1.index })
    }

    /// Find the zone with the highest index
    func highestIndexZone() -> Zone? {
        return zones.max(by: { $0.index < $1.index })
    }

    /// Resize an empty zone and adjust layout ratios accordingly.
    /// - Parameters:
    ///   - index: Zone index (1-based)
    ///   - newFrame: Requested frame for the zone (without margins)
    /// - Returns: true if resize was applied
    @discardableResult
    func resizeZone(at index: Int, to newFrame: CGRect, allowOccupied: Bool = false) -> Bool {
        guard let zone = zone(at: index) else {
            Logger.debug("Cannot resize zone: zone \(index) not found")
            return false
        }

        let wasOccupied = !zone.isEmpty
        if wasOccupied && !allowOccupied {
            Logger.debug("Cannot resize zone \(index): zone is occupied")
            return false
        }

        let sanitizedFrame = sanitizeFrame(newFrame)
        layout.resize(zoneIndex: index, zoneCount: zones.count, screenFrame: screenFrame, to: sanitizedFrame)

        let assignments = zones.sorted { $0.index < $1.index }.map { $0.windowId }
        recomputeLayout(zoneCount: zones.count, preservingAssignments: assignments)

        if wasOccupied {
            Logger.debug("Resized occupied zone \(index) using frame \(sanitizedFrame)")
        } else {
            Logger.debug("Resized zone \(index) using frame \(sanitizedFrame)")
        }
        return true
    }

    /// Recompute the layout for the current number of zones
    private func recomputeLayout(zoneCount: Int, preservingAssignments assignmentsParam: [Int?]? = nil) {
        let frames = layout.frames(for: zoneCount, screenFrame: screenFrame)

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

    /// Screen frame used for the layout. Useful for clamping zone adjustments.
    var layoutBounds: CGRect {
        return screenFrame
    }

    private func sanitizeFrame(_ frame: CGRect) -> CGRect {
        var standardized = frame.standardized

        let clampedOriginX = max(screenFrame.minX, standardized.origin.x)
        let clampedOriginY = max(screenFrame.minY, standardized.origin.y)
        let maxX = min(screenFrame.maxX, standardized.maxX)
        let maxY = min(screenFrame.maxY, standardized.maxY)

        standardized.origin = CGPoint(x: clampedOriginX, y: clampedOriginY)
        standardized.size.width = max(0, maxX - standardized.origin.x)
        standardized.size.height = max(0, maxY - standardized.origin.y)

        return standardized
    }

    private func clampedZoneCount(_ count: Int) -> Int {
        return max(1, min(3, count))
    }
}
