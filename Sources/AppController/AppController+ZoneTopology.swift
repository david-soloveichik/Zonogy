import Foundation
import AppKit
import ApplicationServices

/// Zone topology operations: adding, removing, and resizing zones.
extension AppController {
    func addZone() {
        let screenId = activeScreenId()
        _ = addZone(on: screenId, announce: true)
    }

    /// Add a zone on `side` (the clicked add-zone bar's edge); a nil side uses the layout
    /// style's preferred fill order (keyboard shortcut and other side-agnostic paths).
    @discardableResult
    internal func addZone(
        on screenId: CGDirectDisplayID,
        side: ZoneSide? = nil,
        announce: Bool = true,
        promoteFloatingOccupant: Bool = true
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
              let newZone = context.zoneController.addZone(preferredSide: side) else {
            if announce {
                let maxZones = screenContexts[screenId]?.zoneController.layoutStyle.maxZoneCount ?? 3
                print("Failed to add zone (max \(maxZones) zones)")
            }
            return nil
        }
        // Zone topology has changed; cancel any in-flight accessibility frame retries
        // so they do not apply stale geometry.
        windowController.cancelAllAccessibilityFrameRetries()
        clearRememberedManualResizeSizes(on: screenId, reason: "zone-added")
        // Creating a zone targets the new zone, but that retarget should not flash the border: the
        // new placeholder appears at the same moment, and an added flash looks wrong on creation.
        withTargetChangeFlashSuppressed {
            targetedZoneManager.targetAfterCreatingZone(on: screenId, reason: "zone-added")
            if promoteFloatingOccupant {
                promoteFloatingOccupantIfOverlapping(on: screenId, zone: newZone, context: context)
            }
            syncWindowsToZones()
            activeFitRefreshAfterZoneTopologyChange(reason: "zone-added")
        }
        if announce {
            print("Added zone \(newZone.index) on \(context.descriptor.localizedName)")
        }
        autoShowLauncherIfEmptyTargetedTiledZone()
        return newZone
    }

    private func promoteFloatingOccupantIfOverlapping(on screenId: CGDirectDisplayID, zone: Zone, context: ScreenContext) {
        guard zone.isEmpty,
              let occupant = floatingZoneOccupant(on: screenId),
              let occupantFrame = windowController.actualFrameInAccessibilityCoordinates(for: occupant) else {
            return
        }
        let zoneFrame = context.descriptor.screenToAccessibility(zone.frame)
        guard FloatingZoneOverlapPolicy.overlapsZoneFrame(
            floatingFrame: occupantFrame,
            zoneFrame: zoneFrame
        ) else {
            return
        }
        let screenIndex = screenContextStore.loggingIndex(for: screenId)
        Logger.debug("Promoting floating zone occupant \(occupant.windowId) into new zone \(zone.index) on screen \(screenIndex): overlaps zone frame")
        // Explicit floating→tile promotion: don't retarget on removal of the floating source.
        windowPlacementManager.placeWindow(
            occupant,
            into: .tiled(ZoneKey(screenId: screenId, index: zone.index)),
            centerFloatingWindow: true,
            reason: "add-zone-promote-overlap",
            retargetOnRemoval: false,
            forceRetargetAfterFill: false
        )
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

        clearRememberedManualResizeSizes(on: screenId, reason: "zone-removed")

        // Clear placeholders for this screen since zones are being reindexed
        placeholderCoordinator.clearPlaceholdersForScreen(screenId)

        // Zone topology has changed; cancel any in-flight accessibility frame retries
        // so they do not apply stale geometry computed before the removal.
        windowController.cancelAllAccessibilityFrameRetries()

        let currentTarget = targetedZoneKey
        let destinationBefore = targetedZoneManager.targetedDestination
        var pendingDestination: TargetedZoneManager.TargetedDestination?
        if let currentTarget, currentTarget.screenId == screenId {
            if currentTarget.index == index {
                pendingDestination = targetedZoneManager.preferredRetargetDestination(
                    preferredSameScreenId: screenId
                )
            } else if currentTarget.index > index {
                pendingDestination = .tiled(ZoneKey(screenId: screenId, index: currentTarget.index - 1))
            }
        }

        // Spec: Launcher is always anchored to the current target. When that targeted zone is removed:
        // - If another empty tiling zone becomes targeted → keep Launcher open
        // - Otherwise → dismiss Launcher
        if launcherWasActive {
            let effectiveDestination = pendingDestination ?? targetedZoneManager.targetedDestination
            enforceLauncherVisibilityAfterZoneTopologyChange(
                effectiveDestination: effectiveDestination,
                reason: "zone removal"
            )
        }

        if let pendingDestination {
            switch pendingDestination {
            case .tiled(let key):
                targetedZoneManager.setTargetedZone(key, reason: "zone-removed")
            case .floating(let floatingScreenId):
                targetedZoneManager.setFloatingTarget(on: floatingScreenId, reason: "zone-removed")
            }
        }

        if let removedWindowId = removalResult.removedWindowId,
           let managed = windowController.window(withId: removedWindowId) {
            windowPlacementManager.handleWindowAfterZoneRemoval(managed)
        }

        syncWindowsToZones()
        activeFitRefreshAfterZoneTopologyChange(reason: "zone-removed")

        if pendingDestination == nil {
            targetedZoneManager.ensureTargetedZone(reason: "zone-removed")
        }

        // The standard target-change flash (via `targetedZoneDidChange`) already confirms every
        // removal that moves the target. Cover the one case it cannot see — a target that survived on
        // this screen with its index unchanged (e.g. removing a higher-index zone) — by confirming it
        // explicitly here, so a removal's confirmation is symmetric regardless of reindexing. Mirrors
        // the re-affirm flash in `retargetForUserGesture`; a same-screen survivor fires no change
        // event, so this never double-flashes with the standard one.
        let targetSurvivedInPlace = targetedZoneManager.targetedDestination == destinationBefore
        let targetOnRemovalScreen = destinationBefore.flatMap { self.screenId(for: $0) } == screenId
        if hasCompletedInitialStartup, !suppressTargetChangeFlash,
           targetSurvivedInPlace, targetOnRemovalScreen {
            flashCurrentTargetFeedback()
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
            clearRememberedManualResizeSizes(on: screenId, reason: "zone-resized-command")
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
