import Foundation
import AppKit
import ApplicationServices

/// Sleep/wake pipeline: screens-off event gating, AX readiness polling, topology refresh, and aggressive minimization.
extension AppController {
    // MARK: - Public entry points from SystemEventMonitor

    internal func handleScreensDidSleep() {
        let (managedWindowCount, placeholderCount) = currentWindowCounts()
        Logger.debug(
            "SleepWake: screensDidSleep received " +
            "(managed: \(managedWindowCount), placeholders: \(placeholderCount))"
        )
        screensAsleep = true
        menuBarManager.setDimmed(true)
        validationRetryManager.cancelAllValidationRetries()
        cancelWakeReadinessTimer()
        cancelWakeAXWindowPollingTimer()
        // Cancel any delayed accessibility frame retries so none fire while displays are asleep.
        windowController.cancelAllAccessibilityFrameRetries()
        // Cancel any pending window capture retries driven by AX notifications.
        capturePipeline.cancelAllRetries()
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

    /// Polls for display, session, and AX focused-application readiness before running the wake pipeline.
    /// Matches SPECIFICATION-WAKE: wait until the primary display is awake, the session is unlocked,
    /// and AX can report an active application, polling in 0.5s increments.
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

    /// Cancels any in-flight AX window readiness polling timer.
    private func cancelWakeAXWindowPollingTimer() {
        wakeAXWindowPollingTimer?.cancel()
        wakeAXWindowPollingTimer = nil
    }

    /// Returns true when the display, session, and AX focused application are ready for Accessibility work.
    /// - Display must not be asleep (CGDisplayIsAsleep == false)
    /// - Session must not be locked (CGSSessionScreenIsLocked == false)
    /// - AX must be able to return a focused application (when Accessibility permissions are granted)
    private func isWakeEnvironmentReady() -> Bool {
        let displayAwake = CGDisplayIsAsleep(primaryScreenId) == 0
        let screenLocked = isScreenLocked()
        guard displayAwake && !screenLocked else {
            return false
        }

        // If Accessibility is not trusted, do not block wake readiness on AX-focused-app checks;
        // the rest of the pipeline will still behave defensively.
        guard AXIsProcessTrusted() else {
            Logger.debug("SleepWake: Accessibility not trusted; skipping AX focused-application readiness check")
            return true
        }

        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedAppValue: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedApplicationAttribute as CFString,
            &focusedAppValue
        )
        guard status == .success, let value = focusedAppValue else {
            Logger.debug("SleepWake: AX focused application unavailable (AX error \(status.rawValue)); treating environment as not ready")
            return false
        }
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else {
            Logger.debug("SleepWake: AX focused element is not an application; treating environment as not ready")
            return false
        }

        return true
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

        // Collect windows that belong to zones on remaining screens and have stable external identifiers.
        let (expectedZoneWindowIds, expectedExternalIdentifiers) = collectExpectedSleepWakeWindows(
            remainingScreenIds: remainingScreenIds
        )

        Logger.debug(
            "SleepWake: expected \(expectedZoneWindowIds.count) window(s) in zones on " +
            "\(remainingScreenIds.count) remaining screen(s); " +
            "\(expectedExternalIdentifiers.count) have external identifiers for AX restoration gating"
        )

        // If there are no expected external windows on remaining screens, we can skip AX restoration
        // polling and proceed directly to minimization and sync.
        if expectedExternalIdentifiers.isEmpty {
            Logger.debug("SleepWake: no expected external windows to restore; skipping AX polling")
            executeSleepWakeMinimizeAndSync(
                remainingScreenIds: remainingScreenIds,
                expectedZoneWindowIds: expectedZoneWindowIds,
                restoredWindowIds: []
            )
        } else {
            startAXWindowRestorationPolling(
                remainingScreenIds: remainingScreenIds,
                expectedZoneWindowIds: expectedZoneWindowIds,
                expectedExternalIdentifiers: expectedExternalIdentifiers
            )
        }
    }

    /// Collects non-placeholder windows assigned to zones (including temporary zones) on remaining screens,
    /// returning both their internal window ids and stable external identifiers (pid + CGWindowID).
    private func collectExpectedSleepWakeWindows(
        remainingScreenIds: Set<CGDirectDisplayID>
    ) -> (windowIds: Set<Int>, externalIdentifiers: [ExternalWindowIdentifier: Int]) {
        var expectedIds: Set<Int> = []
        var externalMapping: [ExternalWindowIdentifier: Int] = [:]

        // Collect non-placeholder windows assigned to zones on remaining screens.
        for screenId in remainingScreenIds {
            guard let context = screenContexts[screenId] else {
                continue
            }
            let screenIndex = screenContextStore.loggingIndex(for: screenId)
            for zone in context.zoneController.allZones {
                guard let windowId = zone.windowId,
                      let managed = windowController.window(withId: windowId),
                      !managed.isPlaceholder else {
                    continue
                }
                expectedIds.insert(windowId)
                if let identifier = managed.externalIdentifier {
                    externalMapping[identifier] = windowId
                } else {
                    Logger.debug(
                        "SleepWake: zone window \(windowId) on screen \(screenIndex) has no external identifier; " +
                        "skipping AX restoration gating for this window"
                    )
                }
            }
        }

        // Also treat temporary-zone occupants on remaining screens as "expected".
        for screenId in remainingScreenIds {
            let screenIndex = screenContextStore.loggingIndex(for: screenId)
            if let occupant = temporaryZoneOccupant(on: screenId),
               !occupant.isPlaceholder {
                expectedIds.insert(occupant.windowId)
                if let identifier = occupant.externalIdentifier {
                    externalMapping[identifier] = occupant.windowId
                } else {
                    Logger.debug(
                        "SleepWake: temporary-zone occupant \(occupant.windowId) on screen \(screenIndex) " +
                        "has no external identifier; skipping AX restoration gating for this window"
                    )
                }
            }
        }

        return (expectedIds, externalMapping)
    }

    /// Stage A from SPECIFICATION-WAKE: poll until `_AXUIElementGetWindow` succeeds for all
    /// expected external windows on remaining screens (or until a 5s timeout).
    private func startAXWindowRestorationPolling(
        remainingScreenIds: Set<CGDirectDisplayID>,
        expectedZoneWindowIds: Set<Int>,
        expectedExternalIdentifiers: [ExternalWindowIdentifier: Int]
    ) {
        cancelWakeAXWindowPollingTimer()

        let expectedIdentifierSet = Set(expectedExternalIdentifiers.keys)
        var restoredIdentifiers: Set<ExternalWindowIdentifier> = []
        let startTime = Date()

        let timer = DispatchSource.makeTimerSource(queue: .main)
        // Poll immediately, then every 0.5s.
        timer.schedule(deadline: .now(), repeating: 0.5)

        timer.setEventHandler { [weak self] in
            guard let self else { return }

            // If the screens are no longer marked as asleep, stop polling.
            if !self.screensAsleep {
                self.cancelWakeAXWindowPollingTimer()
                return
            }

            let newlyRestored = self.performAXWindowRestorationPass(
                expectedIdentifiers: expectedIdentifierSet
            )
            if !newlyRestored.isEmpty {
                restoredIdentifiers.formUnion(newlyRestored)
            }

            let elapsed = Date().timeIntervalSince(startTime)
            let allRestored = expectedIdentifierSet.isSubset(of: restoredIdentifiers)
            let timeoutReached = elapsed >= 5.0

            if allRestored || timeoutReached {
                self.cancelWakeAXWindowPollingTimer()

                let restoredWindowIds: Set<Int> = Set(
                    restoredIdentifiers.compactMap { expectedExternalIdentifiers[$0] }
                )

                if timeoutReached && !allRestored {
                    let missingCount = expectedIdentifierSet.subtracting(restoredIdentifiers).count
                    Logger.debug(
                        "SleepWake: AX restoration polling reached 5.0s timeout with " +
                        "\(missingCount) expected window(s) still unrestored; proceeding with minimization and sync"
                    )
                } else {
                    Logger.debug(
                        "SleepWake: AX restoration polling succeeded " +
                        "for all \(expectedIdentifierSet.count) expected external window(s)"
                    )
                }

                self.executeSleepWakeMinimizeAndSync(
                    remainingScreenIds: remainingScreenIds,
                    expectedZoneWindowIds: expectedZoneWindowIds,
                    restoredWindowIds: restoredWindowIds
                )
            } else {
                Logger.debug(
                    "SleepWake: AX restoration polling in progress; " +
                    "restored \(restoredIdentifiers.count)/\(expectedIdentifierSet.count) expected window(s)"
                )
            }
        }

        wakeAXWindowPollingTimer = timer
        timer.resume()
    }

    /// Executes a single AX restoration pass by enumerating windows for the expected PIDs
    /// and recording any whose ExternalWindowIdentifier matches the expected set.
    private func performAXWindowRestorationPass(
        expectedIdentifiers: Set<ExternalWindowIdentifier>
    ) -> Set<ExternalWindowIdentifier> {
        var newlyRestored: Set<ExternalWindowIdentifier> = []

        let expectedPids: Set<pid_t> = Set(expectedIdentifiers.map { $0.pid })
        if expectedPids.isEmpty {
            return newlyRestored
        }

        let allApps = NSWorkspace.shared.runningApplications

        for application in allApps {
            let pid = application.processIdentifier
            guard expectedPids.contains(pid) else {
                continue
            }

            // Use normal application-level filtering but do not restrict by visible bundle ids here;
            // we want to probe any app that owned a pre-sleep zone window.
            guard shouldManage(application: application, visibleBundleIds: nil) else {
                continue
            }

            let result = windowController.captureWindows(
                for: application,
                notifyDelegate: false,
                allowExisting: true
            )

            for managed in result.windows {
                guard case .accessibility(_, let windowPid, _) = managed.backing,
                      expectedPids.contains(windowPid),
                      let identifier = managed.externalIdentifier,
                      expectedIdentifiers.contains(identifier) else {
                    continue
                }
                newlyRestored.insert(identifier)
            }
        }

        return newlyRestored
    }

    /// Stage B and C from SPECIFICATION-WAKE:
    ///  - Minimize any eligible windows not in zones on remaining screens.
    ///  - Then purge unrecovered zone windows, sync windows to zones, and mark screens as awake.
    private func executeSleepWakeMinimizeAndSync(
        remainingScreenIds: Set<CGDirectDisplayID>,
        expectedZoneWindowIds: Set<Int>,
        restoredWindowIds: Set<Int>
    ) {
        let minimizedSummary = executeSleepWakeEnumerationPass(
            remainingScreenIds: remainingScreenIds,
            expectedZoneWindowIds: expectedZoneWindowIds
        )

        Logger.debug(
            "SleepWake: minimization pass summary - enumerated \(minimizedSummary.totalWindows) window(s), " +
            "minimized \(minimizedSummary.minimizedCount) (already minimized \(minimizedSummary.alreadyMinimizedCount))"
        )

        finalizeSleepWakeSync(
            expectedZoneWindowIds: expectedZoneWindowIds,
            restoredWindowIds: restoredWindowIds
        )
    }

    /// Core enumeration pass implementing the "For eligible applications" loop for minimization.
    private func executeSleepWakeEnumerationPass(
        remainingScreenIds: Set<CGDirectDisplayID>,
        expectedZoneWindowIds: Set<Int>
    ) -> (totalWindows: Int, minimizedCount: Int, alreadyMinimizedCount: Int) {
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
                    // Track restored zone windows for logging (but rely on AX polling for purge decisions).
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
        }

        Logger.debug(
            "SleepWake: enumeration complete - enumerated \(totalWindows) window(s), " +
            "minimized \(minimizedCount) (already minimized \(alreadyMinimizedCount)), " +
            "observed \(restoredWindowIds.count)/\(expectedZoneWindowIds.count) expected zone window(s)"
        )

        return (totalWindows, minimizedCount, alreadyMinimizedCount)
    }

    /// Final step of the sleep/wake cycle: purge any unrecovered zone windows and sync.
    private func finalizeSleepWakeSync(
        expectedZoneWindowIds: Set<Int>,
        restoredWindowIds: Set<Int>
    ) {
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
        menuBarManager.setDimmed(false)
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
