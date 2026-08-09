import CoreGraphics

/// Guardrail assertions for the pure zone-navigation selection policy.
///
/// Frames are in the shared global coordinate space (y increases downward), mirroring the
/// accessibility coordinates AppController feeds the navigator at runtime.
///
/// Fixture: screen A holds a 2×2 grid of tiling zones (zones 1–4: 1 top-left filled, 2 top-right
/// filled, 3 bottom-left EMPTY, 4 bottom-right filled) plus a filled floating zone sitting
/// concentric over the grid. Screen B sits to the right with one empty tiling zone and an empty
/// floating zone at its bottom-edge bar. The overlapping filled float is the case the pass-through
/// rules exist for: it is the first stop in a direction that crosses it, and pressing on moves
/// relative to where it was entered from. The bar is spatially disjoint, so it navigates like any
/// other zone.
enum ZoneNavigationTests {
    private static let screenA: CGDirectDisplayID = 10
    private static let screenB: CGDirectDisplayID = 20

    private static func tiledZone(
        _ index: Int, _ frame: CGRect, on screenId: CGDirectDisplayID = screenA, occupant: Int? = nil
    ) -> ZoneNavigation.Candidate {
        .init(id: .tiling(screenId: screenId, index: index), frame: frame, occupantWindowId: occupant)
    }

    private static func floatingZone(
        _ frame: CGRect, on screenId: CGDirectDisplayID = screenA, occupant: Int? = nil
    ) -> ZoneNavigation.Candidate {
        .init(id: .floating(screenId: screenId), frame: frame, occupantWindowId: occupant)
    }

    private static let z1 = tiledZone(1, CGRect(x: 0, y: 0, width: 480, height: 480), occupant: 1)
    private static let z2 = tiledZone(2, CGRect(x: 520, y: 0, width: 480, height: 480), occupant: 2)
    private static let z3 = tiledZone(3, CGRect(x: 0, y: 520, width: 480, height: 480))
    private static let z4 = tiledZone(4, CGRect(x: 520, y: 520, width: 480, height: 480), occupant: 4)
    private static let floatA = floatingZone(CGRect(x: 250, y: 250, width: 500, height: 500), occupant: 5)

    private static let zB1 = tiledZone(1, CGRect(x: 1000, y: 0, width: 1000, height: 940), on: screenB)
    private static let barB = floatingZone(CGRect(x: 1300, y: 1060, width: 400, height: 16), on: screenB)

    private static let singleScreen = [z1, z2, z3, z4, floatA]
    private static let twoScreens = [z1, z2, z3, z4, floatA, zB1, barB]

    @discardableResult
    static func run() -> Bool {
        var allPassed = true

        func assertSel(_ actual: ZoneNavigation.Selection?, _ expected: NavigableZoneIdentifier?, _ label: String) {
            if actual?.id != expected {
                print("ZoneNavigationTests: \(label) failed\n  expected: \(expected.map { String(describing: $0) } ?? "nil")\n  actual:   \(actual.map { String(describing: $0.id) } ?? "nil")")
                allPassed = false
            }
        }

        // A nil direction asserts the selection has no entry at all (Entry.direction is non-optional).
        func assertEntry(
            _ actual: ZoneNavigation.Selection?,
            sourceId: NavigableZoneIdentifier?,
            direction: ZoneNavigationDirection?,
            _ label: String
        ) {
            if actual?.entry?.sourceId != sourceId || actual?.entry?.direction != direction {
                print("ZoneNavigationTests: \(label) failed\n  expected entry: source \(sourceId.map { String(describing: $0) } ?? "nil"), direction \(direction.map { String(describing: $0) } ?? "nil")\n  actual entry:   source \(actual?.entry?.sourceId.map { String(describing: $0) } ?? "nil"), direction \(actual?.entry.map { String(describing: $0.direction) } ?? "nil")")
                allPassed = false
            }
        }

        func anchor(at candidate: ZoneNavigation.Candidate) -> ZoneNavigation.Anchor {
            .init(frame: candidate.frame, screenId: candidate.id.screenId)
        }

        func initial(
            _ direction: ZoneNavigationDirection,
            focused: ZoneNavigation.Candidate? = nil,
            targeted: ZoneNavigation.Candidate? = nil,
            candidates: [ZoneNavigation.Candidate] = singleScreen
        ) -> ZoneNavigation.Selection? {
            ZoneNavigation.initialSelection(
                direction: direction,
                focusedZoneId: focused?.id,
                targetedZoneId: targeted?.id,
                fallbackAnchor: candidates.first.map(anchor(at:)),
                candidates: candidates
            )
        }

        func next(
            _ direction: ZoneNavigationDirection,
            from selection: ZoneNavigation.Selection?,
            anchor: ZoneNavigation.Anchor,
            candidates: [ZoneNavigation.Candidate] = singleScreen
        ) -> ZoneNavigation.Selection? {
            ZoneNavigation.nextSelection(
                direction: direction,
                currentSelection: selection,
                anchor: anchor,
                candidates: candidates
            )
        }

        // MARK: The overlapping filled float is the first stop of any crossing, and a directional
        // arrival records its source zone as the entry — including from an empty source zone.
        let upFromZ4 = initial(.up, focused: z4)
        assertSel(upFromZ4, floatA.id, "cross: up z4→float")
        assertEntry(upFromZ4, sourceId: z4.id, direction: .up, "cross: up z4→float records entry")
        let upFromEmptyZ3 = initial(.up, targeted: z3)
        assertSel(upFromEmptyZ3, floatA.id, "empty target: up z3→float (moves immediately)")
        assertEntry(upFromEmptyZ3, sourceId: z3.id, direction: .up, "empty target: entry records the empty source zone")

        // MARK: Continuing in the entry direction passes beyond the float, remembering the column
        // or row it was entered from; perpendicular presses move relative to the entry; reversing
        // backs out to the entry zone (clearing the entry) — even when that zone is empty.
        assertSel(next(.up, from: upFromZ4, anchor: anchor(at: z4)), z2.id, "pass-through: z4→float→up→z2")
        assertSel(next(.up, from: upFromEmptyZ3, anchor: anchor(at: z3)), z1.id, "pass-through: z3→float→up→z1")
        assertSel(next(.right, from: upFromEmptyZ3, anchor: anchor(at: z3)), z4.id, "perpendicular: z3→float→right→z4")
        let reversed = next(.down, from: upFromEmptyZ3, anchor: anchor(at: z3))
        assertSel(reversed, z3.id, "reverse: z3→float→down backs out to empty z3")
        assertEntry(reversed, sourceId: nil, direction: nil, "reverse: backing out clears the entry")

        // MARK: No focus, filled targeted zone — the first press selects it in place (any direction),
        // and moving on navigates from its own rectangle.
        let selectedTarget = initial(.left, targeted: z2)
        assertSel(selectedTarget, z2.id, "filled target: first press selects z2 in place")
        assertEntry(selectedTarget, sourceId: nil, direction: nil, "filled target: selecting records no entry")
        assertSel(next(.left, from: selectedTarget, anchor: anchor(at: z2)), floatA.id, "selected target: left → float (overlap wins)")

        // MARK: A float selected without a directional entry navigates from its own rectangle;
        // exact ties prefer the lower zone index.
        assertSel(next(.up, from: ZoneNavigation.Selection(id: floatA.id, entry: nil), anchor: anchor(at: floatA)), z1.id, "entry-less float: up → z1 (zone tie-break)")

        // MARK: Empty zones are first-class stops: cross-screen moves reach them.
        assertSel(initial(.right, focused: z4, candidates: twoScreens), zB1.id, "cross-screen: right z4→empty zB1")

        // MARK: The empty floating bar is reached from above, records no entry (it is spatially
        // disjoint), and navigates back from its own rectangle.
        let downToBar = initial(.down, targeted: zB1, candidates: twoScreens)
        assertSel(downToBar, barB.id, "bar: down zB1→bar")
        assertEntry(downToBar, sourceId: nil, direction: nil, "bar: empty floating records no entry")
        assertSel(next(.up, from: downToBar, anchor: anchor(at: zB1), candidates: twoScreens), zB1.id, "bar: up bar→zB1")

        // MARK: A dead first press selects nothing; later presses still move from the anchor.
        let deadRight = initial(.right, targeted: zB1, candidates: twoScreens)
        assertSel(deadRight, nil, "dead direction: right of zB1 selects nothing")
        assertSel(next(.left, from: deadRight, anchor: anchor(at: zB1), candidates: twoScreens), z2.id, "anchor recovery: left from zB1 anchor → z2")

        // MARK: Exact geometric ties prefer a tiling zone over the floating zone, then the lower
        // zone index.
        let tieSource = tiledZone(1, CGRect(x: 0, y: 0, width: 100, height: 100))
        let tieTiledLow = tiledZone(2, CGRect(x: 200, y: 0, width: 100, height: 100))
        let tieTiledHigh = tiledZone(3, CGRect(x: 200, y: 0, width: 100, height: 100))
        let tieFloat = floatingZone(CGRect(x: 200, y: 0, width: 100, height: 100), occupant: 9)
        assertSel(
            initial(.right, targeted: tieSource, candidates: [tieSource, tieFloat, tieTiledHigh, tieTiledLow]),
            tieTiledLow.id,
            "tie-break: tiled beats floating, lower index beats higher"
        )

        // MARK: No zones — nothing is selectable.
        assertSel(initial(.right, candidates: []), nil, "empty candidates → nil")

        if allPassed {
            print("ZoneNavigationTests: all tests passed")
        }
        return allPassed
    }
}
