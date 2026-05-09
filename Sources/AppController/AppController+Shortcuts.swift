import Foundation
import AppKit

/// Dispatches global hotkey actions (add/remove zone, targeting, minimize, Launcher, etc.).
extension AppController {
    internal func triggerShortcut(_ action: HotkeyService.Action) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            switch action {
            case .addZone:
                self.addZone()
            case .removeZone:
                _ = self.performShortcutZoneRemoval(on: self.activeScreenId())
            case .collapseToOneZone:
                self.collapseToOneZoneShortcut()
            case .captureTimeTravelLogs:
                self.captureTimeTravelLogs(triggerReason: "shortcut")
            case .clearOrResetZones:
                self.clearOrResetZones()
            case .clearOrResetZonesAtCursor:
                self.clearOrResetZonesAtCursor()
            case .targetFloatingZone:
                self.targetFloatingZone()
            case .targetTilingZone:
                self.targetTilingZone()
            case .navigateLeft:
                self.navigateLeft()
            case .navigateRight:
                self.navigateRight()
            case .focusTargetedWindow:
                self.focusTargetedWindow()
            case .minimizeActiveWindow:
                // If Launcher is open and targeting a tiled zone, remove that zone instead.
                // If only 1 zone on screen, just hide Launcher (don't enter UnderCovers).
                if self.launcherController.isActive {
                    self.launcherControllerDidRequestRemoveZone(self.launcherController)
                } else {
                    self.minimizeActiveWindow()
                }
            case .minimizeWindowOrRemoveZoneAtCursor:
                self.minimizeWindowOrRemoveZoneAtCursor()
            case .saveWinShotSnapshot:
                self.saveWinShotSnapshot()
            case .showWinShotChooser:
                self.showWinShotChooser()
            case .showLauncher:
                self.showLauncher()
            }
        }
    }

    internal func showLauncher() {
        if launcherController.isActive {
            toggleOpenLauncherShortcutTargetIfNeeded(reason: "shortcut-retarget-open-launcher")
            return
        }

        if cmdTabController.isActive {
            // Transition from CmdTab to Launcher: keep the target where CmdTab had it and
            // inherit CmdTab's retarget session so Launcher cancel restores the pre-CmdTab target.
            let inheritedSession = cmdTabRetargetSession
            cmdTabController.hideForExternalInterruption()
            launcherRetargetSession = inheritedSession
            showLauncherIfAllowed(trigger: "shortcut-show-launcher-from-cmdtab")
            return
        }

        beginLauncherShortcutRetargetSessionIfNeeded(reason: "shortcut-retarget-before-open-launcher")
        showLauncherIfAllowed(trigger: "shortcut-show-launcher")
    }

    private func captureTimeTravelLogs(triggerReason: String) {
        let captureTime = Date()
        let destinationURL = URL(fileURLWithPath: Logger.timeTravelLogPath, isDirectory: false)
        let success = Logger.dumpRecentLogs(
            destinationURL: destinationURL,
            captureTimestamp: captureTime
        )
        if success {
            Logger.debug("Time-travel logs captured at \(Logger.timeTravelLogPath) (reason: \(triggerReason))")
        } else {
            Logger.debug("Time-travel log capture failed (reason: \(triggerReason))")
        }
    }

    // MARK: - Shortcut Zone Removal (Control-Cmd-[minus])

    private func performShortcutZoneRemoval(on screenId: CGDirectDisplayID) -> Bool {
        guard let removalIndex = zoneIndexForShortcutRemoval(on: screenId) else {
            return false
        }

        logShortcutZoneRemoval(screenId: screenId, removalIndex: removalIndex)
        return performRemoveZone(at: removalIndex, on: screenId, announce: true) != nil
    }

    private func logShortcutZoneRemoval(screenId: CGDirectDisplayID, removalIndex: Int) {
        if let context = screenContexts[screenId],
           let zone = context.zoneController.zone(at: removalIndex) {
            let targetedMatch = (targetedZoneKey?.screenId == screenId) && (targetedZoneKey?.index == removalIndex)
            let screenIndex = screenContextStore.loggingIndex(for: screenId)
            Logger.debug(
                "Shortcut remove about to remove zone \(removalIndex) on \(context.descriptor.localizedName) " +
                "[\(screenIndex)] (empty: \(zone.isEmpty), targeted: \(targetedMatch), window: \(zone.occupantWindowId.map(String.init) ?? "none"))"
            )
        } else {
            let screenIndex = screenContextStore.loggingIndex(for: screenId)
            Logger.debug("Shortcut remove selected zone \(removalIndex) on screen \(screenIndex), but zone details unavailable")
        }
    }

    private func zoneIndexForShortcutRemoval(on screenId: CGDirectDisplayID) -> Int? {
        guard let context = screenContexts[screenId] else {
            return nil
        }

        let zones = context.zoneController.allZones
        guard zones.count > 1 else {
            return nil
        }

        let activeIndices = activeZoneIndices(on: screenId)
        let activeList = activeIndices.sorted()
        Logger.debug(
            "Shortcut remove evaluating screen \(context.descriptor.localizedName) [screen \(screenContextStore.loggingIndex(for: screenId))] " +
            "with active zone indices: \(activeList)"
        )

        let targetedIndex: Int?
        if let targetedKey = targetedZoneKey, targetedKey.screenId == screenId {
            targetedIndex = targetedKey.index
        } else {
            targetedIndex = nil
        }

        let zoneSnapshots = zones.map { zone in
            ZoneShortcutRemovalPolicy.ZoneSnapshot(
                index: zone.index,
                isEmpty: zone.isEmpty,
                occupantWindowId: zone.occupantWindowId
            )
        }
        let orderedCandidates = ZoneShortcutRemovalPolicy.orderedCandidates(
            zones: zoneSnapshots,
            protectedIndices: activeIndices,
            targetedIndex: targetedIndex
        )

        guard !orderedCandidates.isEmpty else {
            Logger.debug(
                "Shortcut remove found no removable zones on \(context.descriptor.localizedName) " +
                "[screen \(screenContextStore.loggingIndex(for: screenId))] (active zones: \(activeList), total zones: \(zones.count))"
            )
            return nil
        }

        let description = orderedCandidates.compactMap { candidate -> String? in
            let priority = ZoneShortcutRemovalPolicy.priorityKey(for: candidate, targetedIndex: targetedIndex)
            let targetedFlag = (targetedIndex == candidate.index)
            return "zone \(candidate.index){empty:\(candidate.isEmpty), targeted:\(targetedFlag), window:\(candidate.occupantWindowId.map(String.init) ?? "none"), priority:\(priority)}"
        }.joined(separator: ", ")

        if let selected = orderedCandidates.first {
            Logger.debug(
                "Shortcut remove selected zone \(selected.index) on \(context.descriptor.localizedName) " +
                "[screen \(screenContextStore.loggingIndex(for: screenId))] from candidates [\(description)]"
            )
            return selected.index
        } else {
            Logger.debug(
                "Shortcut remove unable to choose among candidates on \(context.descriptor.localizedName) " +
                "[screen \(screenContextStore.loggingIndex(for: screenId))], descriptions: [\(description)]"
            )
            return nil
        }
    }

    // MARK: - Shortcut Collapse To One Zone (Control-Cmd-0)

    private func collapseToOneZoneShortcut() {
        if let (screenId, floatingWindow) = floatingActiveCollapseContext() {
            applyFloatingActiveCollapse(on: screenId, floatingWindow: floatingWindow)
            return
        }

        let screenId = activeScreenId()
        guard let context = screenContexts[screenId] else {
            return
        }

        let zones = context.zoneController.allZones.sorted { $0.index < $1.index }
        let screenIndex = screenContextStore.loggingIndex(for: screenId)
        Logger.debug("Shortcut collapse to one zone started on screen \(screenIndex)")

        let protectedWindowIds = protectedWindowIdsForShortcutCollapse(on: screenId, zones: zones)
        let targetedIndex = targetedZoneKey?.screenId == screenId ? targetedZoneKey?.index : nil
        let plan = ZoneCollapsePlanner.plan(
            zones: zones.map { ZoneCollapsePlanner.ZoneSnapshot(index: $0.index, occupantWindowId: $0.occupantWindowId) },
            protectedWindowIds: protectedWindowIds,
            targetedIndex: targetedIndex
        )

        guard plan.finalZones.count < zones.count else {
            Logger.debug("Shortcut collapse to one zone stopped early on screen \(screenIndex): no removable zone")
            return
        }

        applyShortcutCollapsePlan(plan, on: screenId, initialTargetedIndex: targetedIndex)
    }

    private func protectedWindowIdsForShortcutCollapse(
        on screenId: CGDirectDisplayID,
        zones: [Zone]
    ) -> Set<Int> {
        let protectedIndices = activeZoneIndices(on: screenId)
        return Set(
            zones.compactMap { zone in
                guard protectedIndices.contains(zone.index) else {
                    return nil
                }
                return zone.occupantWindowId
            }
        )
    }

    private func applyShortcutCollapsePlan(
        _ plan: ZoneCollapsePlanner.Plan,
        on screenId: CGDirectDisplayID,
        initialTargetedIndex: Int?
    ) {
        guard let context = screenContexts[screenId] else {
            return
        }

        let screenIndex = screenContextStore.loggingIndex(for: screenId)
        Logger.debug(
            "Shortcut collapse applying plan on screen \(screenIndex): " +
            "final zone count \(plan.finalZones.count), removed windows \(plan.removedWindowIds)"
        )

        endUnderCovers(on: screenId, reason: "collapse-to-one-zone", recreatePlaceholders: false)
        clearRememberedManualResizeSizes(on: screenId, reason: "collapse-to-one-zone")
        placeholderCoordinator.clearPlaceholdersForScreen(screenId)
        windowController.cancelAllAccessibilityFrameRetries()
        context.zoneController.replaceZones(withOccupants: plan.finalZones.map(\.occupantWindowId))

        let fallbackTargetDestination: TargetedZoneManager.TargetedDestination? = {
            guard initialTargetedIndex != nil, plan.finalTargetIndex == nil else {
                return nil
            }
            return targetedZoneManager.preferredRetargetDestination(preferredSameScreenId: screenId)
        }()

        var windowsToMinimize: [ManagedWindow] = []
        for windowId in plan.removedWindowIds {
            guard let managed = windowController.window(withId: windowId) else {
                Logger.debug("Shortcut collapse skipped missing window \(windowId)")
                continue
            }
            windowsToMinimize.append(managed)
        }

        bulkProgrammaticMinimize(
            windowsToMinimize,
            minimizeReason: "collapse-to-one-zone",
            cleanupReason: "collapse-to-one-zone"
        ) { managed in
            clearManagedWindowZone(managed)
        }

        syncWindowsToZones()
        activeFitRefreshAfterZoneTopologyChange(reason: "collapse-to-one-zone")
        applyShortcutCollapseTargetOutcome(
            on: screenId,
            initialTargetedIndex: initialTargetedIndex,
            finalTargetIndex: plan.finalTargetIndex,
            fallbackDestination: fallbackTargetDestination
        )
        enforceLauncherVisibilityAfterZoneTopologyChange(
            effectiveDestination: targetedZoneManager.targetedDestination,
            reason: "collapse-to-one-zone"
        )
        refreshLauncherForCurrentTargetAfterTopologyChange()

        if let updatedContext = screenContexts[screenId] {
            Logger.debug(
                "Shortcut collapse to one zone finished on screen \(screenIndex) " +
                "with \(updatedContext.zoneController.allZones.count) zone(s)"
            )
        }
    }

    private func applyShortcutCollapseTargetOutcome(
        on screenId: CGDirectDisplayID,
        initialTargetedIndex: Int?,
        finalTargetIndex: Int?,
        fallbackDestination: TargetedZoneManager.TargetedDestination?
    ) {
        guard initialTargetedIndex != nil else {
            return
        }

        if let finalTargetIndex {
            applyTargetedDestination(
                .tiled(ZoneKey(screenId: screenId, index: finalTargetIndex)),
                reason: "collapse-to-one-zone"
            )
            return
        }

        if let fallbackDestination {
            applyTargetedDestination(fallbackDestination, reason: "collapse-to-one-zone")
        } else if let destination = targetedZoneManager.preferredRetargetDestination(preferredSameScreenId: screenId) {
            applyTargetedDestination(destination, reason: "collapse-to-one-zone")
        } else {
            targetedZoneManager.ensureTargetedZone(reason: "collapse-to-one-zone")
        }
    }

    // MARK: - Floating-Active Collapse (Control-Cmd-0 variant)

    /// Returns the screen and floating-zone window when the frontmost managed window is that screen's floating occupant.
    private func floatingActiveCollapseContext() -> (screenId: CGDirectDisplayID, window: ManagedWindow)? {
        guard let (managed, _) = managedWindowForFrontmostApplication(logPrefix: "collapseToOneZone floating check") else {
            return nil
        }
        guard managed.isInFloatingZone else {
            return nil
        }
        for screenId in screenOrder {
            if floatingZoneOccupant(on: screenId)?.windowId == managed.windowId {
                return (screenId, managed)
            }
        }
        return nil
    }

    private func applyFloatingActiveCollapse(on screenId: CGDirectDisplayID, floatingWindow: ManagedWindow) {
        guard let context = screenContexts[screenId] else {
            return
        }

        let screenIndex = screenContextStore.loggingIndex(for: screenId)
        let zones = context.zoneController.allZones.sorted { $0.index < $1.index }
        let plan = ZoneCollapsePlanner.planWithFloatingPromotion(
            zones: zones.map { ZoneCollapsePlanner.ZoneSnapshot(index: $0.index, occupantWindowId: $0.occupantWindowId) },
            floatingWindowId: floatingWindow.windowId
        )

        Logger.debug(
            "Shortcut collapse (floating active) on screen \(screenIndex): " +
            "promote window \(floatingWindow.windowId) to zone 1, minimize tiled windows \(plan.removedWindowIds)"
        )

        let reason = "collapse-floating-active"
        endUnderCovers(on: screenId, reason: reason, recreatePlaceholders: false)
        clearRememberedManualResizeSizes(on: screenId, reason: reason)
        placeholderCoordinator.clearPlaceholdersForScreen(screenId)
        windowController.cancelAllAccessibilityFrameRetries()

        // Collapse the topology to a single empty tiling zone before minimizing so
        // surviving placeholders/frames don't briefly render at the pre-collapse layout.
        context.zoneController.replaceZones(withOccupants: [nil])

        let windowsToMinimize: [ManagedWindow] = plan.removedWindowIds.compactMap { windowController.window(withId: $0) }
        bulkProgrammaticMinimize(
            windowsToMinimize,
            minimizeReason: reason,
            cleanupReason: reason
        ) { managed in
            clearManagedWindowZone(managed)
        }

        // Move the floating window into tiling zone 1 via the standard placement pipeline so
        // floating-zone bookkeeping, frame retargeting, and activation all stay consistent.
        // Explicit floating→tile promotion: don't retarget on removal of the floating source
        // (preserves the user's current target per the spec's reassignment exception, including
        // the case where target is a floating zone on a different screen).
        let zone1Key = ZoneKey(screenId: screenId, index: 1)
        windowPlacementManager.placeWindow(
            floatingWindow,
            into: .tiled(zone1Key),
            centerFloatingWindow: true,
            reason: reason,
            retargetOnRemoval: false,
            forceRetargetAfterFill: false
        )

        syncWindowsToZones()
        activeFitRefreshAfterZoneTopologyChange(reason: reason)

        enforceLauncherVisibilityAfterZoneTopologyChange(
            effectiveDestination: targetedZoneManager.targetedDestination,
            reason: reason
        )
        refreshLauncherForCurrentTargetAfterTopologyChange()

        if let updatedContext = screenContexts[screenId] {
            Logger.debug(
                "Shortcut collapse (floating active) finished on screen \(screenIndex) " +
                "with \(updatedContext.zoneController.allZones.count) zone(s)"
            )
        }
    }

    // MARK: - Active Zone Detection (used by shortcut removal/collapse)

    private func activeZoneIndices(on screenId: CGDirectDisplayID) -> Set<Int> {
        let screenName = screenContexts[screenId]?.descriptor.localizedName ?? "Unknown Screen"

        if let (managed, pid) = managedWindowForFrontmostApplication(logPrefix: "activeZoneIndices frontmost"),
           let zoneIndex = managed.zoneIndex,
           let managedScreenId = managed.screenDisplayId ?? detectScreenId(for: managed),
           managedScreenId == screenId {
            Logger.debug(
                "activeZoneIndices: using frontmost pid \(pid) -> zone \(zoneIndex) on \(screenName) [screen \(screenContextStore.loggingIndex(for: screenId))]"
            )
            return [zoneIndex]
        }

        if let lastPid = lastActiveApplicationPid,
           let managed = windowController.focusedWindowIfTracked(pid: lastPid),
           let zoneIndex = managed.zoneIndex,
           let managedScreenId = managed.screenDisplayId ?? detectScreenId(for: managed),
           managedScreenId == screenId {
            Logger.debug(
                "activeZoneIndices: using last active pid \(lastPid) -> zone \(zoneIndex) on \(screenName) [screen \(screenContextStore.loggingIndex(for: screenId))]"
            )
            return [zoneIndex]
        }

        guard let context = screenContexts[screenId] else {
            return []
        }

        var candidatePids: Set<pid_t> = []
        if let frontmostPid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
           frontmostPid != getpid() {
            candidatePids.insert(frontmostPid)
        }
        if let lastPid = lastActiveApplicationPid,
           lastPid != getpid() {
            candidatePids.insert(lastPid)
        }

        var indices: Set<Int> = []
        for zone in context.zoneController.allZones {
            guard let windowId = zone.occupantWindowId,
                  let managedWindow = windowController.window(withId: windowId),
                  (managedWindow.screenDisplayId ?? detectScreenId(for: managedWindow)) == screenId else {
                if let windowId = zone.occupantWindowId,
                   let managedWindow = windowController.window(withId: windowId) {
                    let hasScreen = (managedWindow.screenDisplayId ?? detectScreenId(for: managedWindow)) != nil
                    Logger.debug(
                        "activeZoneIndices: skipping zone \(zone.index) on \(screenName) [screen \(screenContextStore.loggingIndex(for: screenId))] " +
                        "for window \(windowId) (hasScreen: \(hasScreen))"
                    )
                } else if zone.occupantWindowId != nil {
                    Logger.debug(
                        "activeZoneIndices: no managed window for id \(zone.occupantWindowId!) in zone \(zone.index) on \(screenName) [screen \(screenContextStore.loggingIndex(for: screenId))]"
                    )
                }
                continue
            }

            let pid = managedWindow.backing.pid
            if candidatePids.contains(pid) {
                indices.insert(zone.index)
            } else {
                Logger.debug(
                    "activeZoneIndices: window \(windowId) pid \(pid) not in candidate pid set \(candidatePids) " +
                    "for zone \(zone.index) on \(screenName) [screen \(screenContextStore.loggingIndex(for: screenId))]"
                )
            }
        }
        Logger.debug(
            "activeZoneIndices: resolved indices \(indices.sorted()) for \(screenName) [screen \(screenContextStore.loggingIndex(for: screenId))] with candidate pids \(candidatePids)"
        )
        return indices
    }
}
