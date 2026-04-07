import CoreGraphics

/// Guardrail tests for WinShot Sticky Resize snapshot save/restore mapping.
enum WinShotStickyResizeSnapshotMappingTests {
    @discardableResult
    static func run() -> Bool {
        var allPassed = true

        func assert(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() {
                print("WinShotStickyResizeSnapshotMappingTests: \(message)")
                allPassed = false
            }
        }

        func identity(_ windowId: Int) -> WindowIdentity {
            WindowIdentity(
                windowId: windowId,
                externalIdentifier: ExternalWindowIdentifier(pid: pid_t(windowId), cgWindowId: windowId),
                bundleIdentifier: "com.example.\(windowId)",
                windowTitle: "Window \(windowId)"
            )
        }

        let snapshotSizes = WinShotStickyResizeSnapshotMapping.snapshotSizesByZoneIndex(
            zoneAssignments: [
                1: identity(101),
                2: identity(202),
                3: identity(303),
            ],
            rememberedSizesByWindowId: [
                101: CGSize(width: 1200, height: 900),
                303: CGSize(width: 800, height: 700),
                999: CGSize(width: 400, height: 300),
            ]
        )
        assert(
            snapshotSizes == [
                1: CGSize(width: 1200, height: 900),
                3: CGSize(width: 800, height: 700),
            ],
            "snapshot save mapping should include only remembered sizes for snapshot-assigned windows"
        )

        let restoredSizes = WinShotStickyResizeSnapshotMapping.restoredSizesByWindowId(
            snapshotSizesByZoneIndex: [
                1: CGSize(width: 1200, height: 900),
                3: CGSize(width: 800, height: 700),
            ],
            restoredWindowIdsByZoneIndex: [
                1: 1001,
                2: 2002,
                3: 3003,
            ]
        )
        assert(
            restoredSizes == [
                1001: CGSize(width: 1200, height: 900),
                3003: CGSize(width: 800, height: 700),
            ],
            "snapshot restore mapping should transfer remembered sizes onto the currently matched windows"
        )

        if allPassed {
            print("WinShotStickyResizeSnapshotMappingTests: all tests passed")
        }
        return allPassed
    }
}
