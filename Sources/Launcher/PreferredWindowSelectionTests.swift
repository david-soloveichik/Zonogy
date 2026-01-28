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
                .init(windowId: 10, cgWindowId: 400, lastActiveTime: tOld),
                .init(windowId: 5, cgWindowId: 200, lastActiveTime: tNew),
                .init(windowId: 1, cgWindowId: 300, lastActiveTime: nil),
            ]

            let selected = PreferredWindowSelection.selectPreferredWindow(from: candidates, prefersMainWindow: true)
            assert(selected?.windowId == 5, "hasMainWindow should select the lowest CGWindowID window")
        }

        do {
            let t1 = Date(timeIntervalSince1970: 10)
            let t2 = Date(timeIntervalSince1970: 20)

            let candidates: [PreferredWindowSelection.Candidate] = [
                .init(windowId: 1, cgWindowId: 111, lastActiveTime: t1),
                .init(windowId: 2, cgWindowId: 222, lastActiveTime: t2),
                .init(windowId: 3, cgWindowId: 333, lastActiveTime: nil),
            ]

            let selected = PreferredWindowSelection.selectPreferredWindow(from: candidates, prefersMainWindow: false)
            assert(selected?.windowId == 2, "non-main window apps should select the most recently active window")
        }

        do {
            let candidates: [PreferredWindowSelection.Candidate] = [
                .init(windowId: 42, cgWindowId: 1000, lastActiveTime: nil),
                .init(windowId: 7, cgWindowId: 2000, lastActiveTime: nil),
            ]

            let selected = PreferredWindowSelection.selectPreferredWindow(from: candidates, prefersMainWindow: false)
            assert(selected?.windowId == 7, "when recency is unknown, selection should fall back to lowest Zonogy ID")
        }

        if allPassed {
            print("PreferredWindowSelectionTests: all tests passed")
        }
        return allPassed
    }
}

