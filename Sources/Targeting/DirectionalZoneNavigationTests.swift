import CoreGraphics

/// Guardrail assertions for the pure 2D arrow-key target navigation geometry.
///
/// All frames are in the shared global coordinate space (y increases downward), mirroring the
/// accessibility coordinates AppController feeds the navigator at runtime.
enum DirectionalZoneNavigationTests {
    private static let screenA: CGDirectDisplayID = 10
    private static let screenB: CGDirectDisplayID = 20

    /// Standard 1500×1000 screen: zone 1 = left full height, zone 2 = right-top, zone 3 =
    /// right-bottom, floating = centered bottom bar.
    private static func standardScreen(_ id: CGDirectDisplayID, originX: CGFloat, originY: CGFloat) -> [NavigableZone] {
        [
            NavigableZone(id: .tiling(screenId: id, index: 1),
                          frame: CGRect(x: originX, y: originY, width: 750, height: 1000)),
            NavigableZone(id: .tiling(screenId: id, index: 2),
                          frame: CGRect(x: originX + 750, y: originY, width: 750, height: 500)),
            NavigableZone(id: .tiling(screenId: id, index: 3),
                          frame: CGRect(x: originX + 750, y: originY + 500, width: 750, height: 500)),
            NavigableZone(id: .floating(screenId: id),
                          frame: CGRect(x: originX + 500, y: originY + 994, width: 500, height: 6)),
        ]
    }

    @discardableResult
    static func run() -> Bool {
        var allPassed = true

        func describe(_ id: NavigableZoneIdentifier?) -> String {
            switch id {
            case nil: return "nil"
            case let .tiling(screenId, index): return "tiling(screen: \(screenId), index: \(index))"
            case let .floating(screenId): return "floating(screen: \(screenId))"
            }
        }

        func assertNext(
            _ zones: [NavigableZone],
            from: NavigableZoneIdentifier,
            _ direction: ZoneNavigationDirection,
            equals expected: NavigableZoneIdentifier?,
            _ label: String
        ) {
            let actual = DirectionalZoneNavigation.nextZone(from: from, direction: direction, among: zones)
            if actual != expected {
                print("DirectionalZoneNavigationTests: \(label) failed\n  expected: \(describe(expected))\n  actual:   \(describe(actual))")
                allPassed = false
            }
        }

        let tiling1 = NavigableZoneIdentifier.tiling(screenId: screenA, index: 1)
        let tiling2 = NavigableZoneIdentifier.tiling(screenId: screenA, index: 2)
        let tiling3 = NavigableZoneIdentifier.tiling(screenId: screenA, index: 3)
        let floatingA = NavigableZoneIdentifier.floating(screenId: screenA)

        // MARK: Single screen — within-zone 2D moves.
        do {
            let zones = standardScreen(screenA, originX: 0, originY: 0)
            // Down walks the right column top→bottom, then to the floating bar.
            assertNext(zones, from: tiling2, .down, equals: tiling3, "single: down zone2→zone3")
            assertNext(zones, from: tiling3, .down, equals: floatingA, "single: down zone3→floating")
            assertNext(zones, from: tiling1, .down, equals: floatingA, "single: down zone1→floating")
            // Up returns from the floating bar to the tiling layer.
            assertNext(zones, from: floatingA, .up, equals: tiling1, "single: up floating→zone1")
            assertNext(zones, from: tiling3, .up, equals: tiling2, "single: up zone3→zone2")
            // Left/Right across the column boundary.
            assertNext(zones, from: tiling1, .right, equals: tiling2, "single: right zone1→zone2")
            assertNext(zones, from: tiling2, .left, equals: tiling1, "single: left zone2→zone1")
            assertNext(zones, from: tiling3, .left, equals: tiling1, "single: left zone3→zone1")
            // Edges of the lone screen stop (no wrap).
            assertNext(zones, from: tiling2, .right, equals: nil, "single: right zone2→edge")
            assertNext(zones, from: tiling1, .left, equals: nil, "single: left zone1→edge")
            assertNext(zones, from: tiling2, .up, equals: nil, "single: up zone2→edge")
            assertNext(zones, from: floatingA, .left, equals: nil, "single: left floating→edge")
            assertNext(zones, from: floatingA, .right, equals: nil, "single: right floating→edge")
            assertNext(zones, from: floatingA, .down, equals: nil, "single: down floating→edge")
        }

        // MARK: Two screens side by side (B to the right of A).
        do {
            let zones = standardScreen(screenA, originX: 0, originY: 0)
                + standardScreen(screenB, originX: 1500, originY: 0)
            let bTiling1 = NavigableZoneIdentifier.tiling(screenId: screenB, index: 1)
            let bTiling2 = NavigableZoneIdentifier.tiling(screenId: screenB, index: 2)
            let floatingB = NavigableZoneIdentifier.floating(screenId: screenB)
            // Same-screen neighbor wins over the next display.
            assertNext(zones, from: tiling1, .right, equals: tiling2, "horizontal: right stays on A (zone1→zone2)")
            // Leaving A's right column lands on B's nearest (left) column.
            assertNext(zones, from: tiling2, .right, equals: bTiling1, "horizontal: right A.zone2→B.zone1")
            assertNext(zones, from: tiling3, .right, equals: bTiling1, "horizontal: right A.zone3→B.zone1")
            // And back the other way.
            assertNext(zones, from: bTiling1, .left, equals: tiling2, "horizontal: left B.zone1→A.zone2")
            assertNext(zones, from: bTiling1, .right, equals: bTiling2, "horizontal: right stays on B (zone1→zone2)")
            // Horizontal floating-zone navigation stays in the floating layer.
            assertNext(zones, from: floatingA, .right, equals: floatingB, "horizontal: right A.floating→B.floating")
            assertNext(zones, from: floatingB, .left, equals: floatingA, "horizontal: left B.floating→A.floating")
        }

        // MARK: Two screens stacked vertically (B directly below A).
        do {
            let zones = standardScreen(screenA, originX: 0, originY: 0)
                + standardScreen(screenB, originX: 0, originY: 1000)
            let bTiling1 = NavigableZoneIdentifier.tiling(screenId: screenB, index: 1)
            let bTiling2 = NavigableZoneIdentifier.tiling(screenId: screenB, index: 2)
            // Down chains through A's own floating bar before crossing to B (same-screen-first).
            assertNext(zones, from: tiling1, .down, equals: floatingA, "stack: down A.zone1→A.floating")
            assertNext(zones, from: tiling3, .down, equals: floatingA, "stack: down A.zone3→A.floating")
            // A second Down from the floating bar crosses to the screen below.
            assertNext(zones, from: floatingA, .down, equals: bTiling1, "stack: down A.floating→B.zone1")
            // Up from below reaches the upper screen's nearest aligned zone.
            assertNext(zones, from: bTiling2, .up, equals: tiling3, "stack: up B.zone2→A.zone3")
        }

        // MARK: Diagonally-placed screen stays reachable via the cone fallback.
        do {
            let nodeA = NavigableZone(id: .tiling(screenId: screenA, index: 1),
                                      frame: CGRect(x: 0, y: 0, width: 100, height: 100))
            let nodeB = NavigableZone(id: .tiling(screenId: screenB, index: 1),
                                      frame: CGRect(x: 200, y: 200, width: 100, height: 100))
            let zones = [nodeA, nodeB]
            assertNext(zones, from: nodeA.id, .right, equals: nodeB.id, "diagonal: right A→B (fallback)")
            assertNext(zones, from: nodeA.id, .down, equals: nodeB.id, "diagonal: down A→B (fallback)")
            assertNext(zones, from: nodeB.id, .left, equals: nodeA.id, "diagonal: left B→A (fallback)")
        }

        // MARK: Unknown current zone yields no move.
        do {
            let zones = standardScreen(screenA, originX: 0, originY: 0)
            let phantom = NavigableZoneIdentifier.tiling(screenId: 999, index: 1)
            assertNext(zones, from: phantom, .right, equals: nil, "phantom current → nil")
        }

        if allPassed {
            print("DirectionalZoneNavigationTests: all tests passed")
        }
        return allPassed
    }
}
