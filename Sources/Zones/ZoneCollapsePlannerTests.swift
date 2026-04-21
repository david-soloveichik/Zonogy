import Foundation

/// Lightweight runtime assertions for shortcut-driven bulk zone collapse planning.
enum ZoneCollapsePlannerTests {
    @discardableResult
    static func run() -> Bool {
        var allPassed = true

        func assert(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() {
                print("ZoneCollapsePlannerTests: \(message)")
                allPassed = false
            }
        }

        do {
            let plan = ZoneCollapsePlanner.plan(
                zones: [
                    .init(index: 1, occupantWindowId: 101),
                    .init(index: 2, occupantWindowId: 202),
                    .init(index: 3, occupantWindowId: 303),
                ],
                protectedWindowIds: [202],
                targetedIndex: 2
            )

            assert(
                plan.finalZones == [.init(index: 1, occupantWindowId: 202)],
                "protected surviving window should stay on the collapsing screen"
            )
            assert(
                plan.removedWindowIds == [303, 101],
                "removal order should match repeated shortcut removal selection"
            )
            assert(plan.finalTargetIndex == 1, "targeted protected zone should shift into the final zone")
        }

        do {
            let plan = ZoneCollapsePlanner.plan(
                zones: [
                    .init(index: 1, occupantWindowId: nil),
                    .init(index: 2, occupantWindowId: 202),
                    .init(index: 3, occupantWindowId: 303),
                ],
                protectedWindowIds: [],
                targetedIndex: 2
            )

            assert(
                plan.finalZones == [.init(index: 1, occupantWindowId: 202)],
                "empty zones should be removed before occupied ones during collapse"
            )
            assert(
                plan.removedWindowIds == [303],
                "only occupied zones removed by the simulated collapse should report windows"
            )
            assert(plan.finalTargetIndex == 1, "target should shift when earlier zones are removed")
        }

        do {
            let plan = ZoneCollapsePlanner.plan(
                zones: [
                    .init(index: 1, occupantWindowId: 101),
                    .init(index: 2, occupantWindowId: nil),
                    .init(index: 3, occupantWindowId: 303),
                ],
                protectedWindowIds: [],
                targetedIndex: 2
            )

            assert(plan.finalTargetIndex == nil, "target should be cleared once the targeted zone is removed")
        }

        do {
            let plan = ZoneCollapsePlanner.plan(
                zones: [
                    .init(index: 1, occupantWindowId: 101),
                    .init(index: 2, occupantWindowId: 202),
                    .init(index: 3, occupantWindowId: 303),
                ],
                protectedWindowIds: [101, 202],
                targetedIndex: 1
            )

            assert(
                plan.finalZones == [
                    .init(index: 1, occupantWindowId: 101),
                    .init(index: 2, occupantWindowId: 202),
                ],
                "collapse should stop once only protected zones remain"
            )
            assert(
                plan.removedWindowIds == [303],
                "partial collapse should preserve the order of removed windows"
            )
            assert(plan.finalTargetIndex == 1, "surviving target should remain on the collapsing screen")
        }

        // Floating-promotion variant: all tiled occupants minimized, floating window becomes zone 1.
        do {
            let plan = ZoneCollapsePlanner.planWithFloatingPromotion(
                zones: [
                    .init(index: 1, occupantWindowId: 101),
                    .init(index: 2, occupantWindowId: 202),
                    .init(index: 3, occupantWindowId: 303),
                ],
                floatingWindowId: 999
            )

            assert(
                plan.finalZones == [.init(index: 1, occupantWindowId: 999)],
                "floating promotion should leave one zone containing the floating window"
            )
            assert(
                plan.removedWindowIds == [101, 202, 303],
                "floating promotion should minimize every tiled occupant in index order"
            )
            assert(plan.finalTargetIndex == nil, "floating promotion preserves the pre-existing floating target instead of forcing zone 1")
        }

        do {
            let plan = ZoneCollapsePlanner.planWithFloatingPromotion(
                zones: [
                    .init(index: 1, occupantWindowId: nil),
                    .init(index: 2, occupantWindowId: 202),
                ],
                floatingWindowId: 999
            )

            assert(
                plan.finalZones == [.init(index: 1, occupantWindowId: 999)],
                "floating promotion should ignore pre-existing emptiness and land the floating window in zone 1"
            )
            assert(
                plan.removedWindowIds == [202],
                "empty tiled zones should contribute nothing to the minimize list"
            )
            assert(plan.finalTargetIndex == nil, "floating promotion preserves the pre-existing floating target instead of forcing zone 1")
        }

        do {
            let plan = ZoneCollapsePlanner.planWithFloatingPromotion(
                zones: [.init(index: 1, occupantWindowId: nil)],
                floatingWindowId: 999
            )

            assert(
                plan.finalZones == [.init(index: 1, occupantWindowId: 999)],
                "floating promotion with only an empty zone should still place the floating window"
            )
            assert(plan.removedWindowIds.isEmpty, "no tiled occupants means nothing to minimize")
            assert(plan.finalTargetIndex == nil, "floating promotion preserves the pre-existing floating target instead of forcing zone 1")
        }

        do {
            let plan = ZoneCollapsePlanner.planWithFloatingPromotion(
                zones: [.init(index: 1, occupantWindowId: 101)],
                floatingWindowId: 999
            )

            assert(
                !plan.removedWindowIds.contains(999),
                "the floating window must never be added to the minimize list"
            )
            assert(
                plan.removedWindowIds == [101],
                "the lone tiled occupant should be minimized to make room for the floating window"
            )
            assert(
                plan.finalZones == [.init(index: 1, occupantWindowId: 999)],
                "single-zone screens collapse in place with the floating window taking over zone 1"
            )
        }

        if allPassed {
            print("ZoneCollapsePlannerTests: all tests passed")
        }
        return allPassed
    }
}
