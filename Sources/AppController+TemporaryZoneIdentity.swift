import Foundation
import AppKit
import ApplicationServices

/// Sleep/wake persistence helpers for temporary-zone occupants.
extension AppController {

    func snapshotTemporaryZoneOccupants(reason: String) {
        var snapshot: [CGDirectDisplayID: TemporaryZoneIdentitySnapshot] = [:]

        for (screenId, windowId) in temporaryZoneCoordinator.occupants {
            guard let managed = windowController.window(withId: windowId) else {
                continue
            }

            snapshot[screenId] = TemporaryZoneIdentitySnapshot(
                screenId: screenId,
                identity: .make(from: managed)
            )
        }

        // Only overwrite the pending snapshot when we have at least one active
        // temporary-zone occupant. This prevents spurious sleep notifications
        // that arrive with no occupants (often during wake-induced display
        // reconfiguration) from discarding a valid pre-sleep snapshot.
        if !snapshot.isEmpty {
            pendingTemporaryZoneIdentitySnapshots = snapshot
            Logger.debug("Snapshot \(snapshot.count) temporary zone occupant(s) for \(reason)")

            // Log snapshot contents so it is clear which floating windows are
            // expected to be restored after wake.
            let details = snapshot.map { screenId, entry in
                let screenIndex = screenContextStore.loggingIndex(for: screenId)
                let identity = entry.identity
                let bundle = identity.bundleIdentifier ?? "unknown"
                let title = identity.windowTitle ?? "unknown"
                return "screen \(screenIndex) temporary -> windowId \(identity.windowId) (bundle: \(bundle), title: \(title))"
            }
            Logger.debug("Temporary zone snapshot details (\(reason)): \(details.joined(separator: "; "))")
        } else if pendingTemporaryZoneIdentitySnapshots.isEmpty {
            Logger.debug("Snapshot 0 temporary zone occupant(s) for \(reason) (none eligible)")
        } else {
            Logger.debug(
                "Snapshot 0 temporary zone occupant(s) for \(reason) (none eligible; preserving \(pendingTemporaryZoneIdentitySnapshots.count) existing snapshot(s))"
            )
        }
    }

    func restoreTemporaryZoneOccupantsFromExistingWindows(reason: String) {
        guard !pendingTemporaryZoneIdentitySnapshots.isEmpty else {
            return
        }

        var remaining: [CGDirectDisplayID: TemporaryZoneIdentitySnapshot] = [:]
        var restored = 0

        for (screenId, entry) in pendingTemporaryZoneIdentitySnapshots {
            if let occupant = temporaryZoneOccupant(on: screenId),
               entry.identity.matches(occupant) {
                Logger.debug("Temporary zone occupant \(entry.windowId) already present on screen \(screenContextStore.loggingIndex(for: screenId)) (reason: \(reason))")
                continue
            }

            if let managed = resolveManagedWindow(for: entry.identity) {
                assignWindowToTemporaryZone(
                    managed,
                    on: screenId,
                    centerWindow: false,
                    reason: reason
                )
                applyWakeTemporaryZoneBehaviorIfNeeded(managed, reason: reason)
                restored += 1
            } else {
                remaining[screenId] = entry
                let identity = entry.identity
                let bundle = identity.bundleIdentifier ?? "unknown"
                let title = identity.windowTitle ?? "unknown"
                let screenIndex = screenContextStore.loggingIndex(for: screenId)
                Logger.debug(
                    "Temporary zone snapshot still pending for screen \(screenIndex): " +
                    "windowId \(identity.windowId) (bundle: \(bundle), title: \(title)) not yet recaptured (reason: \(reason))"
                )
            }
        }

        pendingTemporaryZoneIdentitySnapshots = remaining

        let pendingCount = pendingTemporaryZoneIdentitySnapshots.count
        if restored > 0 || pendingCount > 0 {
            Logger.debug(
                "Temporary zone restore summary (reason: \(reason)): " +
                "restored \(restored), pending \(pendingCount) snapshot(s)"
            )
        }
    }

    func handleTemporaryZoneRestorationIfNeeded(_ managed: ManagedWindow) -> Bool {
        guard !pendingTemporaryZoneIdentitySnapshots.isEmpty,
              let (screenId, entry) = matchingTemporaryZoneSnapshot(for: managed) else {
            return false
        }

        let restoreReason = "wake-restore"
        assignWindowToTemporaryZone(
            managed,
            on: screenId,
            centerWindow: false,
            reason: restoreReason
        )
        pendingTemporaryZoneIdentitySnapshots.removeValue(forKey: screenId)
        applyWakeTemporaryZoneBehaviorIfNeeded(managed, reason: restoreReason)
        let screenIndex = screenContextStore.loggingIndex(for: screenId)
        Logger.debug(
            "Restored temporary zone occupant to screen \(screenIndex) (windowId: \(managed.windowId), title: \(entry.windowTitle ?? "unknown"))"
        )

        return true
    }

    private func matchingTemporaryZoneSnapshot(for managed: ManagedWindow) -> (CGDirectDisplayID, TemporaryZoneIdentitySnapshot)? {
        for (screenId, entry) in pendingTemporaryZoneIdentitySnapshots {
            if entry.identity.matches(managed) {
                return (screenId, entry)
            }
        }
        return nil
    }

    private func resolveManagedWindow(for identity: WindowIdentity) -> ManagedWindow? {
        if let window = windowController.window(withId: identity.windowId) {
            return window
        }
        if let identifier = identity.externalIdentifier {
            return windowController.allWindows.first { $0.externalIdentifier == identifier }
        }
        return nil
    }
}

// MARK: - Wake protection helpers

extension AppController {
    internal func shouldProtectTemporaryZoneOccupant(windowId: Int) -> Bool {
        guard let deadline = temporaryZoneWakeProtectionDeadlines[windowId] else {
            return false
        }
        if Date() < deadline {
            return true
        }
        temporaryZoneWakeProtectionDeadlines.removeValue(forKey: windowId)
        return false
    }

    internal func clearTemporaryZoneWakeProtection(windowId: Int) {
        temporaryZoneWakeProtectionDeadlines.removeValue(forKey: windowId)
    }

    internal func scheduleTemporaryZoneWakeProtection(windowId: Int) {
        temporaryZoneWakeProtectionDeadlines[windowId] = Date().addingTimeInterval(temporaryZoneWakeProtectionDuration)
    }

    private func applyWakeTemporaryZoneBehaviorIfNeeded(_ managed: ManagedWindow, reason: String) {
        guard reason.contains("wake") else { return }
        scheduleTemporaryZoneWakeProtection(windowId: managed.windowId)
        bringTemporaryZoneWindowToFront(managed)
    }

    private func bringTemporaryZoneWindowToFront(_ managed: ManagedWindow) {
        guard !managed.isPlaceholder else { return }
        windowController.unminimizeWindow(managed)

        switch managed.backing {
        case .appKit(let window):
            window.makeKeyAndOrderFront(nil)
        case .accessibility(_, let pid, _) where pid != getpid():
            if let application = NSRunningApplication(processIdentifier: pid) {
                application.activate(options: [.activateIgnoringOtherApps])
            }
        case .accessibility:
            break
        }
    }
}

private extension AppController.TemporaryZoneIdentitySnapshot {
    var windowId: Int { identity.windowId }
    var windowTitle: String? { identity.windowTitle }
}
