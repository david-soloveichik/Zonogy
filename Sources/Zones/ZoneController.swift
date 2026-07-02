import Foundation
import AppKit

/// Manages the zones and their assignments.
/// Zones can contain external window occupants (tracked by windowId).
/// Placeholder windows are managed separately by PlaceholderCoordinator.
///
/// Each zone carries the screen side it tiles on. Single-bar layout styles force sides by zone
/// index; the dual-bar style carries sides as state (which bar added each zone), repaired to
/// keep every side within capacity and two zones on one per side.
class ZoneController {
    struct RemovalResult {
        let removedWindowId: Int?
    }

    private var zones: [Zone] = []
    private var layout = ZoneLayout()
    private var screenFrame: CGRect
    private(set) var layoutStyle: ZoneLayoutStyle

    init(screenFrame: CGRect, initialZoneCount: Int = 1, layoutStyle: ZoneLayoutStyle = .rightBar) {
        self.screenFrame = screenFrame.standardized
        self.layoutStyle = layoutStyle
        let zoneCount = max(1, min(layoutStyle.maxZoneCount, initialZoneCount))
        recomputeLayout(
            sides: layoutStyle.canonicalSides(zoneCount: zoneCount),
            preservingOccupants: Array(repeating: nil, count: zoneCount)
        )
        Logger.debug("Initialized \(zoneCount) zone(s) with layout style \(layoutStyle.rawValue)")
    }

    /// Get all zones
    var allZones: [Zone] {
        return zones
    }

    /// Get zone by index (1-based)
    func zone(at index: Int) -> Zone? {
        return zones.first { $0.index == index }
    }

    private var currentSides: [ZoneSide] {
        zones.sorted { $0.index < $1.index }.map { $0.side }
    }

    private var currentOccupants: [Int?] {
        zones.sorted { $0.index < $1.index }.map { $0.occupantWindowId }
    }

    /// Number of zones currently on a side.
    func zoneCount(on side: ZoneSide) -> Int {
        zones.filter { $0.side == side }.count
    }

    /// True when a zone can be added on the given side (side capacity and total max permitting).
    /// A lone full-screen zone does not block either side: adding re-splits the screen.
    func canAddZone(on side: ZoneSide) -> Bool {
        guard zones.count < layoutStyle.maxZoneCount else {
            return false
        }
        if zones.count == 1 {
            return true
        }
        return zoneCount(on: side) < layoutStyle.sideCapacity(side)
    }

    /// Add a new zone, on `preferredSide` when given (an add-zone bar click), otherwise on the
    /// style's preferred side with remaining capacity.
    /// Returns the newly created zone, or nil if no capacity remains.
    func addZone(preferredSide: ZoneSide? = nil) -> Zone? {
        guard zones.count < layoutStyle.maxZoneCount else {
            Logger.debug("Cannot add zone: maximum of \(layoutStyle.maxZoneCount) zones reached")
            return nil
        }

        let side: ZoneSide
        if let preferredSide {
            guard canAddZone(on: preferredSide) else {
                Logger.debug("Cannot add zone: side \(preferredSide.rawValue) is full")
                return nil
            }
            side = preferredSide
        } else if let fallback = layoutStyle.preferredAddSideOrder.first(where: { canAddZone(on: $0) }) {
            side = fallback
        } else {
            Logger.debug("Cannot add zone: no side has remaining capacity")
            return nil
        }

        var sides = currentSides
        // Splitting a lone full-screen zone: the new zone takes the clicked side and the
        // existing zone takes the other, regardless of the side it nominally carried.
        if sides.count == 1 {
            sides = [side.opposite]
        }
        sides.append(side)

        recomputeLayout(sides: repairedSides(sides), preservingOccupants: currentOccupants + [nil])
        Logger.debug("Added zone \(zones.count) on side \(side.rawValue)")
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

        recomputeLayout(sides: repairedSides(currentSides), preservingOccupants: currentOccupants)

        Logger.debug("Removed zone \(index), now have \(zones.count) zone(s)")
        return RemovalResult(removedWindowId: removedWindowId)
    }

    /// Force the number of zones to the specified count (clamped to 1...max for the style).
    /// - Returns: Window IDs removed due to a reduction in zone count.
    @discardableResult
    func setZoneCount(to desiredCount: Int) -> [Int] {
        let clampedCount = max(1, min(layoutStyle.maxZoneCount, desiredCount))
        guard clampedCount != zones.count else {
            return []
        }

        let sortedZones = zones.sorted { $0.index < $1.index }
        var removedWindowIds: [Int] = []
        var occupants: [Int?]
        var sides: [ZoneSide]

        if clampedCount < sortedZones.count {
            occupants = sortedZones.prefix(clampedCount).map { $0.occupantWindowId }
            removedWindowIds = sortedZones.dropFirst(clampedCount).compactMap { $0.occupantWindowId }
            sides = repairedSides(Array(sortedZones.prefix(clampedCount).map { $0.side }))
        } else {
            occupants = sortedZones.map { $0.occupantWindowId }
                + Array(repeating: nil, count: clampedCount - sortedZones.count)
            sides = sortedZones.map { $0.side }
            while sides.count < clampedCount {
                let side = layoutStyle.preferredAddSideOrder.first { candidate in
                    sides.filter { $0 == candidate }.count < layoutStyle.sideCapacity(candidate)
                } ?? .right
                if sides.count == 1 {
                    sides = [side.opposite]
                }
                sides.append(side)
            }
            sides = repairedSides(sides)
        }

        recomputeLayout(sides: sides, preservingOccupants: occupants)
        Logger.debug("Adjusted zone count to \(clampedCount)")
        return removedWindowIds
    }

    /// Replace the current tiling-zone topology with the provided occupant list.
    /// Each array element maps to the corresponding 1-based zone index.
    func replaceZones(withOccupants occupantWindowIds: [Int?]) {
        let requestedCount = max(1, min(layoutStyle.maxZoneCount, max(1, occupantWindowIds.count)))
        let occupants = Array(occupantWindowIds.prefix(requestedCount))
            + Array(repeating: nil, count: max(0, requestedCount - occupantWindowIds.count))
        recomputeLayout(
            sides: layoutStyle.canonicalSides(zoneCount: requestedCount),
            preservingOccupants: occupants
        )
        Logger.debug("Replaced zones with \(requestedCount) explicit occupant slot(s)")
    }

    /// Switch to another layout style, re-tiling the current zones in place (occupants keep
    /// their indexes). Zones beyond the new style's maximum are dropped, highest index first.
    /// - Returns: Window IDs from dropped zones.
    @discardableResult
    func setLayoutStyle(_ newStyle: ZoneLayoutStyle) -> [Int] {
        guard newStyle != layoutStyle else {
            return []
        }
        layoutStyle = newStyle

        let sortedZones = zones.sorted { $0.index < $1.index }
        let keptCount = max(1, min(newStyle.maxZoneCount, sortedZones.count))
        let removedWindowIds = sortedZones.dropFirst(keptCount).compactMap { $0.occupantWindowId }
        let kept = sortedZones.prefix(keptCount)

        recomputeLayout(
            sides: repairedSides(kept.map { $0.side }),
            preservingOccupants: kept.map { $0.occupantWindowId }
        )
        Logger.debug("Switched layout style to \(newStyle.rawValue); \(zones.count) zone(s) retained")
        return removedWindowIds
    }

    /// Align dual-bar side assignments to saved zone frames (e.g. a WinShot snapshot), so a
    /// restored arrangement reproduces its columns. No-op for single-bar styles (sides are fixed)
    /// or when the frames don't describe a valid dual-bar arrangement.
    func alignSides(toSavedFrames framesByIndex: [Int: CGRect]) {
        guard layoutStyle == .dualBar, zones.count > 1 else {
            return
        }

        let sortedZones = zones.sorted { $0.index < $1.index }
        var inferred: [ZoneSide] = []
        for zone in sortedZones {
            guard let saved = framesByIndex[zone.index] else {
                return
            }
            inferred.append(saved.standardized.midX <= screenFrame.midX ? .left : .right)
        }

        let repaired = repairedSides(inferred)
        guard repaired == inferred, inferred != currentSides else {
            return
        }
        recomputeLayout(sides: inferred, preservingOccupants: currentOccupants)
        Logger.debug("Aligned zone sides to saved frames: \(inferred.map(\.rawValue))")
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
        layout.resize(zoneIndex: index, sides: currentSides, screenFrame: screenFrame, to: sanitizedFrame)

        recomputeLayout(sides: currentSides, preservingOccupants: currentOccupants)

        if wasOccupied {
            Logger.debug("Resized occupied zone \(index) using frame \(sanitizedFrame)")
        } else {
            Logger.debug("Resized zone \(index) using frame \(sanitizedFrame)")
        }
        return true
    }

    /// Resize zones by dragging a separator
    func resizeBySeparator(id: ZoneLayout.SeparatorIdentity, delta: CGFloat) {
        layout.resizeBySeparator(id: id, delta: delta, screenFrame: screenFrame)
        recomputeLayout(sides: currentSides, preservingOccupants: currentOccupants)
        Logger.debug("Resized by separator \(id.logLabel) delta \(delta)")
    }

    /// Repair a side assignment so it is valid for the current style: single-bar styles use
    /// their fixed sides; dual-bar keeps carried sides but re-tiles two same-side survivors to
    /// one per side (in index order) and falls back to canonical sides for degenerate states.
    private func repairedSides(_ proposed: [ZoneSide]) -> [ZoneSide] {
        if let fixed = layoutStyle.fixedSides(zoneCount: proposed.count) {
            return fixed
        }
        guard proposed.count > 1 else {
            return layoutStyle.canonicalSides(zoneCount: max(1, proposed.count))
        }

        let leftCount = proposed.filter { $0 == .left }.count
        let rightCount = proposed.count - leftCount

        if proposed.count == 2, leftCount != 1 {
            return [.left, .right]
        }
        if leftCount == 0 || rightCount == 0
            || leftCount > layoutStyle.sideCapacity(.left)
            || rightCount > layoutStyle.sideCapacity(.right) {
            return layoutStyle.canonicalSides(zoneCount: proposed.count)
        }
        return proposed
    }

    /// Recompute zone frames for the given sides, preserving occupant window IDs by position.
    /// PlaceholderCoordinator manages placeholders separately.
    private func recomputeLayout(sides: [ZoneSide], preservingOccupants occupants: [Int?]) {
        let frames = layout.frames(sides: sides, screenFrame: screenFrame)

        zones = frames.enumerated().map { index, frame in
            let occupantId = index < occupants.count ? occupants[index] : nil
            return Zone(index: index + 1, frame: frame, side: sides[index], occupantWindowId: occupantId)
        }
    }

    func separators() -> [ZoneLayout.Separator] {
        return layout.separators(sides: currentSides, screenFrame: screenFrame)
    }

    /// Force a layout recalculation (useful after screen size changes)
    func relayout() {
        recomputeLayout(sides: currentSides, preservingOccupants: currentOccupants)
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
}
