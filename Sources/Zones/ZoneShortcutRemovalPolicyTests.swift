import Foundation

/// Lightweight runtime assertions for shortcut-driven zone removal selection.
enum ZoneShortcutRemovalPolicyTests {
    @discardableResult
    static func run() -> Bool {
        var allPassed = true

        func assert(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() {
                print("ZoneShortcutRemovalPolicyTests: \(message)")
                allPassed = false
            }
        }

        let emptyZone1 = ZoneShortcutRemovalPolicy.ZoneSnapshot(index: 1, isEmpty: true, occupantWindowId: nil)
        let occupiedZone2 = ZoneShortcutRemovalPolicy.ZoneSnapshot(index: 2, isEmpty: false, occupantWindowId: 2002)
        let occupiedZone3 = ZoneShortcutRemovalPolicy.ZoneSnapshot(index: 3, isEmpty: false, occupantWindowId: 2003)

        do {
            let selected = ZoneShortcutRemovalPolicy.selectedZoneIndex(
                zones: [emptyZone1, occupiedZone2, occupiedZone3],
                protectedIndices: [],
                targetedIndex: nil
            )
            assert(selected == 1, "empty zones should be removed before occupied zones")
        }

        do {
            let selected = ZoneShortcutRemovalPolicy.selectedZoneIndex(
                zones: [occupiedZone2, occupiedZone3],
                protectedIndices: [],
                targetedIndex: 3
            )
            assert(selected == 2, "non-targeted zones should be preferred over targeted zones")
        }

        do {
            let ordered = ZoneShortcutRemovalPolicy.orderedCandidates(
                zones: [emptyZone1, occupiedZone2, occupiedZone3],
                protectedIndices: [1],
                targetedIndex: nil
            )
            assert(
                ordered.map(\.index) == [3, 2],
                "when all remaining candidates tie, higher zone indices should be removed first"
            )
        }

        do {
            let selected = ZoneShortcutRemovalPolicy.selectedZoneIndex(
                zones: [emptyZone1, occupiedZone2],
                protectedIndices: [1, 2],
                targetedIndex: 1
            )
            assert(selected == nil, "selection should stop when every zone is protected")
        }

        if allPassed {
            print("ZoneShortcutRemovalPolicyTests: all tests passed")
        }
        return allPassed
    }
}
