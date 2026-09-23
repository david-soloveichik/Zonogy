import Foundation

/// Guardrail tests for Launcher preferred window selection heuristics.
enum PreferredWindowSelectionTests {
    @discardableResult
    static func run() -> Bool {
        var allPassed = true

        func assert(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() {
                print("PreferredWindowSelectionTests: \(message)")
                allPassed = false
            }
        }

        do {
            let tOld = Date(timeIntervalSince1970: 1)
            let tNew = Date(timeIntervalSince1970: 999)

            let candidates: [PreferredWindowSelection.Candidate] = [
                .init(windowId: 10, cgWindowId: 400, isPlacedInZone: false, lastActiveTime: tOld),
                .init(windowId: 5, cgWindowId: 200, isPlacedInZone: true, lastActiveTime: tNew),
                .init(windowId: 1, cgWindowId: 300, isPlacedInZone: false, lastActiveTime: nil),
            ]

            let selected = PreferredWindowSelection.selectPreferredWindow(
                from: candidates, prefersMainWindow: true, placedMainWindowYields: false
            )
            assert(selected?.windowId == 5, "hasMainWindow should select the lowest CGWindowID window")

            let yielded = PreferredWindowSelection.selectPreferredWindow(
                from: candidates, prefersMainWindow: true, placedMainWindowYields: true
            )
            assert(yielded?.windowId == 10, "a placed main window should yield to the first drill-down window")
        }

        do {
            let tNew = Date(timeIntervalSince1970: 999)

            let unplacedMain: [PreferredWindowSelection.Candidate] = [
                .init(windowId: 2, cgWindowId: 100, isPlacedInZone: false, lastActiveTime: nil),
                .init(windowId: 3, cgWindowId: 300, isPlacedInZone: false, lastActiveTime: tNew),
            ]
            let selected = PreferredWindowSelection.selectPreferredWindow(
                from: unplacedMain, prefersMainWindow: true, placedMainWindowYields: true
            )
            assert(selected?.windowId == 2, "a main window not in a zone should win even when a placed one would yield")

            let onlyPlacedMain: [PreferredWindowSelection.Candidate] = [
                .init(windowId: 4, cgWindowId: 100, isPlacedInZone: true, lastActiveTime: nil),
            ]
            let sole = PreferredWindowSelection.selectPreferredWindow(
                from: onlyPlacedMain, prefersMainWindow: true, placedMainWindowYields: true
            )
            assert(sole?.windowId == 4, "a placed main window that is the only window should still be selected")
        }

        do {
            let t1 = Date(timeIntervalSince1970: 10)
            let t2 = Date(timeIntervalSince1970: 20)

            let candidates: [PreferredWindowSelection.Candidate] = [
                .init(windowId: 1, cgWindowId: 111, isPlacedInZone: true, lastActiveTime: t2),
                .init(windowId: 2, cgWindowId: 222, isPlacedInZone: false, lastActiveTime: t1),
                .init(windowId: 3, cgWindowId: 333, isPlacedInZone: true, lastActiveTime: nil),
            ]

            let selected = PreferredWindowSelection.selectPreferredWindow(
                from: candidates, prefersMainWindow: false, placedMainWindowYields: false
            )
            assert(selected?.windowId == 2, "non-main window apps should prioritize the first drill-down window (not-in-zone first)")
        }

        do {
            let tOld = Date(timeIntervalSince1970: 10)
            let tNew = Date(timeIntervalSince1970: 20)

            let candidates: [PreferredWindowSelection.Candidate] = [
                .init(windowId: 1, cgWindowId: 1000, isPlacedInZone: false, lastActiveTime: tOld),
                .init(windowId: 7, cgWindowId: 2000, isPlacedInZone: false, lastActiveTime: tNew),
            ]

            let selected = PreferredWindowSelection.selectPreferredWindow(
                from: candidates, prefersMainWindow: false, placedMainWindowYields: false
            )
            assert(selected?.windowId == 7, "within the same placement group, non-main window apps should pick most recent")
        }

        do {
            let candidates: [PreferredWindowSelection.Candidate] = [
                .init(windowId: 42, cgWindowId: 1000, isPlacedInZone: false, lastActiveTime: nil),
                .init(windowId: 7, cgWindowId: 2000, isPlacedInZone: false, lastActiveTime: nil),
            ]

            let selected = PreferredWindowSelection.selectPreferredWindow(
                from: candidates, prefersMainWindow: false, placedMainWindowYields: false
            )
            assert(selected?.windowId == 7, "when recency is unknown, selection should fall back to lowest Zonogy ID")
        }

        if allPassed {
            print("PreferredWindowSelectionTests: all tests passed")
        }
        return allPassed
    }
}
