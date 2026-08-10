import CoreGraphics

/// Guardrail assertions for the pure zone-navigation selection policy.
///
/// Frames are in the shared global coordinate space (y increases downward), mirroring the
/// accessibility coordinates AppController feeds the navigator at runtime.
///
/// Fixture: screen A holds a 2×2 grid of tiling zones (zones 1–4: 1 top-left filled, 2 top-right
/// filled, 3 bottom-left EMPTY, 4 bottom-right filled) plus its floating zone's bottom-edge bar,
/// occupied and clear of the grid (a bottom-Dock layout). Screen B sits to the right with one
/// empty tiling zone and an empty floating bar. Local fixtures cover the grazing-bar layouts
/// (hidden/side Dock), a screen stacked above, and the reported gesture annoyances, plus the
/// Add Zone key's side preference and the reselection after the Remove Zone key.
enum ZoneNavigationTests {
    private static let screenA: CGDirectDisplayID = 10
    private static let screenB: CGDirectDisplayID = 20
    private static let screenT: CGDirectDisplayID = 30
    private static let screenU: CGDirectDisplayID = 40

    private static func tiledZone(
        _ index: Int, _ frame: CGRect, on screenId: CGDirectDisplayID = screenA, occupied: Bool = false
    ) -> ZoneNavigation.Candidate {
        .init(id: .tiling(screenId: screenId, index: index), frame: frame, isOccupied: occupied)
    }

    private static func floatingZone(
        _ frame: CGRect, on screenId: CGDirectDisplayID = screenA, occupied: Bool = false
    ) -> ZoneNavigation.Candidate {
        .init(id: .floating(screenId: screenId), frame: frame, isOccupied: occupied)
    }

    private static let z1 = tiledZone(1, CGRect(x: 0, y: 0, width: 480, height: 480), occupied: true)
    private static let z2 = tiledZone(2, CGRect(x: 520, y: 0, width: 480, height: 480), occupied: true)
    private static let z3 = tiledZone(3, CGRect(x: 0, y: 520, width: 480, height: 480))
    private static let z4 = tiledZone(4, CGRect(x: 520, y: 520, width: 480, height: 480), occupied: true)
    private static let barA = floatingZone(CGRect(x: 300, y: 1044, width: 400, height: 16), occupied: true)

    private static let zB1 = tiledZone(1, CGRect(x: 1000, y: 0, width: 1000, height: 940), on: screenB)
    private static let barB = floatingZone(CGRect(x: 1300, y: 1060, width: 400, height: 16), on: screenB)

    private static let singleScreen = [z1, z2, z3, z4, barA]
    private static let twoScreens = [z1, z2, z3, z4, barA, zB1, barB]

    @discardableResult
    static func run() -> Bool {
        var allPassed = true

        func assertSel(_ actual: ZoneNavigation.Selection?, _ expected: NavigableZoneIdentifier?, _ label: String) {
            if actual?.id != expected {
                print("ZoneNavigationTests: \(label) failed\n  expected: \(expected.map { String(describing: $0) } ?? "nil")\n  actual:   \(actual.map { String(describing: $0.id) } ?? "nil")")
                allPassed = false
            }
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
                fallbackZoneId: candidates.first?.id,
                candidates: candidates
            )
        }

        func next(
            _ direction: ZoneNavigationDirection,
            from selection: ZoneNavigation.Selection?,
            candidates: [ZoneNavigation.Candidate] = singleScreen
        ) -> ZoneNavigation.Selection? {
            guard let selection else { return nil }
            return ZoneNavigation.nextSelection(
                direction: direction,
                currentSelection: selection,
                candidates: candidates
            )
        }

        func selected(_ candidate: ZoneNavigation.Candidate) -> ZoneNavigation.Selection {
            .init(id: candidate.id, trail: [])
        }

        // MARK: The occupied bar is a first-class vertical stop below the grid: down from a bottom
        // zone reaches it (filled or empty source alike), and up climbs back out — an exactly
        // centered bar ties between the bottom zones and the lower index wins.
        assertSel(initial(.down, focused: z4), barA.id, "down z4→occupied bar")
        assertSel(initial(.down, targeted: z3), barA.id, "empty target: down z3→bar (moves immediately)")
        assertSel(next(.up, from: selected(barA)), z3.id, "up bar→z3 (equidistant tie prefers lower index)")

        // MARK: The motivating degenerate case: one tiling zone spanning the screen plus an
        // occupied floating zone. The bar keeps the two mutually reachable even though the
        // occupant window itself may sit concentric with the zone (where no direction is
        // "ahead"). The bar here grazes the zone's bottom edge — the hidden/side-Dock layout,
        // where the visible area reaches the true screen bottom — and overlap still resolves
        // vertically (it clamps the travel gap to zero; it does not disqualify).
        let soloZone = tiledZone(1, CGRect(x: 0, y: 0, width: 1000, height: 1000), occupied: true)
        let soloBar = floatingZone(CGRect(x: 300, y: 994, width: 400, height: 16), occupied: true)
        let solo = [soloZone, soloBar]
        assertSel(initial(.down, focused: soloZone, candidates: solo), soloBar.id, "solo: down zone→occupied bar")
        assertSel(initial(.up, focused: soloBar, candidates: solo), soloZone.id, "solo: up from focused float→zone")

        // MARK: Horizontal presses never land on a bar — even one that grazes the zone frames and
        // would otherwise win the race outright (zero gap against the neighbor's margin gap) —
        // and the trail makes the return press retrace exactly, where raw geometry would tie
        // toward the lower zone index. Layout: full-height left zone, two stacked right zones,
        // grazing occupied bar.
        let lrL1 = tiledZone(1, CGRect(x: 0, y: 0, width: 480, height: 1000), occupied: true)
        let lrR2 = tiledZone(2, CGRect(x: 520, y: 0, width: 480, height: 480), occupied: true)
        let lrR3 = tiledZone(3, CGRect(x: 520, y: 520, width: 480, height: 480), occupied: true)
        let lrBar = floatingZone(CGRect(x: 300, y: 994, width: 400, height: 16), occupied: true)
        let lr = [lrL1, lrR2, lrR3, lrBar]
        let lrLeft = initial(.left, focused: lrR3, candidates: lr)
        assertSel(lrLeft, lrL1.id, "left from bottom-right → the zone, never the grazing bar")
        assertSel(initial(.down, focused: lrR3, candidates: lr), lrBar.id, "down from bottom-right → the bar")
        assertSel(next(.right, from: lrLeft, candidates: lr), lrR3.id, "reverse press returns to the start zone")
        assertSel(next(.right, from: selected(lrL1), candidates: lr), lrR2.id, "without a trail, right from the left column ties to the lower index")
        let lrDown = next(.down, from: lrLeft, candidates: lr)
        assertSel(lrDown, lrBar.id, "trail: left then down reaches the bar")
        let lrBack1 = next(.up, from: lrDown, candidates: lr)
        assertSel(lrBack1, lrL1.id, "trail: first reverse pops to the left zone")
        assertSel(next(.right, from: lrBack1, candidates: lr), lrR3.id, "trail: second reverse pops to the start")
        let lrDead = next(.left, from: lrLeft, candidates: lr)
        assertSel(lrDead, lrL1.id, "dead press keeps the selection…")
        assertSel(next(.right, from: lrDead, candidates: lr), lrR3.id, "…and keeps the trail: the reverse still pops")

        // MARK: Moves across the grid are direct — the floating occupant never sits between zones
        // (it navigates at the bar, not at its window rectangle).
        assertSel(initial(.up, focused: z4), z2.id, "grid: up z4→z2 is direct")

        // MARK: No focus, filled targeted zone — the first press selects it in place (any
        // direction). An occupied floating target works the same, so tap-and-release focuses the
        // floating window. Moving off a selected target is reversible like any other move.
        let selectedTarget = initial(.left, targeted: z2)
        assertSel(selectedTarget, z2.id, "filled target: first press selects z2 in place")
        assertSel(initial(.up, targeted: barA), barA.id, "occupied floating target: selected in place")
        let offTarget = next(.left, from: selectedTarget)
        assertSel(offTarget, z1.id, "selected target: left → z1")
        assertSel(next(.right, from: offTarget), z2.id, "selected target: reverse returns")

        // MARK: Empty zones are first-class stops: cross-screen moves reach them.
        assertSel(initial(.right, focused: z4, candidates: twoScreens), zB1.id, "cross-screen: right z4→empty zB1")

        // MARK: The empty floating bar is the same vertical stop: reached from above, and the
        // reverse press pops back out.
        let downToBar = initial(.down, targeted: zB1, candidates: twoScreens)
        assertSel(downToBar, barB.id, "bar: down zB1→empty bar")
        assertSel(next(.up, from: downToBar, candidates: twoScreens), zB1.id, "bar: up pops back to zB1")

        // MARK: Entering a screen from below lands on its bar first — the bar is that screen's
        // bottom-most vertical stop — and the next press continues into its zones.
        let zT = tiledZone(1, CGRect(x: 0, y: -1060, width: 1000, height: 940), on: screenT)
        let barT = floatingZone(CGRect(x: 300, y: -16, width: 400, height: 16), on: screenT)
        let stacked = [z1, z2, z3, z4, barA, zT, barT]
        let upToBarT = initial(.up, focused: z1, candidates: stacked)
        assertSel(upToBarT, barT.id, "stacked screens: up from below lands on the upper bar")
        assertSel(next(.up, from: upToBarT, candidates: stacked), zT.id, "stacked screens: up again continues into the zones")

        // MARK: The boundary-bar priority: generic racing can skip a bar — a grazing bar ties
        // with a flush neighbor screen's zone and loses the tiling-first tie-break, and a narrow
        // source zone may not row-align with the centered bar — but a cross-screen vertical move
        // still stops at the boundary bar it passes.
        let zFlushT = tiledZone(1, CGRect(x: 0, y: -1060, width: 1000, height: 1060), on: screenT, occupied: true)
        let barFlushT = floatingZone(CGRect(x: 300, y: -16, width: 400, height: 16), on: screenT, occupied: true)
        assertSel(
            initial(.up, focused: z1, candidates: [z1, z2, z3, z4, barA, zFlushT, barFlushT]),
            barFlushT.id,
            "flush screens: up still stops at the grazing upper bar (would tie to its zone)"
        )
        let narrowSrc = tiledZone(1, CGRect(x: 0, y: 0, width: 200, height: 900), occupied: true)
        assertSel(
            initial(.up, focused: narrowSrc, candidates: [narrowSrc, zFlushT, barFlushT]),
            barFlushT.id,
            "narrow source: up stops at the bar it does not row-align with"
        )
        let flushSrc = tiledZone(1, CGRect(x: 0, y: 0, width: 200, height: 1010), occupied: true)
        let flushSrcBar = floatingZone(CGRect(x: 300, y: 994, width: 400, height: 16), occupied: true)
        let zBelow = tiledZone(1, CGRect(x: 0, y: 1010, width: 1000, height: 900), on: screenU)
        assertSel(
            initial(.down, focused: flushSrc, candidates: [flushSrc, flushSrcBar, zBelow]),
            flushSrcBar.id,
            "down out of a screen stops at its own bar even without row alignment"
        )

        // MARK: …and its escape branches: moving off a bar crosses to the next screen (the bar is
        // the excluded source), a diagonal screen's bar that is not ahead is not forced, and a
        // missing bar candidate leaves the geometric winner.
        assertSel(
            next(.down, from: selected(flushSrcBar), candidates: [flushSrc, flushSrcBar, zBelow]),
            zBelow.id,
            "down from the bar itself continues into the screen below"
        )
        let diagSrc = tiledZone(1, CGRect(x: 0, y: 0, width: 400, height: 400), occupied: true)
        let diagZone = tiledZone(1, CGRect(x: 1200, y: -800, width: 800, height: 700), on: screenB, occupied: true)
        let diagBar = floatingZone(CGRect(x: 1400, y: 284, width: 400, height: 16), on: screenB, occupied: true)
        assertSel(
            initial(.up, focused: diagSrc, candidates: [diagSrc, diagZone, diagBar]),
            diagZone.id,
            "a diagonal screen's bar that is not ahead is not forced"
        )
        assertSel(
            initial(.up, focused: z1, candidates: [z1, z2, z3, z4, barA, zT]),
            zT.id,
            "a missing boundary bar leaves the geometric winner"
        )

        // MARK: Horizontal presses from a bar move among tiling zones only — but the reverse
        // press pops back onto the bar (retracing is remembered, not raced).
        let offBar = next(.right, from: selected(barA))
        assertSel(offBar, z4.id, "right from the bar → nearest zone (bars barred horizontally)")
        assertSel(next(.left, from: offBar), barA.id, "horizontal reverse pops back onto the bar")

        // MARK: A first press with no zone in the pressed direction selects the start zone in
        // place — the circle appears rather than nothing happening — for focused, targeted, and
        // bar starts alike (horizontal bar starts included: in-place selection is not a race);
        // a dead subsequent press stays put.
        assertSel(initial(.left, focused: z1), z1.id, "dead first press: the focused zone is selected in place")
        assertSel(initial(.right, targeted: barB, candidates: twoScreens), barB.id, "dead horizontal first press from an empty bar target selects it in place")
        assertSel(initial(.left, focused: soloBar, candidates: solo), soloBar.id, "dead horizontal first press from the focused float selects its bar in place")
        let deadRight = initial(.right, targeted: zB1, candidates: twoScreens)
        assertSel(deadRight, zB1.id, "dead first press: the empty target is selected in place")
        let recovered = next(.left, from: deadRight, candidates: twoScreens)
        assertSel(recovered, z2.id, "moving on from an in-place selection works")
        assertSel(next(.right, from: recovered, candidates: twoScreens), zB1.id, "…and reverses back to it")
        let loneZone = tiledZone(1, CGRect(x: 0, y: 0, width: 100, height: 100))
        let loneBar = floatingZone(CGRect(x: 200, y: 0, width: 100, height: 100), occupied: true)
        assertSel(
            initial(.right, targeted: loneZone, candidates: [loneZone, loneBar]),
            loneZone.id,
            "horizontal press toward a lone bar stays in place (bars barred horizontally)"
        )
        assertSel(next(.down, from: selected(barA)), barA.id, "dead direction: down from the bar stays put")

        // MARK: No focus and no resolvable target: the first press moves from the fallback start
        // (z1, the first candidate) and is reversible like any other move.
        let fromFallback = initial(.right)
        assertSel(fromFallback, z2.id, "fallback start: right from z1 → z2")
        assertSel(next(.left, from: fromFallback), z1.id, "fallback start: reverse returns to z1")

        // MARK: Exact geometric ties (vertical, where bars compete) prefer a tiling zone over the
        // floating zone, then the lower zone index.
        let tieSource = tiledZone(1, CGRect(x: 0, y: 0, width: 100, height: 100))
        let tieTiledLow = tiledZone(2, CGRect(x: 0, y: 200, width: 100, height: 100))
        let tieTiledHigh = tiledZone(3, CGRect(x: 0, y: 200, width: 100, height: 100))
        let tieFloat = floatingZone(CGRect(x: 0, y: 200, width: 100, height: 100), occupied: true)
        assertSel(
            initial(.down, targeted: tieSource, candidates: [tieSource, tieFloat, tieTiledHigh, tieTiledLow]),
            tieTiledLow.id,
            "tie-break: tiled beats floating, lower index beats higher"
        )

        // MARK: No zones — nothing is selectable.
        assertSel(initial(.right, candidates: []), nil, "empty candidates → nil")

        // MARK: The Add Zone key's side preference: stack into the selected zone's column only
        // when that zone is alone there and the column has room — a lone full-screen zone, a
        // stacked column, or a full side defers to the layout's fill order.
        func assertSide(_ actual: ZoneSide?, _ expected: ZoneSide?, _ label: String) {
            if actual != expected {
                print("ZoneNavigationTests: \(label) failed (expected \(expected.map(\.rawValue) ?? "nil"), got \(actual.map(\.rawValue) ?? "nil"))")
                allPassed = false
            }
        }
        func addSide(_ side: ZoneSide, zones: Int, onSide: Int, capacity: Int) -> ZoneSide? {
            ZoneNavigation.stackedAddSide(
                selectedZoneSide: side, zonesOnScreen: zones,
                zonesOnSelectedSide: onSide, selectedSideCapacity: capacity
            )
        }
        assertSide(addSide(.left, zones: 2, onSide: 1, capacity: 2), .left, "lone left-column zone stacks left")
        assertSide(addSide(.right, zones: 3, onSide: 1, capacity: 2), .right, "lone right-column zone stacks right")
        assertSide(addSide(.left, zones: 1, onSide: 1, capacity: 2), nil, "a lone full-screen zone has no column")
        assertSide(addSide(.right, zones: 3, onSide: 2, capacity: 2), nil, "a stacked column defers to the fill order")
        assertSide(addSide(.left, zones: 2, onSide: 1, capacity: 1), nil, "a full side defers to the fill order")

        // MARK: Reselection after the Remove Zone key: the removed screen's tiling zone that
        // takes over most of the removed frame wins — never a bar or another screen's zone, even
        // one covering the removed frame outright — ties prefer the lower index, and a screen
        // left without tiling zones resolves nothing (the gesture ends rather than jumping
        // screens).
        func assertReselect(_ actual: NavigableZoneIdentifier?, _ expected: NavigableZoneIdentifier?, _ label: String) {
            if actual != expected {
                print("ZoneNavigationTests: \(label) failed (expected \(expected.map { String(describing: $0) } ?? "nil"), got \(actual.map { String(describing: $0) } ?? "nil"))")
                allPassed = false
            }
        }
        let removedBottomRight = CGRect(x: 520, y: 520, width: 480, height: 480)
        let leftColumn = tiledZone(1, CGRect(x: 0, y: 0, width: 480, height: 1000))
        let rightColumn = tiledZone(2, CGRect(x: 520, y: 0, width: 480, height: 1000), occupied: true)
        assertReselect(
            ZoneNavigation.selectionAfterRemoval(
                removedFrame: removedBottomRight, screenId: screenA,
                candidates: [leftColumn, rightColumn, barA]
            ),
            rightColumn.id,
            "the zone absorbing the removed space is reselected"
        )
        assertReselect(
            ZoneNavigation.selectionAfterRemoval(
                removedFrame: CGRect(x: 0, y: 0, width: 1000, height: 480), screenId: screenA,
                candidates: [rightColumn, leftColumn, barA]
            ),
            leftColumn.id,
            "an equal-overlap tie prefers the lower zone index"
        )
        let coveringOtherScreenZone = tiledZone(1, removedBottomRight, on: screenB, occupied: true)
        let coveringBar = floatingZone(removedBottomRight, occupied: true)
        assertReselect(
            ZoneNavigation.selectionAfterRemoval(
                removedFrame: removedBottomRight, screenId: screenA,
                candidates: [coveringOtherScreenZone, coveringBar, leftColumn]
            ),
            leftColumn.id,
            "bars and other screens' zones never win the reselection"
        )
        assertReselect(
            ZoneNavigation.selectionAfterRemoval(
                removedFrame: removedBottomRight, screenId: screenA,
                candidates: [zB1, barB]
            ),
            nil,
            "a screen without tiling zones resolves nothing (never jump screens)"
        )

        if allPassed {
            print("ZoneNavigationTests: all tests passed")
        }
        return allPassed
    }
}
