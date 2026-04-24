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
    }

    private var entriesByIdentifier: [ExternalWindowIdentifier: Entry] = [:]

    mutating func stage(
        identifier: ExternalWindowIdentifier,
        windowId: Int,
        lastActiveTime: Date?,
        preferredDestination: PendingPrunedWindowDestination?
    ) {
        entriesByIdentifier[identifier] = Entry(
            identifier: identifier,
            windowId: windowId,
            lastActiveTime: lastActiveTime,
            preferredDestination: preferredDestination
        )
    }

    mutating func restoreMatch(for identifier: ExternalWindowIdentifier) -> Entry? {
        entriesByIdentifier.removeValue(forKey: identifier)
    }

    mutating func clear(forPid pid: pid_t) -> [Entry] {
        let identifiers = entriesByIdentifier.keys.filter { $0.pid == pid }
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
