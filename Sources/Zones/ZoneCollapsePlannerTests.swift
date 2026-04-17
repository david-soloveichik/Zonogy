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

        if allPassed {
            print("ZoneCollapsePlannerTests: all tests passed")
        }
        return allPassed
    }
}
