import Foundation

/// Guardrail tests for deferred-prune bookkeeping and per-process clearing rules.
enum PendingPrunedWindowStoreTests {
    @discardableResult
    static func run() -> Bool {
        var allPassed = true

        func assert(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() {
                print("PendingPrunedWindowStoreTests: \(message)")
                allPassed = false
            }
        }

        let pidA: pid_t = 101
        let pidB: pid_t = 202
        let date1 = Date(timeIntervalSince1970: 100)
        let date2 = Date(timeIntervalSince1970: 200)
        let now = Date(timeIntervalSince1970: 1_000)

        do {
            var store = PendingPrunedWindowStore()
            let identifier = ExternalWindowIdentifier(pid: pidA, cgWindowId: 11)
            let destination = PendingPrunedWindowDestination.tiled(
                ZoneKey(screenId: 77, index: 2)
            )

            store.stage(
                identifier: identifier,
                windowId: 7,
                lastActiveTime: date1,
                preferredDestination: destination
            )
            let restored = store.restoreMatch(for: identifier)

            assert(restored?.identifier == identifier, "restore should return the matching identifier")
            assert(restored?.windowId == 7, "restore should preserve the original window id")
            assert(restored?.lastActiveTime == date1, "restore should preserve recency metadata")
            assert(restored?.preferredDestination == destination, "restore should preserve the original preferred destination")
            assert(store.restoreMatch(for: identifier) == nil, "restored entry should be removed from the store")
        }

        do {
            var store = PendingPrunedWindowStore()
            let identifier = ExternalWindowIdentifier(pid: pidA, cgWindowId: 22)

            store.stage(
                identifier: identifier,
                windowId: 8,
                lastActiveTime: date1,
                preferredDestination: .tiled(ZoneKey(screenId: 1, index: 1))
            )
            store.stage(
                identifier: identifier,
                windowId: 9,
                lastActiveTime: date2,
                preferredDestination: .floating(2)
            )

            let restored = store.restoreMatch(for: identifier)
            assert(restored?.windowId == 9, "staging the same identifier again should replace the old window id")
            assert(restored?.lastActiveTime == date2, "staging the same identifier again should replace recency metadata")
            assert(restored?.preferredDestination == .floating(2), "staging the same identifier again should replace preferred destination")
        }

        do {
            var store = PendingPrunedWindowStore()
            let samePidA = ExternalWindowIdentifier(pid: pidA, cgWindowId: 31)
            let samePidB = ExternalWindowIdentifier(pid: pidA, cgWindowId: 32)
            let otherPid = ExternalWindowIdentifier(pid: pidB, cgWindowId: 41)

            store.stage(identifier: samePidA, windowId: 3, lastActiveTime: date1, preferredDestination: nil)
            store.stage(identifier: samePidB, windowId: 4, lastActiveTime: nil, preferredDestination: .floating(4))
            store.stage(identifier: otherPid, windowId: 5, lastActiveTime: date2, preferredDestination: .tiled(ZoneKey(screenId: 5, index: 1)))

            assert(store.hasEntries(forPid: pidA), "store should report pending entries for pid A")
            assert(store.hasEntries(forPid: pidB), "store should report pending entries for pid B")

            let cleared = store.clear(forPid: pidA)
            assert(cleared.map(\.windowId) == [3, 4], "clearing a pid should remove only that pid's pending entries")
            assert(!store.hasEntries(forPid: pidA), "clearing a pid should exhaust that pid's entries")
            assert(store.hasEntries(forPid: pidB), "clearing one pid should not affect another pid")
            assert(store.restoreMatch(for: otherPid)?.windowId == 5, "entries for other pids should remain restorable")
        }

        do {
            var store = PendingPrunedWindowStore()
            let recent = ExternalWindowIdentifier(pid: pidA, cgWindowId: 51)
            let old = ExternalWindowIdentifier(pid: pidA, cgWindowId: 52)
            let oldOtherPid = ExternalWindowIdentifier(pid: pidB, cgWindowId: 61)

            store.stage(
                identifier: recent,
                windowId: 11,
                lastActiveTime: nil,
                preferredDestination: nil,
                stagedAt: now.addingTimeInterval(-1.0)
            )
            store.stage(
                identifier: old,
                windowId: 12,
                lastActiveTime: nil,
                preferredDestination: nil,
                stagedAt: now.addingTimeInterval(-3.0)
            )
            store.stage(
                identifier: oldOtherPid,
                windowId: 13,
                lastActiveTime: nil,
                preferredDestination: nil,
                stagedAt: now.addingTimeInterval(-3.0)
            )

            let cleared = store.clearForNewManagedWindow(pid: pidA, now: now, graceInterval: 2.0)
            assert(cleared.map(\.windowId) == [12], "new-window cleanup should clear old entries for the pid")
            assert(store.restoreMatch(for: recent)?.windowId == 11, "new-window cleanup should preserve very recent entries")
            assert(store.restoreMatch(for: oldOtherPid)?.windowId == 13, "new-window cleanup should not clear entries for other pids")
        }

        if allPassed {
            print("PendingPrunedWindowStoreTests: all tests passed")
        }
        return allPassed
    }
}
