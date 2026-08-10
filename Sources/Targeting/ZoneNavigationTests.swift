import CoreGraphics

/// Guardrail assertions for the pure zone-navigation selection policy.
///
/// Each tiling fixture carries its structural place (column side and stack row) exactly as the
/// gesture builder derives it from the zone model; frames only matter for the geometric
/// cross-screen exits. Frames are in the shared global coordinate space (y increases downward),
/// mirroring the accessibility coordinates AppController feeds the navigator at runtime.
///
/// Fixture: screen A holds a 2×2 grid of tiling zones (zones 1–4: 1 top-left filled, 2 top-right
/// filled, 3 bottom-left EMPTY, 4 bottom-right filled) plus its floating zone's bottom-edge bar,
/// occupied and clear of the grid (a bottom-Dock layout). Screen B sits to the right with one
/// empty full-screen tiling zone and an empty floating bar. Local fixtures cover the
/// full-column-beside-a-stack layout (the reported diagonal-move annoyance), uneven splits,
/// screens stacked above and below, grazing bars (hidden/side Dock), and the Add Zone key's side
/// preference plus the reselection after the Remove Zone key.
enum ZoneNavigationTests {
    private static let screenA: CGDirectDisplayID = 10
    private static let screenB: CGDirectDisplayID = 20
    private static let screenT: CGDirectDisplayID = 30
    private static let screenU: CGDirectDisplayID = 40

    private static func tiledZone(
        _ index: Int,
        _ frame: CGRect,
        on screenId: CGDirectDisplayID = screenA,
        _ side: ZoneSide,
        _ row: ZoneNavigation.StackRow,
        occupied: Bool = false
    ) -> ZoneNavigation.Candidate {
        .init(
            id: .tiling(screenId: screenId, index: index),
            frame: frame,
            isOccupied: occupied,
            place: .init(side: side, row: row)
        )
    }

    private static func floatingZone(
        _ frame: CGRect, on screenId: CGDirectDisplayID = screenA, occupied: Bool = false
    ) -> ZoneNavigation.Candidate {
        .init(id: .floating(screenId: screenId), frame: frame, isOccupied: occupied, place: nil)
    }

    private static let z1 = tiledZone(1, CGRect(x: 0, y: 0, width: 480, height: 480), .left, .top, occupied: true)
    private static let z2 = tiledZone(2, CGRect(x: 520, y: 0, width: 480, height: 480), .right, .top, occupied: true)
    private static let z3 = tiledZone(3, CGRect(x: 0, y: 520, width: 480, height: 480), .left, .bottom)
    private static let z4 = tiledZone(4, CGRect(x: 520, y: 520, width: 480, height: 480), .right, .bottom, occupied: true)
    private static let barA = floatingZone(CGRect(x: 300, y: 1044, width: 400, height: 16), occupied: true)

    private static let zB1 = tiledZone(1, CGRect(x: 1000, y: 0, width: 1000, height: 940), on: screenB, .left, .full)
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

        // MARK: Up and down walk a column's stack, with the bar as the bottom-most stop — filled
        // and empty zones alike — and up from the bar climbs into the bottom row, where the
        // lower zone index wins between the two columns.
        assertSel(initial(.down, focused: z2), z4.id, "down z2→z4 walks the right stack")
        assertSel(initial(.up, focused: z4), z2.id, "up z4→z2 climbs it")
        assertSel(initial(.down, focused: z4), barA.id, "down z4→occupied bar")
        assertSel(initial(.down, targeted: z3), barA.id, "empty target: down z3→bar (moves immediately)")
        assertSel(next(.up, from: selected(barA)), z3.id, "up bar→z3 (lower index between bottom zones)")

        // MARK: The degenerate single-zone screen: down reaches the bar even when it grazes the
        // zone's bottom edge (hidden/side Dock), and up climbs back out — the bar keeps the zone
        // and the floating occupant mutually reachable regardless of where that occupant's
        // window sits.
        let soloZone = tiledZone(1, CGRect(x: 0, y: 0, width: 1000, height: 1000), .left, .full, occupied: true)
        let soloBar = floatingZone(CGRect(x: 300, y: 994, width: 400, height: 16), occupied: true)
        let solo = [soloZone, soloBar]
        assertSel(initial(.down, focused: soloZone, candidates: solo), soloBar.id, "solo: down zone→occupied bar")
        assertSel(initial(.up, focused: soloBar, candidates: solo), soloZone.id, "solo: up from focused float→zone")

        // MARK: A full-height column counts as a bottom zone for the bar's climb — in the
        // mirrored layout (full right column, stacked left) the lower index wins across columns.
        let mirror1 = tiledZone(1, CGRect(x: 520, y: 0, width: 480, height: 1000), .right, .full, occupied: true)
        let mirror2 = tiledZone(2, CGRect(x: 0, y: 0, width: 480, height: 480), .left, .top)
        let mirror3 = tiledZone(3, CGRect(x: 0, y: 520, width: 480, height: 480), .left, .bottom)
        let mirrorBar = floatingZone(CGRect(x: 300, y: 1044, width: 400, height: 16))
        let mirror = [mirror1, mirror2, mirror3, mirrorBar]
        assertSel(next(.up, from: selected(mirrorBar), candidates: mirror), mirror1.id, "bar-up: the full column is a bottom zone and its lower index wins")

        // MARK: The reported diagonal annoyance: a full-height column has nothing above it on its
        // own screen — up NEVER selects the neighboring stack's top zone. With no screen above
        // the press is dead; with one, it exits to that screen (bar first). Down still reaches
        // the (grazing) bar.
        let lrL1 = tiledZone(1, CGRect(x: 0, y: 0, width: 480, height: 1000), .left, .full, occupied: true)
        let lrR2 = tiledZone(2, CGRect(x: 520, y: 0, width: 480, height: 480), .right, .top, occupied: true)
        let lrR3 = tiledZone(3, CGRect(x: 520, y: 520, width: 480, height: 480), .right, .bottom, occupied: true)
        let lrBar = floatingZone(CGRect(x: 300, y: 994, width: 400, height: 16), occupied: true)
        let lr = [lrL1, lrR2, lrR3, lrBar]
        assertSel(initial(.up, focused: lrL1, candidates: lr), lrL1.id, "up from a full column: dead press, not the stack's top")
        assertSel(initial(.down, focused: lrL1, candidates: lr), lrBar.id, "down from a full column: the bar")
        let lrT = tiledZone(1, CGRect(x: 0, y: -1060, width: 1000, height: 940), on: screenT, .left, .full)
        let lrBarT = floatingZone(CGRect(x: 300, y: -16, width: 400, height: 16), on: screenT)
        assertSel(
            initial(.up, focused: lrL1, candidates: lr + [lrT, lrBarT]),
            lrBarT.id,
            "up from a full column exits to the screen above (bar first)"
        )

        // MARK: Left and right cross between the columns, staying in the same row; a single-zone
        // column takes both rows, and a full-height column enters a stack at its top.
        assertSel(initial(.left, focused: z2), z1.id, "left z2→z1 stays in the top row")
        assertSel(initial(.left, focused: z4), z3.id, "left z4→z3 stays in the bottom row")
        assertSel(initial(.left, focused: lrR3, candidates: lr), lrL1.id, "left from the stack's bottom → the full column")
        assertSel(next(.right, from: selected(lrL1), candidates: lr), lrR2.id, "right from the full column enters the stack at the top")

        // MARK: Dragged split ratios never change where a press lands: rows match positionally
        // even when geometry disagrees. (Left column split 20/80, right column 80/20: the tall
        // bottom-left zone faces mostly the tall top-right zone, but Right still lands on the
        // bottom-right sliver.)
        let u1 = tiledZone(1, CGRect(x: 0, y: 0, width: 480, height: 192), .left, .top)
        let u2 = tiledZone(2, CGRect(x: 0, y: 208, width: 480, height: 792), .left, .bottom, occupied: true)
        let u3 = tiledZone(3, CGRect(x: 520, y: 0, width: 480, height: 792), .right, .top, occupied: true)
        let u4 = tiledZone(4, CGRect(x: 520, y: 808, width: 480, height: 192), .right, .bottom)
        let uneven = [u1, u2, u3, u4, floatingZone(CGRect(x: 300, y: 1044, width: 400, height: 16))]
        assertSel(initial(.right, focused: u2, candidates: uneven), u4.id, "bottom stays bottom despite the ratios")
        assertSel(initial(.left, focused: u3, candidates: uneven), u1.id, "top stays top despite the ratios")

        // MARK: From the bar, left and right go to that column's bottom-most zone; a fresh move
        // never lands on a bar horizontally, but the reverse press pops back onto it (retracing
        // is remembered, not resolved), and a press with no stop that way is dead.
        let offBar = next(.right, from: selected(barA))
        assertSel(offBar, z4.id, "right from the bar → the right column's bottom zone")
        assertSel(next(.left, from: offBar), barA.id, "horizontal reverse pops back onto the bar")
        assertSel(next(.left, from: selected(barA)), z3.id, "left from the bar → the left column's bottom zone")
        let loneZone = tiledZone(1, CGRect(x: 0, y: 0, width: 100, height: 100), .left, .full)
        let loneBar = floatingZone(CGRect(x: 200, y: 0, width: 100, height: 100), occupied: true)
        assertSel(
            initial(.right, targeted: loneZone, candidates: [loneZone, loneBar]),
            loneZone.id,
            "horizontal press toward a lone bar stays in place (bars barred horizontally)"
        )
        assertSel(next(.down, from: selected(barA)), barA.id, "dead direction: down from the bar stays put")

        // MARK: A single-zone screen — the only layout where a side is empty (multi-zone screens
        // always occupy both sides) — has no column to cross: horizontal presses from its zone
        // or its bar exit the screen, landing on the neighbor's zone (bars stay out of
        // horizontal races). The dead no-neighbor variants are covered above and below.
        let soloPair = solo + [zB1, barB]
        assertSel(initial(.right, focused: soloZone, candidates: soloPair), zB1.id, "single zone: right exits to the neighboring screen")
        assertSel(next(.right, from: selected(soloBar), candidates: soloPair), zB1.id, "single zone: right from the bar exits to the neighbor's zone")

        // MARK: Reversal is remembered, not recomputed: moves are lossy (the full column reached
        // from the stack's bottom re-enters at the top), so the exact opposite press retraces the
        // trail step by step, and a dead press keeps it intact.
        let lrLeft = initial(.left, focused: lrR3, candidates: lr)
        assertSel(next(.right, from: lrLeft, candidates: lr), lrR3.id, "reverse press returns to the bottom, not the top")
        let lrDown = next(.down, from: lrLeft, candidates: lr)
        assertSel(lrDown, lrBar.id, "trail: left then down reaches the bar")
        let lrBack1 = next(.up, from: lrDown, candidates: lr)
        assertSel(lrBack1, lrL1.id, "trail: first reverse pops to the full column")
        assertSel(next(.right, from: lrBack1, candidates: lr), lrR3.id, "trail: second reverse pops to the start")
        let lrDead = next(.up, from: lrLeft, candidates: lr)
        assertSel(lrDead, lrL1.id, "dead press keeps the selection…")
        assertSel(next(.right, from: lrDead, candidates: lr), lrR3.id, "…and keeps the trail: the reverse still pops")

        // MARK: No focus, filled targeted zone — the first press selects it in place (any
        // direction). An occupied floating target works the same, so tap-and-release focuses the
        // floating window. Moving off a selected target is reversible like any other move.
        let selectedTarget = initial(.left, targeted: z2)
        assertSel(selectedTarget, z2.id, "filled target: first press selects z2 in place")
        assertSel(initial(.up, targeted: barA), barA.id, "occupied floating target: selected in place")
        let offTarget = next(.left, from: selectedTarget)
        assertSel(offTarget, z1.id, "selected target: left → z1")
        assertSel(next(.right, from: offTarget), z2.id, "selected target: reverse returns")

        // MARK: Exits are geometric: a press past the layout's edge crosses to the next screen
        // in that direction. Empty zones are first-class stops, and bars never join horizontal
        // races.
        assertSel(initial(.right, focused: z4, candidates: twoScreens), zB1.id, "cross-screen: right z4→empty zB1")

        // MARK: The empty floating bar is the same bottom-most stop, and the reverse press pops
        // back out.
        let downToBar = initial(.down, targeted: zB1, candidates: twoScreens)
        assertSel(downToBar, barB.id, "bar: down zB1→empty bar")
        assertSel(next(.up, from: downToBar, candidates: twoScreens), zB1.id, "bar: up pops back to zB1")

        // MARK: Entering a screen from below lands on its bar first — the bar is that screen's
        // bottom-most stop — and the next press continues into its zones.
        let zT = tiledZone(1, CGRect(x: 0, y: -1060, width: 1000, height: 940), on: screenT, .left, .full)
        let barT = floatingZone(CGRect(x: 300, y: -16, width: 400, height: 16), on: screenT)
        let stacked = [z1, z2, z3, z4, barA, zT, barT]
        let upToBarT = initial(.up, focused: z1, candidates: stacked)
        assertSel(upToBarT, barT.id, "stacked screens: up from below lands on the upper bar")
        assertSel(next(.up, from: upToBarT, candidates: stacked), zT.id, "stacked screens: up again continues into the zones")

        // MARK: The upward entry-bar rule holds even where raw racing would skip the bar: a
        // grazing bar on a flush screen boundary, and a source too narrow to row-align with the
        // centered bar.
        let zFlushT = tiledZone(1, CGRect(x: 0, y: -1060, width: 1000, height: 1060), on: screenT, .left, .full, occupied: true)
        let barFlushT = floatingZone(CGRect(x: 300, y: -16, width: 400, height: 16), on: screenT, occupied: true)
        assertSel(
            initial(.up, focused: z1, candidates: [z1, z2, z3, z4, barA, zFlushT, barFlushT]),
            barFlushT.id,
            "flush screens: up still stops at the grazing upper bar"
        )
        let narrowSrc = tiledZone(1, CGRect(x: 0, y: 0, width: 200, height: 900), .left, .full, occupied: true)
        assertSel(
            initial(.up, focused: narrowSrc, candidates: [narrowSrc, zFlushT, barFlushT]),
            barFlushT.id,
            "narrow source: up stops at the bar it does not row-align with"
        )

        // MARK: Leaving a screen downward stops at its own bar structurally — even one the
        // source does not overlap horizontally — and down from the bar itself continues into the
        // screen below.
        let flushSrc = tiledZone(1, CGRect(x: 0, y: 0, width: 200, height: 1010), .left, .full, occupied: true)
        let flushSrcBar = floatingZone(CGRect(x: 300, y: 994, width: 400, height: 16), occupied: true)
        let zBelow = tiledZone(1, CGRect(x: 0, y: 1010, width: 1000, height: 900), on: screenU, .left, .full)
        assertSel(
            initial(.down, focused: flushSrc, candidates: [flushSrc, flushSrcBar, zBelow]),
            flushSrcBar.id,
            "down out of a screen stops at its own bar even without row alignment"
        )
        assertSel(
            next(.down, from: selected(flushSrcBar), candidates: [flushSrc, flushSrcBar, zBelow]),
            zBelow.id,
            "down from the bar itself continues into the screen below"
        )

        // MARK: A screen missing its bar candidate (a defensive state — every real screen has a
        // floating zone) degrades gracefully: down from its bottom zone exits directly.
        let noBarZone = tiledZone(1, CGRect(x: 0, y: 0, width: 1000, height: 1000), .left, .full, occupied: true)
        assertSel(
            initial(.down, focused: noBarZone, candidates: [noBarZone, zBelow]),
            zBelow.id,
            "a missing source bar falls through to the screen below"
        )

        // MARK: …and the entry-bar rule's escape branches: a diagonal screen's bar that is not
        // ahead is not forced, and a missing bar candidate leaves the geometric winner.
        let diagSrc = tiledZone(1, CGRect(x: 0, y: 0, width: 400, height: 400), .left, .full, occupied: true)
        let diagZone = tiledZone(1, CGRect(x: 1200, y: -800, width: 800, height: 700), on: screenB, .left, .full, occupied: true)
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

        // MARK: A first press with no zone in the pressed direction selects the start zone in
        // place — the circle appears rather than nothing happening — for focused, targeted, and
        // bar starts alike.
        assertSel(initial(.left, focused: z1), z1.id, "dead first press: the focused zone is selected in place")
        assertSel(initial(.right, targeted: barB, candidates: twoScreens), barB.id, "dead horizontal first press from an empty bar target selects it in place")
        assertSel(initial(.left, focused: soloBar, candidates: solo), soloBar.id, "dead horizontal first press from the focused float selects its bar in place")
        let deadRight = initial(.right, targeted: zB1, candidates: twoScreens)
        assertSel(deadRight, zB1.id, "dead first press: the empty target is selected in place")
        let recovered = next(.left, from: deadRight, candidates: twoScreens)
        assertSel(recovered, z2.id, "moving on from an in-place selection works")
        assertSel(next(.right, from: recovered, candidates: twoScreens), zB1.id, "…and reverses back to it")

        // MARK: No focus and no resolvable target: the first press moves from the fallback start
        // (z1, the first candidate) and is reversible like any other move.
        let fromFallback = initial(.right)
        assertSel(fromFallback, z2.id, "fallback start: right from z1 → z2")
        assertSel(next(.left, from: fromFallback), z1.id, "fallback start: reverse returns to z1")

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
        let leftColumn = tiledZone(1, CGRect(x: 0, y: 0, width: 480, height: 1000), .left, .full)
        let rightColumn = tiledZone(2, CGRect(x: 520, y: 0, width: 480, height: 1000), .right, .full, occupied: true)
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
        let coveringOtherScreenZone = tiledZone(1, removedBottomRight, on: screenB, .left, .full, occupied: true)
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
