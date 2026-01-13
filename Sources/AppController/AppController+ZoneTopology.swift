import Foundation
import AppKit
import ApplicationServices

/// Zone topology operations: adding, removing, and resizing zones.
extension AppController {
    func addZone() {
        let screenId = activeScreenId()
        _ = addZone(on: screenId, announce: true, promoteTemporaryOccupant: true)
    }

    @discardableResult
    internal func addZone(
        on screenId: CGDirectDisplayID,
        announce: Bool = true,
        promoteTemporaryOccupant: Bool = true
    ) -> Zone? {
        // Special-case: if this screen is in UnderCovers and has a single empty zone 1,
        // treat the first "add zone" invocation as exiting UnderCovers without changing zone count.
        if let context = screenContexts[screenId] {
            let zones = context.zoneController.allZones
            if isUnderCoversActive(on: screenId),
               zones.count == 1,
               let zone = zones.first,
               zone.index == 1,
               zone.isEmpty {
                Logger.debug("Add zone invoked while UnderCovers active on screen \(screenContextStore.loggingIndex(for: screenId)); exiting UnderCovers without adding a new zone")
                endUnderCovers(on: screenId, reason: "add-zone-exit-undercovers", recreatePlaceholders: true)
                return zone
            }
        }

        // Any shortcut or command adding a zone to this screen should exit UnderCovers otherwise.
        endUnderCovers(on: screenId, reason: "add-zone", recreatePlaceholders: false)

        guard let context = screenContexts[screenId],
              let newZone = context.zoneController.addZone() else {
            if announce {
                print("Failed to add zone (max 3 zones)")
            }
            return nil
        }
        // Zone topology has changed; cancel any in-flight accessibility frame retries
        // so they do not apply stale geometry.
        windowController.cancelAllAccessibilityFrameRetries()
        if promoteTemporaryOccupant {
            promoteTemporaryZoneOccupantIfNeeded(on: screenId, newZone: newZone)
        }
        syncWindowsToZones()
        activeFitRefreshAfterZoneTopologyChange(reason: "zone-added")
        let newZoneKey = zoneKey(for: screenId, index: newZone.index)
        if shouldRetarget(to: newZoneKey) {
            targetedZoneManager.setTargetedZone(newZoneKey, reason: "zone-added")
            // If we targeted a zone that's already filled (e.g., from temporary zone promotion),
            // retarget per spec: "Whenever the targeted tiling zone is filled..."
            if targetingMode == .independentOfFocus,
               !targetedZoneManager.isZoneEmpty(newZoneKey) {
                targetedZoneManager.retargetAfterFillingZone(newZoneKey, reason: "zone-added-filled")
            }
        } else {
            targetedZoneManager.ensureTargetedZone(reason: "zone-added")
        }
        if announce {
            print("Added zone \(newZone.index) on \(context.descriptor.localizedName)")
        }
        autoShowLauncherIfEmptyTargetedTiledZone()
        return newZone
    }

    private func promoteTemporaryZoneOccupantIfNeeded(on screenId: CGDirectDisplayID, newZone: Zone) {
        guard newZone.isEmpty,
              let occupant = temporaryZoneOccupant(on: screenId),
              occupant.zoneIndex == nil else {
            return
        }

        let screenIndex = screenContextStore.loggingIndex(for: screenId)
        Logger.debug("Promoting temporary zone window \(occupant.windowId) into new zone \(newZone.index) on screen \(screenIndex)")
        windowPlacementManager.placeWindow(occupant, into: ZoneKey(screenId: screenId, index: newZone.index), reason: "add-zone-promote-temporary")
    }

    func removeZone(at index: Int) {
        let screenId = activeScreenId()
        guard let context = screenContexts[screenId] else {
            print("Active screen not available")
            return
        }

        guard performRemoveZone(at: index, on: screenId, announce: true, context: context) != nil else {
            print("Failed to remove zone \(index)")
            return
        }
    }

    internal func performRemoveZone(
        at index: Int,
        on screenId: CGDirectDisplayID,
        announce: Bool,
        context: ScreenContext? = nil
    ) -> ZoneController.RemovalResult? {
        // Removing a zone on this screen should clear any UnderCovers state there.
        endUnderCovers(on: screenId, reason: "remove-zone", recreatePlaceholders: false)

        // Track if Launcher was active - dismissal decision happens after computing new target
        let launcherWasActive = launcherController.isActive

        let context = context ?? screenContexts[screenId]
        guard let context else {
            return nil
        }

        guard let removalResult = context.zoneController.removeZone(at: index) else {
            return nil
        }

        // Clear placeholders for this screen since zones are being reindexed
        placeholderCoordinator.clearPlaceholdersForScreen(screenId)

        // Zone topology has changed; cancel any in-flight accessibility frame retries
        // so they do not apply stale geometry computed before the removal.
        windowController.cancelAllAccessibilityFrameRetries()

        let currentTarget = targetedZoneKey
        var pendingTargetedKey: ZoneKey?
        var shouldTargetTemporary = false
        if let currentTarget, currentTarget.screenId == screenId {
            if currentTarget.index == index {
                // The targeted zone is being removed, find a fallback
                if let destination = followsFocusTargetOnZoneRemoval(removedIndex: index, removedScreenId: screenId) {
                    switch destination {
                    case .tiled(let key):
                        pendingTargetedKey = key
                    case .temporary(let tempScreenId):
                        targetedZoneManager.setTemporaryTarget(on: tempScreenId, reason: "zone-removed-follows-focus")
                    }
                } else {
                    pendingTargetedKey = targetedZoneManager.fallbackTargetedZoneOnSameScreen(screenId: screenId)
                    if pendingTargetedKey == nil {
                        shouldTargetTemporary = true
                    }
                }
            } else if currentTarget.index > index {
                pendingTargetedKey = ZoneKey(screenId: screenId, index: currentTarget.index - 1)
            }
        }

        // Spec: When Launcher is open and zone is removed:
        // - If another empty tiling zone becomes targeted → keep Launcher open
        // - Otherwise → dismiss Launcher
        if launcherWasActive {
            var newTargetIsEmptyTiledZone = false

            if !shouldTargetTemporary {
                let effectiveTargetKey: ZoneKey?
                if let pending = pendingTargetedKey {
                    effectiveTargetKey = pending
                } else {
                    effectiveTargetKey = currentTarget
                }

                if let key = effectiveTargetKey {
                    newTargetIsEmptyTiledZone = targetedZoneManager.isZoneEmpty(key)
                }
            }

            if !newTargetIsEmptyTiledZone {
                launcherController.hide()
                Logger.debug("Launcher: Dismissed on zone removal (new target is not empty tiling zone)")
            }
        }

        if let pendingTargetedKey {
            targetedZoneManager.setTargetedZone(pendingTargetedKey, reason: "zone-removed")
        } else if shouldTargetTemporary {
            targetedZoneManager.setTemporaryTarget(on: screenId, reason: "zone-removed-no-empty-same-screen")
        }

        if let removedWindowId = removalResult.removedWindowId,
           let managed = windowController.window(withId: removedWindowId) {
            windowPlacementManager.handleWindowAfterZoneRemoval(managed, preferredScreenId: screenId)
        }

        syncWindowsToZones()
        activeFitRefreshAfterZoneTopologyChange(reason: "zone-removed")

        if pendingTargetedKey == nil && !shouldTargetTemporary {
            targetedZoneManager.ensureTargetedZone(reason: "zone-removed")
        }

        if announce {
            print("Removed zone \(index) on \(context.descriptor.localizedName)")
        }

        return removalResult
    }

    func resizeZone(at index: Int, frame: CGRect) {
        let screenId = activeScreenId()
        guard let context = screenContexts[screenId] else {
            print("Active screen not available")
            return
        }

        guard let zone = context.zoneController.zone(at: index) else {
            print("Zone \(index) not found on \(context.descriptor.localizedName)")
            return
        }

        guard zone.isEmpty else {
            print("Zone \(index) is occupied; minimize or close its window before resizing.")
            return
        }

        if context.zoneController.resizeZone(at: index, to: frame) {
            // Zone geometry changed; clear any pending accessibility frame retries
            // since their targets were based on the previous layout.
            windowController.cancelAllAccessibilityFrameRetries()
            syncWindowsToZones()
            if let updatedZone = context.zoneController.zone(at: index) {
                print("Resized zone \(index) on \(context.descriptor.localizedName) to \(updatedZone.frame)")
            } else {
                print("Zone \(index) resized")
            }
        } else {
            print("Failed to resize zone \(index)")
        }
    }
}
