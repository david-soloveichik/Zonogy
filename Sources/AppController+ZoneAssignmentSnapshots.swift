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
        let candidateSnapshots = liveZoneAssignments.filter { key, snapshot in
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

        // If we found eligible assignments, replace the pending snapshot with the
        // current state. If not, *preserve* any existing snapshot so that spurious
        // sleep notifications that fire while no windows are managed (e.g. during
        // wake-related display churn) do not erase the last real layout.
        if !candidateSnapshots.isEmpty {
            pendingZoneAssignmentSnapshots = candidateSnapshots
            Logger.debug("Snapshot \(pendingZoneAssignmentSnapshots.count) zone assignment(s) for \(reason)")

            // Log a concise summary of the snapshot contents to make sleep/wake
            // behavior easier to interpret in time-travel logs.
            let details = pendingZoneAssignmentSnapshots.map { key, snapshot in
                let screenIndex = screenContextStore.loggingIndex(for: key.screenId)
                let identity = snapshot.identity
                let bundle = identity.bundleIdentifier ?? "unknown"
                let title = identity.windowTitle ?? "unknown"
                return "screen \(screenIndex) zone \(key.index) -> windowId \(identity.windowId) (bundle: \(bundle), title: \(title))"
            }
            Logger.debug("Zone assignment snapshot details (\(reason)): \(details.joined(separator: "; "))")
        } else {
            if pendingZoneAssignmentSnapshots.isEmpty {
                Logger.debug("Snapshot 0 zone assignments for \(reason) (none eligible)")
            } else {
                Logger.debug(
                    "Snapshot 0 zone assignments for \(reason) (none eligible; preserving \(pendingZoneAssignmentSnapshots.count) existing snapshot(s))"
                )
            }
        }
    }

    func restoreZoneAssignmentsFromExistingWindows(reason: String) {
        guard !pendingZoneAssignmentSnapshots.isEmpty else {
            return
        }

        var remaining: [ZoneKey: ZoneAssignmentSnapshot] = [:]
        var restored = 0
        for (key, snapshot) in pendingZoneAssignmentSnapshots {
            if attemptZoneAssignmentRestoration(using: snapshot, reason: reason) {
                liveZoneAssignments[key] = snapshot
                restored += 1
            } else {
                remaining[key] = snapshot
            }
        }
        pendingZoneAssignmentSnapshots = remaining

        let pendingCount = pendingZoneAssignmentSnapshots.count
        if restored > 0 || pendingCount > 0 {
            Logger.debug(
                "Zone assignment restore summary (reason: \(reason)): " +
                "restored \(restored), pending \(pendingCount) snapshot(s)"
            )
        }
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
            let identity = snapshot.identity
            let bundle = identity.bundleIdentifier ?? "unknown"
            let title = identity.windowTitle ?? "unknown"
            let key = snapshot.zoneKey
            let screenIndex = screenContextStore.loggingIndex(for: key.screenId)
            Logger.debug(
                "Zone snapshot still pending for screen \(screenIndex) zone \(key.index): " +
                "windowId \(identity.windowId) (bundle: \(bundle), title: \(title)) not yet recaptured (reason: \(reason))"
            )
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
        guard let context = screenContexts[key.screenId] else {
            let screenIndex = screenContextStore.loggingIndex(for: key.screenId)
            Logger.debug("Zone snapshot for screen \(screenIndex) zone \(key.index) dropped (screen missing)")
            return true
        }

        let zoneController = context.zoneController

        // If the target zone no longer exists on an otherwise-present screen, recreate
        // zones up to the requested index so we can faithfully restore the layout
        // captured before sleep.
        if zoneController.zone(at: key.index) == nil {
            let existingCount = zoneController.allZones.count
            let desiredCount = max(existingCount, key.index)

            if desiredCount <= 3 {
                zoneController.setZoneCount(to: desiredCount)
                let screenIndex = screenContextStore.loggingIndex(for: key.screenId)
                Logger.debug(
                    "Recreated missing zone \(key.index) on screen \(screenIndex) for snapshot (zone count \(existingCount) -> \(zoneController.allZones.count))"
                )
            }
        }

        guard let zone = zoneController.zone(at: key.index) else {
            let screenIndex = screenContextStore.loggingIndex(for: key.screenId)
            Logger.debug("Zone snapshot for screen \(screenIndex) zone \(key.index) dropped (zone still missing)")
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
