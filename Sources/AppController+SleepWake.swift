import Foundation
import AppKit
import ApplicationServices

/// Sleep/wake pipeline: topology refresh and aggressive minimization.
extension AppController {
    // MARK: - Public entry points from SystemEventMonitor

    internal func handleScreensDidSleep() {
        let (managedWindowCount, placeholderCount) = currentWindowCounts()
        Logger.debug(
            "SleepWake: screensDidSleep received " +
            "(managed: \(managedWindowCount), placeholders: \(placeholderCount))"
        )
        screensAsleep = true
        validationRetryManager.cancelAllValidationRetries()
        cancelWakeReadinessTimer()
    }

    internal func handleScreensDidWake() {
        let (managedWindowCount, placeholderCount) = currentWindowCounts()
        Logger.debug(
            "SleepWake: screensDidWake received " +
            "(managed: \(managedWindowCount), placeholders: \(placeholderCount)), " +
            "starting wake readiness polling"
        )
        startWakeReadinessPolling()
    }

    // MARK: - Core wake pipeline

    /// Polls for display and session readiness before running the wake pipeline.
    /// Workaround #2 from SPECIFICATION-WAKE: wait until the primary display is awake
    /// and the session is unlocked, polling in 0.5s increments.
    private func startWakeReadinessPolling() {
        cancelWakeReadinessTimer()

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)

        timer.setEventHandler { [weak self] in
            guard let self else { return }

            // If we've already completed the wake pipeline (or weren't asleep), stop polling.
            if !self.screensAsleep {
                self.cancelWakeReadinessTimer()
                return
            }

            if self.isWakeEnvironmentReady() {
                Logger.debug("SleepWake: wake readiness checks passed; starting wake pipeline")
                self.cancelWakeReadinessTimer()
                self.executeSleepWakePipeline()
            } else {
                Logger.debug("SleepWake: wake readiness checks not yet satisfied; retrying in 0.5s")
            }
        }

        wakeReadinessTimer = timer
        timer.resume()
    }

    /// Cancels any in-flight wake readiness timer.
    private func cancelWakeReadinessTimer() {
        wakeReadinessTimer?.cancel()
        wakeReadinessTimer = nil
    }

    /// Returns true when both the display and session are ready for Accessibility work.
    /// - Display must not be asleep (CGDisplayIsAsleep == false)
    /// - Session must not be locked (CGSSessionScreenIsLocked == false)
    private func isWakeEnvironmentReady() -> Bool {
        let displayAwake = CGDisplayIsAsleep(primaryScreenId) == 0
        let screenLocked = isScreenLocked()
        return displayAwake && !screenLocked
    }

    /// Best-effort check for whether the session screen is locked using CGSessionCopyCurrentDictionary.
    /// If the dictionary or key is unavailable, we conservatively assume the screen is unlocked to
    /// avoid stalling the wake pipeline indefinitely.
    private func isScreenLocked() -> Bool {
        guard let sessionDict = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            Logger.debug("SleepWake: CGSessionCopyCurrentDictionary returned nil; treating session as unlocked")
            return false
        }
        if let locked = sessionDict["CGSSessionScreenIsLocked"] as? Bool {
            return locked
        }
        Logger.debug("SleepWake: CGSSessionScreenIsLocked key missing; treating session as unlocked")
        return false
    }

    private func executeSleepWakePipeline() {
        Logger.debug("SleepWake: starting wake pipeline - rebuilding screen topology")

        // Capture pre-wake screen set for comparison.
        let preSleepScreenIds = Set(screenContexts.keys)

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
        let remainingScreenIds = preSleepScreenIds.intersection(currentScreenIds)
        let removedSinceSleep = preSleepScreenIds.subtracting(currentScreenIds)

        if remainingScreenIds.isEmpty {
            Logger.debug(
                "SleepWake: no remaining screens intersect pre-sleep set; all eligible windows will be minimized"
            )
        } else {
            let indices = remainingScreenIds
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

        // Collect windows that belong to zones on remaining screens.
        let expectedZoneWindowIds = collectExpectedZoneWindowIds(remainingScreenIds: remainingScreenIds)

        Logger.debug(
            "SleepWake: starting enumeration with " +
            "\(expectedZoneWindowIds.count) window(s) in zones on " +
            "\(remainingScreenIds.count) remaining screen(s)"
        )

        // Execute enumeration pass.
        let restoredWindowIds = executeSleepWakeEnumerationPass(
            remainingScreenIds: remainingScreenIds,
            expectedZoneWindowIds: expectedZoneWindowIds
        )

        // Purge unrestored windows from zones and sync.
        finalizeSleepWakeSync(
            expectedZoneWindowIds: expectedZoneWindowIds,
            restoredWindowIds: restoredWindowIds
        )
    }

    private func collectExpectedZoneWindowIds(remainingScreenIds: Set<CGDirectDisplayID>) -> Set<Int> {
        var expectedIds: Set<Int> = []

        // Collect non-placeholder windows assigned to zones on remaining screens.
        for screenId in remainingScreenIds {
            guard let context = screenContexts[screenId] else {
                continue
            }
            for zone in context.zoneController.allZones {
                guard let windowId = zone.windowId,
                      let managed = windowController.window(withId: windowId),
                      !managed.isPlaceholder else {
                    continue
                }
                expectedIds.insert(windowId)
            }
        }

        // Also treat temporary-zone occupants on remaining screens as "expected".
        for screenId in remainingScreenIds {
            if let occupant = temporaryZoneOccupant(on: screenId),
               !occupant.isPlaceholder {
                expectedIds.insert(occupant.windowId)
            }
        }

        return expectedIds
    }

    /// Core enumeration pass implementing the "For eligible applications" loop.
    private func executeSleepWakeEnumerationPass(
        remainingScreenIds: Set<CGDirectDisplayID>,
        expectedZoneWindowIds: Set<Int>
    ) -> Set<Int> {
        let visibleBundleIds = bundleIdsWithVisibleWindows()
        let allApps = NSWorkspace.shared.runningApplications

        let eligibleApps = allApps.filter { app in
            shouldManage(application: app, visibleBundleIds: visibleBundleIds)
        }

        Logger.debug(
            "SleepWake: \(eligibleApps.count) eligible application(s), " +
            "\(visibleBundleIds.count) bundle(s) with visible windows"
        )

        var totalWindows = 0
        var minimizedCount = 0
        var alreadyMinimizedCount = 0
        var restoredWindowIds: Set<Int> = []
        var syncPerformed = false

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
                "SleepWake: enumerated \(windows.count) window(s) for " +
                "\(bundleId) (pid \(application.processIdentifier)), needsRetry=\(result.needsRetry)"
            )

            for managed in windows {
                totalWindows += 1

                // All eligible windows in this loop are external (Accessibility-backed).
                guard case .accessibility(_, _, _) = managed.backing else {
                    continue
                }

                if isWindowInRemainingZone(managed, remainingScreenIds: remainingScreenIds) {
                    // Mark as restored only if this window was expected.
                    if expectedZoneWindowIds.contains(managed.windowId) {
                        restoredWindowIds.insert(managed.windowId)
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

            // Check if all expected zone windows have been restored - perform early sync if so.
            if !syncPerformed {
                let allRestored = expectedZoneWindowIds.isEmpty ||
                    restoredWindowIds.isSuperset(of: expectedZoneWindowIds)
                if allRestored {
                    Logger.debug(
                        "SleepWake: all expected zone windows restored mid-enumeration; performing early sync"
                    )
                    syncWindowsToZones()
                    screensAsleep = false
                    syncPerformed = true
                }
            }
        }

        Logger.debug(
            "SleepWake: enumeration complete - enumerated \(totalWindows) window(s), " +
            "minimized \(minimizedCount) (already minimized \(alreadyMinimizedCount)), " +
            "restored \(restoredWindowIds.count)/\(expectedZoneWindowIds.count) expected zone window(s)"
        )

        return restoredWindowIds
    }

    /// Final step of the sleep/wake cycle: purge any unrecovered zone windows and sync.
    private func finalizeSleepWakeSync(
        expectedZoneWindowIds: Set<Int>,
        restoredWindowIds: Set<Int>
    ) {
        // If sync was already performed during enumeration (early exit), skip.
        guard screensAsleep || !restoredWindowIds.isSuperset(of: expectedZoneWindowIds) else {
            Logger.debug("SleepWake: sync already performed during enumeration; skipping finalize")
            return
        }

        let unrestored = expectedZoneWindowIds.subtracting(restoredWindowIds)
        if unrestored.isEmpty {
            Logger.debug("SleepWake: no unrestored expected zone windows to purge before sync")
        } else {
            Logger.debug(
                "SleepWake: purging \(unrestored.count) unrestored expected zone window(s) " +
                "from internal zone model before sync"
            )
            for windowId in unrestored {
                // Remove from all zones without retargeting; we only want to drop
                // stale references, not change the targeted zone due to purging.
                removeWindowFromAllZones(windowId: windowId, reason: "sleep-wake-unrestored", retarget: false)
            }
        }

        syncWindowsToZones()
        screensAsleep = false
    }

    // MARK: - Event gating helper

    /// Returns true when events should be ignored due to screens being asleep.
    /// Call this at the top of delegate handlers that respond to external notifications.
    internal func shouldIgnoreDueToSleepWake(event: String) -> Bool {
        guard screensAsleep else {
            return false
        }
        Logger.debug("SleepWake: ignoring \(event) because screens are asleep")
        return true
    }

    /// Determines whether a managed window is considered "in a zone" on one of the
    /// remaining screens (either as a tiled zone occupant or as a temporary-zone occupant).
    private func isWindowInRemainingZone(_ managed: ManagedWindow, remainingScreenIds: Set<CGDirectDisplayID>) -> Bool {
        guard let screenId = managed.screenDisplayId,
              remainingScreenIds.contains(screenId) else {
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
}
