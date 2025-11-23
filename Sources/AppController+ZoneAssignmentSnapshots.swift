import Foundation
import AppKit
import ApplicationServices

/// Persists tiled zone assignments across sleep/wake.
extension AppController {
    struct ZoneAssignmentSnapshot {
        let zoneKey: ZoneKey
        let identity: WindowIdentity
    }

    func snapshotZoneAssignments(reason: String) {
        // Only snapshot assignments for non-placeholder windows that are still
        // tracked and currently associated with a tiled zone on the expected screen.
        pendingZoneAssignmentSnapshots = liveZoneAssignments.filter { key, snapshot in
            guard let window = windowController.window(withId: snapshot.identity.windowId) else {
                return false
            }
            if window.isPlaceholder {
                return false
            }
            if window.zoneIndex == nil {
                return false
            }
            if window.screenDisplayId != key.screenId {
                return false
            }
            return true
        }
        if !pendingZoneAssignmentSnapshots.isEmpty {
            Logger.debug("Snapshot \(pendingZoneAssignmentSnapshots.count) zone assignment(s) for \(reason)")
        } else {
            Logger.debug("Snapshot 0 zone assignments for \(reason) (none eligible)")
        }
    }

    func restoreZoneAssignmentsFromExistingWindows(reason: String) {
        guard !pendingZoneAssignmentSnapshots.isEmpty else {
            return
        }

        var remaining: [ZoneKey: ZoneAssignmentSnapshot] = [:]
        for (key, snapshot) in pendingZoneAssignmentSnapshots {
            if attemptZoneAssignmentRestoration(using: snapshot, reason: reason) {
                liveZoneAssignments[key] = snapshot
            } else {
                remaining[key] = snapshot
            }
        }
        pendingZoneAssignmentSnapshots = remaining
    }

    func handleZoneAssignmentRestorationIfNeeded(_ managed: ManagedWindow) -> Bool {
        guard let (key, snapshot) = matchingZoneAssignmentSnapshot(for: managed) else {
            return false
        }
        if attemptZoneAssignmentRestoration(with: managed, snapshot: snapshot, reason: "wake-restore") {
            pendingZoneAssignmentSnapshots.removeValue(forKey: key)
            return true
        }
        return false
    }

    private func attemptZoneAssignmentRestoration(using snapshot: ZoneAssignmentSnapshot, reason: String) -> Bool {
        guard let managed = resolveManagedWindow(for: snapshot) else {
            return false
        }
        return attemptZoneAssignmentRestoration(with: managed, snapshot: snapshot, reason: reason)
    }

    private func attemptZoneAssignmentRestoration(
        with managed: ManagedWindow,
        snapshot: ZoneAssignmentSnapshot,
        reason: String
    ) -> Bool {
        let key = snapshot.zoneKey
        guard let context = screenContexts[key.screenId],
              let zone = context.zoneController.zone(at: key.index) else {
            Logger.debug("Zone snapshot for screen \(screenContextStore.loggingIndex(for: key.screenId)) zone \(key.index) dropped (zone missing)")
            return true
        }

        if zone.windowId == managed.windowId {
            return true
        }

        windowPlacementManager.placeWindow(
            managed,
            into: key,
            reason: "zone-snapshot-\(reason)"
        )

        let screenIndex = screenContextStore.loggingIndex(for: key.screenId)
        Logger.debug("Restored zone snapshot: window \(managed.windowId) -> screen \(screenIndex) zone \(key.index) (reason: \(reason))")
        pendingZoneAssignmentSnapshots.removeValue(forKey: key)
        liveZoneAssignments[key] = ZoneAssignmentSnapshot(zoneKey: key, identity: .make(from: managed))
        return true
    }

    private func matchingZoneAssignmentSnapshot(
        for managed: ManagedWindow
    ) -> (ZoneKey, ZoneAssignmentSnapshot)? {
        for (key, snapshot) in pendingZoneAssignmentSnapshots {
            if snapshot.identity.matches(managed) {
                return (key, snapshot)
            }
        }
        return nil
    }

    private func resolveManagedWindow(for snapshot: ZoneAssignmentSnapshot) -> ManagedWindow? {
        if let window = windowController.window(withId: snapshot.identity.windowId) {
            return window
        }
        if let identifier = snapshot.identity.externalIdentifier {
            return windowController.allWindows.first { candidate in
                candidate.externalIdentifier == identifier
            }
        }
        return nil
    }
}
