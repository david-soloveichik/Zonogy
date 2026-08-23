import CoreGraphics
import Foundation

/// Guardrail tests for merging a disconnected display's WinShot snapshots onto a neighbor.
enum WinShotDisplayMergePolicyTests {
    @discardableResult
    static func run() -> Bool {
        var allPassed = true

        func assert(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() {
                print("WinShotDisplayMergePolicyTests: \(message)")
                allPassed = false
            }
        }

        // MARK: Host display choice

        let removed = CGRect(x: 0, y: 0, width: 1000, height: 600)
        let rightNeighbor = CGRect(x: 1000, y: 0, width: 1000, height: 600)   // shares the full 600pt edge
        let aboveNeighbor = CGRect(x: 0, y: 600, width: 800, height: 500)     // shares an 800pt edge
        let cornerNeighbor = CGRect(x: 1000, y: 600, width: 500, height: 500) // touches at a corner only
        let farNeighbor = CGRect(x: 2000, y: 0, width: 1000, height: 600)     // 1000pt away

        assert(
            WinShotDisplayMergePolicy.hostScreenId(forRemovedFrame: removed, remainingFrames: [:]) == nil,
            "no remaining display means no host"
        )
        assert(
            WinShotDisplayMergePolicy.hostScreenId(
                forRemovedFrame: removed,
                remainingFrames: [1: rightNeighbor, 2: aboveNeighbor, 3: cornerNeighbor, 4: farNeighbor]
            ) == 2,
            "the display sharing the longest edge hosts the snapshots"
        )
        assert(
            WinShotDisplayMergePolicy.hostScreenId(
                forRemovedFrame: removed,
                remainingFrames: [1: rightNeighbor, 3: cornerNeighbor, 4: farNeighbor]
            ) == 1,
            "an edge-sharing display beats a corner-touching one"
        )
        assert(
            WinShotDisplayMergePolicy.hostScreenId(
                forRemovedFrame: removed,
                remainingFrames: [3: cornerNeighbor, 4: farNeighbor]
            ) == 3,
            "a touching display beats one that sits apart"
        )
        assert(
            WinShotDisplayMergePolicy.hostScreenId(
                forRemovedFrame: removed,
                remainingFrames: [4: farNeighbor, 5: CGRect(x: 0, y: 900, width: 1000, height: 600)]
            ) == 5,
            "among displays sitting apart, the nearest gap wins"
        )
        // Two full-height neighbors on either side (the middle display of a row is removed).
        assert(
            WinShotDisplayMergePolicy.hostScreenId(
                forRemovedFrame: removed,
                remainingFrames: [7: rightNeighbor, 6: CGRect(x: -1000, y: 0, width: 1000, height: 600)]
            ) == 6,
            "an equal shared edge breaks the tie toward the lowest display id"
        )
        // Equally far apart: the display facing the removed one across more of its width/height wins.
        assert(
            WinShotDisplayMergePolicy.hostScreenId(
                forRemovedFrame: removed,
                remainingFrames: [4: farNeighbor, 8: CGRect(x: 0, y: 1600, width: 1000, height: 600)]
            ) == 8,
            "among equally distant displays, the larger facing overlap wins"
        )

        // MARK: Merging the lists

        func snapshot(screenId: CGDirectDisplayID, createdAt: Date, supersededAt: Date? = nil) -> WinShotSnapshot {
            WinShotSnapshot(
                id: UUID(),
                screenId: screenId,
                createdAt: createdAt,
                supersededAt: supersededAt,
                layoutBounds: .zero,
                zoneCount: 0,
                zoneFrames: [:],
                rememberedTiledWindowSizesByZoneIndex: [:],
                zoneAssignments: [:],
                floatingZoneOccupant: nil,
                floatingZoneFrame: nil,
                activeWindowId: nil,
                thumbnail: nil
            )
        }

        let base = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let disconnectedAt = base.addingTimeInterval(500)
        // Removed display 2: live front (created at +450) over a superseded older one (+100).
        let removedLive = snapshot(screenId: 2, createdAt: base.addingTimeInterval(450))
        let removedOlder = snapshot(screenId: 2, createdAt: base.addingTimeInterval(100), supersededAt: base.addingTimeInterval(450))
        // Host display 1: live front (+400, older than the removed display's) over a superseded one (+200).
        let hostLive = snapshot(screenId: 1, createdAt: base.addingTimeInterval(400))
        let hostOlder = snapshot(screenId: 1, createdAt: base.addingTimeInterval(200), supersededAt: base.addingTimeInterval(400))

        assert(
            snapshot(screenId: 1, createdAt: base, supersededAt: base).hasBeenSuperseded,
            "a snapshot superseded the instant it was created reads as superseded"
        )

        let afterRemoval = WinShotDisplayMergePolicy.lists(
            afterDisconnecting: 2,
            into: 1,
            disconnectedAt: disconnectedAt,
            from: [1: [hostLive, hostOlder], 2: [removedLive, removedOlder]]
        )
        let merged = afterRemoval[1] ?? []
        assert(afterRemoval[2] == nil, "the removed display no longer has a list of its own")
        assert(
            merged.map(\.id) == [removedLive.id, hostLive.id, hostOlder.id, removedOlder.id],
            "merged list interleaves both displays newest-first by creation time"
        )
        assert(
            merged.first(where: { $0.id == removedLive.id })?.supersededAt == disconnectedAt,
            "the removed display's live arrangement ends at the disconnect"
        )
        assert(
            merged.first(where: { $0.id == removedOlder.id })?.supersededAt == base.addingTimeInterval(450),
            "an already superseded snapshot keeps its last-on-screen time"
        )
        assert(
            merged.first(where: { !$0.hasBeenSuperseded })?.id == hostLive.id && merged.first?.screenId == 2,
            "the host's live arrangement stays live behind the newer merged snapshot"
        )
        assert(
            merged.filter { $0.screenId == 2 }.allSatisfy(\.hasBeenSuperseded),
            "no merged snapshot reads as live on the host"
        )

        // No display remains to host: the list stays in place, its live arrangement still stamped.
        let noHost = WinShotDisplayMergePolicy.lists(
            afterDisconnecting: 2,
            into: nil,
            disconnectedAt: disconnectedAt,
            from: [2: [removedLive, removedOlder]]
        )
        assert(
            noHost[2]?.map(\.id) == [removedLive.id, removedOlder.id]
                && noHost[2]?.first?.supersededAt == disconnectedAt,
            "without a host the snapshots stay put and the live arrangement still ends at the disconnect"
        )

        // A removed list whose front was already superseded (its live arrangement's snapshot was
        // removed earlier) is not re-stamped.
        let staleFront = snapshot(screenId: 2, createdAt: base, supersededAt: base.addingTimeInterval(50))
        let mergedStale = WinShotDisplayMergePolicy.lists(
            afterDisconnecting: 2, into: 1, disconnectedAt: disconnectedAt, from: [2: [staleFront]]
        )
        assert(
            mergedStale[1]?.first?.supersededAt == base.addingTimeInterval(50),
            "a stale front snapshot is not re-stamped at the disconnect"
        )
        assert(
            WinShotDisplayMergePolicy.lists(afterDisconnecting: 2, into: 1, disconnectedAt: disconnectedAt, from: [1: [hostLive]])[1]?.count == 1,
            "removing a display without snapshots leaves the host untouched"
        )

        // MARK: Reconnecting

        // Captured on the host while display 2 was away: belongs to the host and stays there.
        let hostWhileMerged = snapshot(screenId: 1, createdAt: base.addingTimeInterval(600))
        let afterReconnect = WinShotDisplayMergePolicy.lists(
            afterConnecting: 2,
            from: [1: [hostWhileMerged] + merged]
        )
        assert(
            afterReconnect[2]?.map(\.id) == [removedLive.id, removedOlder.id],
            "a reconnected display gets back its own snapshots, newest-first"
        )
        assert(
            afterReconnect[1]?.map(\.id) == [hostWhileMerged.id, hostLive.id, hostOlder.id],
            "the host keeps its own snapshots, including those captured while hosting"
        )
        assert(
            WinShotDisplayMergePolicy.lists(afterConnecting: 3, from: [1: merged])[3] == nil,
            "a display with no snapshots anywhere gets no list"
        )
        let scattered = WinShotDisplayMergePolicy.lists(
            afterConnecting: 2,
            from: [1: [removedOlder], 3: [removedLive]]
        )
        assert(
            scattered[2]?.map(\.id) == [removedLive.id, removedOlder.id] && scattered[1] == nil && scattered[3] == nil,
            "reconnecting gathers a display's snapshots from every list and drops emptied lists"
        )

        // Cascade: display 2 merged onto 1, then 1 onto 3. Display 1's live arrangement sits behind the
        // newer merged snapshot, and is still the one stamped. Reconnecting 2 pulls its snapshots out
        // of 3's list; display 1's stay there until 1 itself returns.
        let cascaded = WinShotDisplayMergePolicy.lists(
            afterDisconnecting: 1, into: 3, disconnectedAt: base.addingTimeInterval(700), from: afterRemoval
        )
        assert(
            cascaded[3]?.first(where: { $0.id == hostLive.id })?.supersededAt == base.addingTimeInterval(700)
                && cascaded[3]?.first(where: { $0.id == removedLive.id })?.supersededAt == disconnectedAt,
            "disconnecting a host stamps its own live arrangement, not the merged snapshot ahead of it"
        )
        let cascadeReconnect2 = WinShotDisplayMergePolicy.lists(afterConnecting: 2, from: cascaded)
        assert(
            cascadeReconnect2[2]?.map(\.id) == [removedLive.id, removedOlder.id]
                && cascadeReconnect2[3]?.map(\.id) == [hostLive.id, hostOlder.id],
            "a display reconnecting after a cascade of merges reclaims its snapshots from the final host"
        )
        let cascadeReconnect1 = WinShotDisplayMergePolicy.lists(afterConnecting: 1, from: cascadeReconnect2)
        assert(
            cascadeReconnect1[1]?.map(\.id) == [hostLive.id, hostOlder.id] && cascadeReconnect1[3] == nil,
            "the intermediate host reclaims its own snapshots when it returns"
        )

        if allPassed {
            print("WinShotDisplayMergePolicyTests: all tests passed")
        }
        return allPassed
    }
}
