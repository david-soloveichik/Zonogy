import Foundation
import ApplicationServices

/// Pure bookkeeping for windows staged for deferred prune and later identifier reuse.
enum PendingPrunedWindowDestination: Equatable {
    case tiled(ZoneKey)
    case floating(CGDirectDisplayID)
}

/// Pure bookkeeping for windows staged for deferred prune and later identifier reuse.
struct PendingPrunedWindowStore {
    struct Entry: Equatable {
        let identifier: ExternalWindowIdentifier
        let windowId: Int
        let lastActiveTime: Date?
        let preferredDestination: PendingPrunedWindowDestination?
        let stagedAt: Date
    }

    static let samePidNewWindowClearGrace: TimeInterval = 2.0

    private var entriesByIdentifier: [ExternalWindowIdentifier: Entry] = [:]

    mutating func stage(
        identifier: ExternalWindowIdentifier,
        windowId: Int,
        lastActiveTime: Date?,
        preferredDestination: PendingPrunedWindowDestination?,
        stagedAt: Date = Date()
    ) {
        entriesByIdentifier[identifier] = Entry(
            identifier: identifier,
            windowId: windowId,
            lastActiveTime: lastActiveTime,
            preferredDestination: preferredDestination,
            stagedAt: stagedAt
        )
    }

    mutating func restoreMatch(for identifier: ExternalWindowIdentifier) -> Entry? {
        entriesByIdentifier.removeValue(forKey: identifier)
    }

    mutating func clear(forPid pid: pid_t) -> [Entry] {
        clear(forPid: pid) { _ in true }
    }

    mutating func clearForNewManagedWindow(
        pid: pid_t,
        now: Date = Date(),
        graceInterval: TimeInterval = Self.samePidNewWindowClearGrace
    ) -> [Entry] {
        let cutoff = now.addingTimeInterval(-graceInterval)
        return clear(forPid: pid) { entry in
            entry.stagedAt <= cutoff
        }
    }

    private mutating func clear(forPid pid: pid_t, where shouldClear: (Entry) -> Bool) -> [Entry] {
        let identifiers = entriesByIdentifier
            .filter { identifier, entry in
                identifier.pid == pid && shouldClear(entry)
            }
            .map(\.key)
        guard !identifiers.isEmpty else {
            return []
        }

        var removed: [Entry] = []
        removed.reserveCapacity(identifiers.count)
        for identifier in identifiers {
            if let entry = entriesByIdentifier.removeValue(forKey: identifier) {
                removed.append(entry)
            }
        }
        return removed.sorted { lhs, rhs in
            if lhs.windowId != rhs.windowId {
                return lhs.windowId < rhs.windowId
            }
            return lhs.identifier.cgWindowId < rhs.identifier.cgWindowId
        }
    }

    func hasEntries(forPid pid: pid_t) -> Bool {
        entriesByIdentifier.keys.contains { $0.pid == pid }
    }

    func hasEntry(forWindowId windowId: Int) -> Bool {
        entriesByIdentifier.values.contains { $0.windowId == windowId }
    }
}
