import CoreGraphics
import Foundation

/// Guardrail tests for the pure last-on-screen (`lastActiveAt`) supersede policy.
enum WinShotLastActivePolicyTests {
    @discardableResult
    static func run() -> Bool {
        var allPassed = true

        func assert(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() {
                print("WinShotLastActivePolicyTests: \(message)")
                allPassed = false
            }
        }

        // Signatures are distinguished purely by which zone indices are present, so the snapshots can
        // be built without window identities. `lastActiveAt == createdAt` marks a still-live (not yet
        // superseded) snapshot; `lastActiveAt > createdAt` marks one that was already superseded.
        func snapshot(present: [Int], createdAt: Date, lastActiveAt: Date) -> WinShotSnapshot {
            WinShotSnapshot(
                id: UUID(),
                screenId: 0,
                createdAt: createdAt,
                lastActiveAt: lastActiveAt,
                zoneCount: present.count,
                zoneFrames: Dictionary(uniqueKeysWithValues: present.map { ($0, CGRect.zero) }),
                windowFrames: [:],
                rememberedTiledWindowSizesByZoneIndex: [:],
                zoneAssignments: [:],
                floatingZoneOccupant: nil,
                floatingZoneFrame: nil,
                activeWindowId: nil,
                thumbnail: nil
            )
        }

        func sig(present: [Int]) -> WinShotSnapshotOccupancySignature {
            WinShotSnapshotOccupancySignature(
                presentZoneIndices: present,
                tiledWindowIdsByZoneIndex: [:],
                floatingZoneWindowId: nil
            )
        }

        let base = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let later = base.addingTimeInterval(60)

        // Empty list: nothing to supersede.
        assert(WinShotLastActivePolicy.supersededSnapshotId(inNewestFirst: [], newSignature: sig(present: [1])) == nil,
               "an empty list supersedes nothing")

        // Live front + a genuinely different arrangement: the front is stamped as superseded.
        let live = snapshot(present: [1], createdAt: base, lastActiveAt: base)
        assert(WinShotLastActivePolicy.supersededSnapshotId(inNewestFirst: [live], newSignature: sig(present: [1, 2])) == live.id,
               "a live front arrangement is superseded by a different capture")

        // Live front + same signature: a refresh of the current arrangement supersedes nothing, so
        // the current arrangement keeps reading as "now".
        assert(WinShotLastActivePolicy.supersededSnapshotId(inNewestFirst: [live], newSignature: sig(present: [1])) == nil,
               "a same-signature refresh does not supersede the current arrangement")

        // Stale front (already superseded: lastActiveAt > createdAt) + a different signature: must NOT
        // be re-stamped. This is the window-close case — the live arrangement's snapshot was removed
        // and an older snapshot floated to the front; stamping it would make it look freshly used.
        let stale = snapshot(present: [1], createdAt: base, lastActiveAt: later)
        assert(WinShotLastActivePolicy.supersededSnapshotId(inNewestFirst: [stale], newSignature: sig(present: [1, 2])) == nil,
               "a stale (already superseded) front snapshot is not re-stamped")

        // Only the front snapshot is ever a supersede candidate; older entries are untouched.
        let older = snapshot(present: [3], createdAt: base.addingTimeInterval(-100), lastActiveAt: base.addingTimeInterval(-50))
        assert(WinShotLastActivePolicy.supersededSnapshotId(inNewestFirst: [live, older], newSignature: sig(present: [9])) == live.id,
               "only the front snapshot is considered for superseding")

        if allPassed {
            print("WinShotLastActivePolicyTests: all tests passed")
        }
        return allPassed
    }
}
