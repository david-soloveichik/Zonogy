import Foundation
import AppKit

/// Sleep/wake pipeline: event gating, topology refresh, and aggressive minimization.
extension AppController {
    // MARK: - Public entry points from SystemEventMonitor

    internal func handleWorkspaceWillSleep() {
        let (managedWindowCount, placeholderCount) = currentWindowCounts()

        if sleepWakeCycle {
            Logger.debug(
                "SleepWake: NSWorkspace.willSleep received while cycle already active - ignoring " +
                "(managed: \(managedWindowCount), placeholders: \(placeholderCount))"
            )
            return
        }

        Logger.debug(
            "SleepWake: entering sleepWakeCycle on willSleep " +
            "(managed: \(managedWindowCount), placeholders: \(placeholderCount))"
        )

        // Mark cycle active and clear any prior state.
        sleepWakeCycle = true
        sleepWakeTimer?.cancel()
        sleepWakePassWorkItem?.cancel()
        sleepWakeTimer = nil
        sleepWakePassWorkItem = nil
        sleepWakePreSleepScreenIds = Set(screenContexts.keys)
        sleepWakeRemainingScreenIds.removeAll()
        sleepWakeExpectedZoneWindowIds.removeAll()
        sleepWakeRestoredWindowIds.removeAll()
        sleepWakeSyncPerformed = false

        if sleepWakePreSleepScreenIds.isEmpty {
            Logger.debug("SleepWake: pre-sleep screen set is empty (unexpected)")
        } else {
            let indices = sleepWakePreSleepScreenIds
                .map { screenContextStore.loggingIndex(for: $0) }
                .sorted()
            Logger.debug("SleepWake: pre-sleep screens: \(indices)")
        }
    }

    internal func handleWorkspaceDidWake() {
        let (managedWindowCount, placeholderCount) = currentWindowCounts()

        guard sleepWakeCycle else {
            Logger.debug(
                "SleepWake: NSWorkspace.didWake received with no active cycle - treating as spurious " +
                "(managed: \(managedWindowCount), placeholders: \(placeholderCount))"
            )
            return
        }

        Logger.debug(
            "SleepWake: didWake received - scheduling wake timer (0.5s) " +
            "(managed: \(managedWindowCount), placeholders: \(placeholderCount))"
        )

        sleepWakeTimer?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.sleepWakeCycle else {
                Logger.debug("SleepWake: wake timer fired but sleepWakeCycle is false; aborting wake pipeline")
                return
            }
            self.startSleepWakePasses()
        }
        sleepWakeTimer = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
    }

    // MARK: - Core wake pipeline

    private func startSleepWakePasses() {
        Logger.debug("SleepWake: wake timer fired - rebuilding screen topology and preparing passes")

        // Recompute current screen topology.
        let screens = NSScreen.screens
        let rebuildResult = screenContextStore.rebuild(with: screens)

        if !rebuildResult.addedDisplayIds.isEmpty {
            let indices = rebuildResult.addedDisplayIds
                .map { screenContextStore.loggingIndex(for: $0) }
                .sorted()
            Logger.debug("SleepWake: detected added display ids after wake: \(indices)")
        }
        if !rebuildResult.removedContexts.isEmpty {
            let indices = rebuildResult.removedContexts
                .map { screenContextStore.loggingIndex(for: $0.displayId) }
                .sorted()
            Logger.debug("SleepWake: detected removed display ids after wake: \(indices)")
        }
        if rebuildResult.orderChanged {
            Logger.debug("SleepWake: screen order changed after wake")
        }

        let currentScreenIds = Set(screenContexts.keys)
        sleepWakeRemainingScreenIds = sleepWakePreSleepScreenIds.intersection(currentScreenIds)
        let removedSinceSleep = sleepWakePreSleepScreenIds.subtracting(currentScreenIds)

        if sleepWakeRemainingScreenIds.isEmpty {
            Logger.debug(
                "SleepWake: no remaining screens intersect pre-sleep set; all eligible windows will be minimized"
            )
        } else {
            let indices = sleepWakeRemainingScreenIds
                .map { screenContextStore.loggingIndex(for: $0) }
                .sorted()
            Logger.debug(
                "SleepWake: remaining screens after wake (intersection of pre/post): \(indices)"
            )
        }

        if !removedSinceSleep.isEmpty {
            let indices = removedSinceSleep
                .map { screenContextStore.loggingIndex(for: $0) }
                .sorted()
            Logger.debug("SleepWake: screens removed since sleep: \(indices)")
        }

        prepareSleepWakeExpectedZoneWindows()

        Logger.debug(
            "SleepWake: starting enumeration passes with " +
            "\(sleepWakeExpectedZoneWindowIds.count) window(s) in zones on " +
            "\(sleepWakeRemainingScreenIds.count) remaining screen(s)"
        )

        // Run passes serially with delays between them: first immediately, then
        // after 0.5s, 0.5s, 1.0s, 1.0s, 2.0s, 2.0s (relative to the previous pass).
        runSleepWakePass(passIndex: 0, remainingDelays: [0.5, 0.5, 1.0, 1.0, 2.0, 2.0])
    }

    private func prepareSleepWakeExpectedZoneWindows() {
        sleepWakeExpectedZoneWindowIds.removeAll()
        sleepWakeRestoredWindowIds.removeAll()
        sleepWakeSyncPerformed = false

        // Collect non-placeholder windows assigned to zones on remaining screens.
        for screenId in sleepWakeRemainingScreenIds {
            guard let context = screenContexts[screenId] else {
                continue
            }
            for zone in context.zoneController.allZones {
                guard let windowId = zone.windowId,
                      let managed = windowController.window(withId: windowId),
                      !managed.isPlaceholder else {
                    continue
                }
                sleepWakeExpectedZoneWindowIds.insert(windowId)
            }
        }

        // Also treat temporary-zone occupants on remaining screens as "expected".
        for screenId in sleepWakeRemainingScreenIds {
            if let occupant = temporaryZoneOccupant(on: screenId),
               !occupant.isPlaceholder {
                sleepWakeExpectedZoneWindowIds.insert(occupant.windowId)
            }
        }
    }

    private func runSleepWakePass(passIndex: Int, remainingDelays: [TimeInterval]) {
        let isLastPass = remainingDelays.isEmpty
        Logger.debug(
            "SleepWake: starting enumeration pass \(passIndex + 1) " +
            "(sleepWakeCycle=\(sleepWakeCycle), last=\(isLastPass))"
        )

        executeSleepWakeEnumerationPass(passIndex: passIndex, isLastPass: isLastPass)

        // Schedule the next pass if any remain. We continue running passes even
        // after sleepWakeCycle becomes false so we can keep minimizing windows
        // that are not part of any remaining-screen zone.
        guard let nextDelay = remainingDelays.first else {
            if !sleepWakeSyncPerformed {
                Logger.debug(
                    "SleepWake: all passes complete and sync not yet performed; " +
                    "finalizing now from runSleepWakePass tail"
                )
                finalizeSleepWakeSync(context: "runSleepWakePass-tail")
            } else {
                Logger.debug("SleepWake: all passes complete; sync already performed earlier in cycle")
            }
            return
        }

        let delaysTail = Array(remainingDelays.dropFirst())
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.runSleepWakePass(passIndex: passIndex + 1, remainingDelays: delaysTail)
        }
        sleepWakePassWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + nextDelay, execute: workItem)
    }

    /// Core enumeration pass implementing the "For eligible applications" loop.
    private func executeSleepWakeEnumerationPass(passIndex: Int, isLastPass: Bool) {
        let visibleBundleIds = bundleIdsWithVisibleWindows()
        let allApps = NSWorkspace.shared.runningApplications

        let eligibleApps = allApps.filter { app in
            shouldManage(application: app, visibleBundleIds: visibleBundleIds)
        }

        Logger.debug(
            "SleepWake: pass \(passIndex + 1) - \(eligibleApps.count) eligible application(s), " +
            "\(visibleBundleIds.count) bundle(s) with visible windows"
        )

        var totalWindows = 0
        var minimizedCount = 0
        var alreadyMinimizedCount = 0
        var restoredThisPass: Set<Int> = []

        for application in eligibleApps {
            guard let bundleId = application.bundleIdentifier else {
                continue
            }

            let result = windowController.captureWindows(
                for: application,
                notifyDelegate: false,
                allowExisting: true
            )

            let windows = result.windows
            if windows.isEmpty {
                continue
            }

            Logger.debug(
                "SleepWake: pass \(passIndex + 1) - enumerated \(windows.count) window(s) for " +
                "\(bundleId) (pid \(application.processIdentifier)), needsRetry=\(result.needsRetry)"
            )

            for managed in windows {
                totalWindows += 1

                // All eligible windows in this loop are external (Accessibility-backed).
                guard case .accessibility(_, _, _) = managed.backing else {
                    continue
                }

                if isWindowInRemainingZone(managed) {
                    // Mark as restored only if this window was expected.
                    if sleepWakeExpectedZoneWindowIds.contains(managed.windowId) &&
                        !sleepWakeRestoredWindowIds.contains(managed.windowId) {
                        sleepWakeRestoredWindowIds.insert(managed.windowId)
                        restoredThisPass.insert(managed.windowId)
                    }
                    continue
                }

                // Not in a zone on any remaining screen: minimize aggressively.
                if managed.isMinimized {
                    alreadyMinimizedCount += 1
                    continue
                }

                minimizeWindowProgrammatically(managed, reason: "sleep-wake-minimize")
                minimizedCount += 1
            }
        }

        Logger.debug(
            "SleepWake: pass \(passIndex + 1) complete - enumerated \(totalWindows) window(s), " +
            "minimized \(minimizedCount) (already minimized \(alreadyMinimizedCount)), " +
            "restored \(restoredThisPass.count) expected zone window(s) this pass " +
            "(total restored \(sleepWakeRestoredWindowIds.count)/\(sleepWakeExpectedZoneWindowIds.count))"
        )

        // Decide whether to perform the sync/clear step for this cycle.
        if !sleepWakeSyncPerformed {
            let allRestored = sleepWakeExpectedZoneWindowIds.isEmpty ||
                sleepWakeRestoredWindowIds.isSuperset(of: sleepWakeExpectedZoneWindowIds)

            if allRestored {
                Logger.debug(
                    "SleepWake: all expected zone windows on remaining screens have been restored " +
                    "by pass \(passIndex + 1); finalizing sync"
                )
                finalizeSleepWakeSync(context: "all-restored-pass-\(passIndex + 1)")
            } else if isLastPass {
                Logger.debug(
                    "SleepWake: final pass reached with incomplete restores " +
                    "(restored \(sleepWakeRestoredWindowIds.count)/\(sleepWakeExpectedZoneWindowIds.count)); " +
                    "finalizing sync at final pass"
                )
                finalizeSleepWakeSync(context: "final-pass-\(passIndex + 1)")
            }
        }
    }

    /// Final step of the sleep/wake cycle: purge any unrecovered zone windows and sync.
    private func finalizeSleepWakeSync(context: String) {
        guard !sleepWakeSyncPerformed else {
            Logger.debug("SleepWake: finalizeSleepWakeSync(\(context)) called but sync already performed; skipping")
            return
        }

        let unrestored = sleepWakeExpectedZoneWindowIds.subtracting(sleepWakeRestoredWindowIds)
        if unrestored.isEmpty {
            Logger.debug("SleepWake: no unrestored expected zone windows to purge before sync (\(context))")
        } else {
            Logger.debug(
                "SleepWake: purging \(unrestored.count) unrestored expected zone window(s) " +
                "from internal zone model before sync (\(context))"
            )
            for windowId in unrestored {
                // Remove from all zones without retargeting; we only want to drop
                // stale references, not change the targeted zone due to purging.
                removeWindowFromAllZones(windowId: windowId, reason: "sleep-wake-unrestored", retarget: false)
            }
        }

        syncWindowsToZones()
        sleepWakeCycle = false
        sleepWakeSyncPerformed = true
    }

    /// Determines whether a managed window is considered "in a zone" on one of the
    /// remaining screens (either as a tiled zone occupant or as a temporary-zone occupant).
    private func isWindowInRemainingZone(_ managed: ManagedWindow) -> Bool {
        guard let screenId = managed.screenDisplayId,
              sleepWakeRemainingScreenIds.contains(screenId) else {
            return false
        }

        if managed.zoneIndex != nil {
            return true
        }

        if let occupant = temporaryZoneOccupant(on: screenId),
           occupant.windowId == managed.windowId {
            return true
        }

        return false
    }

    // MARK: - Event gating helper

    /// Returns true when non-sleep/wake events should be ignored due to an active
    /// sleep/wake cycle. Call this at the top of delegate handlers that respond
    /// to external notifications (window events, workspace events, display changes).
    internal func shouldIgnoreDueToSleepWake(event: String) -> Bool {
        guard sleepWakeCycle else {
            return false
        }
        Logger.debug("SleepWake: ignoring \(event) because sleepWakeCycle is active")
        return true
    }
}
