import AppKit
import Foundation

/// Guardrail tests for chooser row placement refresh and the equality contract it relies on.
enum LauncherWindowItemTests {
    @discardableResult
    static func run() -> Bool {
        var allPassed = true

        func assert(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() {
                print("LauncherWindowItemTests: \(message)")
                allPassed = false
            }
        }

        // A local AX element token; never sent to the AX server, so no permissions involved.
        let element = AXUIElementCreateApplication(getpid())

        func item(title: String, placed: Bool, managedWindowId: Int?) -> LauncherWindowItem {
            LauncherWindowItem(
                title: title,
                isPlacedInZone: placed,
                axElement: element,
                pid: 1,
                managedWindowId: managedWindowId
            )
        }

        // Equality must include the placement flag: the refresh publish gates and SwiftUI
        // row repainting both compare items, so id-only equality would hide refreshes.
        let placed = item(title: "a", placed: true, managedWindowId: 1)
        var unplacedCopy = placed
        unplacedCopy.isPlacedInZone = false
        assert(placed == placed, "identical items should be equal")
        assert(placed != unplacedCopy, "same row with a different placement flag should not be equal")

        // refreshingPlacement: flags follow the resolver; membership, order, and identity
        // are preserved so an open chooser never reorders.
        let rows = [
            item(title: "a", placed: true, managedWindowId: 1),
            item(title: "b", placed: true, managedWindowId: 2),
            item(title: "c", placed: true, managedWindowId: nil),
        ]
        let refreshed = rows.refreshingPlacement { windowId in windowId == 2 }
        assert(refreshed.map(\.id) == rows.map(\.id), "refresh should preserve membership, order, and identity")
        assert(refreshed[0].isPlacedInZone == false, "resolver false should clear the flag")
        assert(refreshed[1].isPlacedInZone == true, "resolver true should keep the flag")
        assert(refreshed[2].isPlacedInZone == true, "rows without a managed id keep their snapshot value")

        // Rows without a managed id must not consult the resolver.
        var resolvedIds: [Int] = []
        _ = rows.refreshingPlacement { windowId in
            resolvedIds.append(windowId)
            return false
        }
        assert(resolvedIds == [1, 2], "only managed rows should be resolved")

        // A refresh that changes nothing must compare equal, so publishes can be suppressed.
        let unchanged = rows.refreshingPlacement { _ in true }
        assert(unchanged == rows, "no-op refresh should compare equal to the original rows")

        if allPassed {
            print("LauncherWindowItemTests: all tests passed")
        }
        return allPassed
    }
}
