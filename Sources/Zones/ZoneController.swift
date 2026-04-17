import Foundation
import AppKit

/// Manages the zones and their assignments.
/// Zones can contain external window occupants (tracked by windowId).
/// Placeholder windows are managed separately by PlaceholderCoordinator.
class ZoneController {
    struct RemovalResult {
        let removedWindowId: Int?
    }

    private var zones: [Zone] = []
    private var layout = ZoneLayout()
    private var screenFrame: CGRect

    init(screenFrame: CGRect, initialZoneCount: Int = 1) {
        self.screenFrame = screenFrame.standardized
        initializeZones(count: initialZoneCount)
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
        let occupants = zones.sorted { $0.index < $1.index }.map { $0.occupantWindowId } + [nil]
        recomputeLayout(zoneCount: newCount, preservingOccupants: occupants)
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
        let removedWindowId = removedZone.occupantWindowId

        let remainingOccupants = zones.sorted { $0.index < $1.index }.map { $0.occupantWindowId }
        let newCount = zones.count
        recomputeLayout(zoneCount: newCount, preservingOccupants: remainingOccupants)

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
        var occupants: [Int?]
        var removedWindowIds: [Int] = []

        if clampedCount < sortedZones.count {
            occupants = sortedZones.prefix(clampedCount).map { $0.occupantWindowId }
            removedWindowIds = sortedZones.dropFirst(clampedCount).compactMap { $0.occupantWindowId }
        } else {
            occupants = sortedZones.map { $0.occupantWindowId }
            if clampedCount > occupants.count {
                occupants.append(contentsOf: Array(repeating: nil, count: clampedCount - occupants.count))
            }
        }

        recomputeLayout(zoneCount: clampedCount, preservingOccupants: occupants)
        Logger.debug("Adjusted zone count to \(clampedCount)")
        return removedWindowIds
    }

    /// Replace the current tiling-zone topology with the provided occupant list.
    /// Each array element maps to the corresponding 1-based zone index.
    func replaceZones(withOccupants occupantWindowIds: [Int?]) {
        let requestedCount = clampedZoneCount(max(1, occupantWindowIds.count))
        let occupants = Array(occupantWindowIds.prefix(requestedCount))
            + Array(repeating: nil, count: max(0, requestedCount - occupantWindowIds.count))
        recomputeLayout(zoneCount: requestedCount, preservingOccupants: occupants)
        Logger.debug("Replaced zones with \(requestedCount) explicit occupant slot(s)")
    }

    /// Assign an external window to a zone.
    /// Only external windows (from other applications) can occupy zones.
    func assignWindow(windowId: Int, toZoneIndex zoneIndex: Int) {
        guard let zone = zone(at: zoneIndex) else {
            Logger.debug("Cannot assign window \(windowId): zone \(zoneIndex) not found")
            return
        }

        let wasEmpty = zone.isEmpty
        zone.occupantWindowId = windowId
        Logger.debug("Assigned window \(windowId) to zone \(zoneIndex)")
        if wasEmpty {
            Logger.debug("Zone \(zoneIndex) is now occupied")
        }
    }

    /// Remove a window from its zone
    func removeWindow(windowId: Int) {
        for zone in zones {
            if zone.occupantWindowId == windowId {
                zone.occupantWindowId = nil
                Logger.debug("Removed window \(windowId) from zone \(zone.index)")
                Logger.debug("Zone \(zone.index) is now empty")
                return
            }
        }
    }

    /// Find the zone that contains the specified window
    func zoneForWindow(windowId: Int) -> Zone? {
        return zones.first { $0.occupantWindowId == windowId }
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

        let occupants = zones.sorted { $0.index < $1.index }.map { $0.occupantWindowId }
        recomputeLayout(zoneCount: zones.count, preservingOccupants: occupants)

        if wasOccupied {
            Logger.debug("Resized occupied zone \(index) using frame \(sanitizedFrame)")
        } else {
            Logger.debug("Resized zone \(index) using frame \(sanitizedFrame)")
        }
        return true
    }

    /// Resize zones by dragging a separator
    func resizeBySeparator(index: Int, delta: CGFloat) {
        layout.resizeBySeparator(index: index, delta: delta, zoneCount: zones.count, screenFrame: screenFrame)
        let occupants = zones.sorted { $0.index < $1.index }.map { $0.occupantWindowId }
        recomputeLayout(zoneCount: zones.count, preservingOccupants: occupants)
        Logger.debug("Resized by separator \(index) delta \(delta)")
    }

    /// Recompute the layout for the current number of zones.
    /// Preserves occupant window IDs; PlaceholderCoordinator manages placeholders separately.
    private func recomputeLayout(zoneCount: Int, preservingOccupants occupantsParam: [Int?]? = nil) {
        let frames = layout.frames(for: zoneCount, screenFrame: screenFrame)

        let occupants: [Int?]
        if let provided = occupantsParam {
            occupants = provided
        } else {
            occupants = zones.sorted { $0.index < $1.index }.map { $0.occupantWindowId }
        }

        zones = frames.enumerated().map { index, frame in
            let occupantId = index < occupants.count ? occupants[index] : nil
            return Zone(index: index + 1, frame: frame, occupantWindowId: occupantId)
        }
    }

    func separators() -> [ZoneLayout.Separator] {
        return layout.separators(zoneCount: zones.count, screenFrame: screenFrame)
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

    /// Update the screen frame (e.g., when a monitor is resized) and relayout existing zones.
    func updateScreenFrame(_ newFrame: CGRect) {
        let standardized = newFrame.standardized
        guard !screenFrame.equalTo(standardized) else {
            return
        }

        screenFrame = standardized
        Logger.debug("ZoneController screen frame updated to \(standardized) - relayout \(zones.count) zone(s)")
        relayout()
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
