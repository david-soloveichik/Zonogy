import Foundation
import AppKit
import ApplicationServices

/// Accessibility capture helpers and external window registry management.
extension WindowController {
    /// Attempt to capture the frontmost standard window of the active application.
    /// Returns the managed wrapper if successful.
    func captureFrontmostWindow() -> ManagedWindow? {
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication else {
            Logger.debug("No frontmost application available to capture")
            return nil
        }
        return captureFocusedWindow(application: frontmostApp, allowCreating: true)
    }

    /// Attempt to capture the focused window for the specified process identifier.
    /// Returns the managed wrapper if successful.
    func captureFocusedWindow(pid: pid_t, allowCreating: Bool = true) -> ManagedWindow? {
        guard let application = NSRunningApplication(processIdentifier: pid) else {
            Logger.debug("No running application for pid \(pid); cannot capture focused window")
            return nil
        }
        return captureFocusedWindow(application: application, allowCreating: allowCreating)
    }

    /// Attempt to return the focused window for the specified pid if it is already tracked.
    /// Does not create new ManagedWindow instances.
    func focusedWindowIfTracked(pid: pid_t) -> ManagedWindow? {
        let managed = captureFocusedWindow(pid: pid, allowCreating: false)
        if let managed {
            let screenDescription = managed.screenDisplayId.map { ScreenContextStore.logDescription(for: $0) } ?? "unknown-screen"
            Logger.debug(
                "focusedWindowIfTracked: pid \(pid) -> window \(managed.windowId) (zone: \(managed.zoneIndex.map(String.init) ?? "none"), \(screenDescription))"
            )
        } else {
            Logger.debug("focusedWindowIfTracked: pid \(pid) has no tracked focused window (or focused window is unavailable)")
        }
        return managed
    }

    func captureFocusedWindow(application: NSRunningApplication, allowCreating: Bool) -> ManagedWindow? {
        guard ensureAccessibilityPermissions() else {
            Logger.debug("Accessibility permissions missing; cannot capture focused window for pid \(application.processIdentifier)")
            return nil
        }

        if let bundleId = application.bundleIdentifier,
           ignoredBundleIdentifiers.contains(bundleId) {
            Logger.debug("Skipping capture for ignored bundle \(bundleId)")
            return nil
        }

        let pid = application.processIdentifier
        if pid == getpid() {
            Logger.debug("Requested capture for Zonogy; nothing to capture")
            return nil
        }

        let appElement = accessibilityWatcher.applicationElement(for: pid)

        var windowObject: CFTypeRef?
        let windowResult = AXCall.copyAttribute(appElement, kAXFocusedWindowAttribute as CFString, &windowObject)
        guard windowResult == .success, let windowObject else {
            let bundleId = application.bundleIdentifier ?? "unknown"
            Logger.debug(
                "Failed to obtain focused window for pid \(pid) (bundle: \(bundleId), active: \(application.isActive), hidden: \(application.isHidden), finishedLaunching: \(application.isFinishedLaunching)) (AX error \(windowResult.logDescription))"
            )
            return nil
        }

        guard CFGetTypeID(windowObject) == AXUIElementGetTypeID() else {
            Logger.debug("Focused element for pid \(pid) is not a window element")
            return nil
        }

        let windowElement = unsafeBitCast(windowObject, to: AXUIElement.self)
        let focusedExisting = existingManagedWindow(for: windowElement)

        if let focusedExisting, focusedExisting.isPlacedInZone {
            Logger.debug("captureFocusedWindow: returning existing managed window \(focusedExisting.windowId) for pid \(pid)")
            return focusedExisting
        }

        if !allowCreating,
           focusedExisting == nil {
            Logger.debug("captureFocusedWindow: focused window for pid \(pid) is not yet tracked and allowCreating=false")
            return nil
        }

        return captureWindowIfNeeded(
            element: windowElement,
            pid: pid,
            appElement: appElement,
            allowReturningExisting: true,
            notifyDelegate: allowCreating
        )
    }

    private func existingManagedWindow(for element: AXUIElement) -> ManagedWindow? {
        let elementKey = AccessibilityElementKey(element: element)
        if let existing = externalWindowsByElement[elementKey] {
            return existing
        }

        if let identifier = externalIdentifier(for: element),
           let existing = externalWindows[identifier] {
            externalWindowsByElement[elementKey] = existing
            return existing
        }

        return nil
    }

    /// Capture all top-level windows for the specified application.
    /// - Parameters:
    ///   - application: The running application whose windows should be managed.
    ///   - notifyDelegate: When true, the delegate is notified for each newly captured window.
    ///   - allowExisting: When true, existing managed windows are included in the result.
    /// - Returns: Newly captured windows (and existing ones if requested) along with retry guidance.
    func captureWindows(
        for application: NSRunningApplication,
        notifyDelegate: Bool,
        allowExisting: Bool = false
    ) -> CaptureResult {
        guard ensureAccessibilityPermissions() else {
            return CaptureResult(windows: [], needsRetry: false)
        }

        guard application.processIdentifier != getpid() else {
            return CaptureResult(windows: [], needsRetry: false)
        }

        let bundleIdentifier = application.bundleIdentifier
        if let bundleId = bundleIdentifier,
           ignoredBundleIdentifiers.contains(bundleId) {
            return CaptureResult(windows: [], needsRetry: false)
        }

        let pid = application.processIdentifier
        let appElement = accessibilityWatcher.applicationElement(for: pid)

        var needsRetry = false
        if let observerResult = accessibilityWatcher.ensureObserver(for: pid, appElement: appElement, bundleIdentifier: bundleIdentifier) {
            needsRetry = observerResult.needsRetry
        } else {
            return CaptureResult(windows: [], needsRetry: true)
        }

        var windowsObject: CFTypeRef?
        let status = AXCall.copyAttribute(appElement, kAXWindowsAttribute as CFString, &windowsObject)
        if status != .success {
            let bundleDescription = bundleIdentifier ?? "unknown-bundle-identifier"
            Logger.debug("Failed to enumerate windows for pid \(pid) (bundle \(bundleDescription)) (AX error \(status.rawValue))")
            if status == .cannotComplete {
                needsRetry = true
            }
            return CaptureResult(windows: [], needsRetry: needsRetry)
        }
        guard let windowsObject else {
            let bundleDescription = bundleIdentifier ?? "unknown-bundle-identifier"
            Logger.debug("AX windows attribute returned nil for pid \(pid) (bundle \(bundleDescription))")
            return CaptureResult(windows: [], needsRetry: needsRetry)
        }

        var captured: [ManagedWindow] = []
        for element in windowElements(from: windowsObject) {
            if let managed = captureWindowIfNeeded(
                element: element,
                pid: pid,
                appElement: appElement,
                allowReturningExisting: allowExisting,
                notifyDelegate: notifyDelegate,
                needsRetry: &needsRetry
            ) {
                captured.append(managed)
            }
        }

        return CaptureResult(windows: captured, needsRetry: needsRetry)
    }

    internal func captureWindowIfNeeded(
        element: AXUIElement,
        pid: pid_t,
        appElement: AXUIElement,
        allowReturningExisting: Bool,
        notifyDelegate: Bool,
        needsRetry: UnsafeMutablePointer<Bool>? = nil
    ) -> ManagedWindow? {
        let cgResult = cgWindowIdWithStatus(for: element, pid: pid, context: "captureWindowIfNeeded")
        guard let cgWindowId = cgResult.id else {
            if let error = cgResult.axError,
               retryableAXWindowErrors.contains(error) {
                needsRetry?.pointee = true
            } else if cgResult.axError == nil {
                // Received CGWindowID 0; the window may not be fully initialized yet.
                needsRetry?.pointee = true
            }

            Logger.debug("captureWindowIfNeeded: Skipping window because CGWindowID is unavailable for pid \(pid)")
            return nil
        }

        let windowNumStr = String(cgWindowId)

        Logger.debug("captureWindowIfNeeded: Attempting to capture window (CGWindowID: \(windowNumStr)) for pid \(pid)")

        // Check minimized state first - minimized windows skip the subrole check
        // (some apps like PDF Expert report AXDialog subrole for their document windows)
        let isMinimized = isWindowMinimized(element)

        guard isStandardWindow(element, pid: pid, cgWindowId: cgWindowId, skipSubroleCheck: isMinimized) else {
            Logger.debug("captureWindowIfNeeded: Window (CGWindowID: \(windowNumStr)) is not a standard window for pid \(pid)")
            return nil
        }

        let identifier = ExternalWindowIdentifier(pid: pid, cgWindowId: Int(cgWindowId))
        let existing = existingManagedWindow(for: element)

        if let existing,
           existing.externalIdentifier == identifier,
           AccessibilityElementKey(element: existing.backing.element) != AccessibilityElementKey(element: element) {
            rebindElement(for: existing, newElement: element, appElement: appElement)
        }

        let shouldEvaluateNativeTabReplacement = NativeTabReplacementPolicy.shouldEvaluateIncomingWindow(
            isPlacedInZone: existing?.isPlacedInZone ?? false,
            isMinimized: isMinimized,
            nativeTabHandlingDisabled: nativeTabHandlingDisabled
        )

        if let existing, !shouldEvaluateNativeTabReplacement {
            Logger.debug(
                "captureWindowIfNeeded: Window already exists for pid \(pid) as managed \(existing.windowId) (CGWindowID: \(windowNumStr)), allowReturningExisting=\(allowReturningExisting)"
            )
            return allowReturningExisting ? existing : nil
        }

        if existing == nil,
           let restored = restorePendingPrunedWindowIfNeeded(
            identifier: identifier,
            element: element,
            appElement: appElement,
            notifyDelegate: notifyDelegate,
            isMinimized: isMinimized
        ) {
            Logger.debug("captureWindowIfNeeded: Restored deferred-prune window \(restored.windowId) for pid \(pid)")
            return restored
        }

        let incomingWindowServerFrame: CGRect?
        if shouldEvaluateNativeTabReplacement {
            guard let frame = WindowServerWindowList.frame(
                for: identifier.cgWindowId,
                ownerPid: identifier.pid
            ) else {
                needsRetry?.pointee = true
                Logger.debug(
                    "captureWindowIfNeeded: Waiting for live WindowServer frame before managing pid \(pid), CGWindowID \(identifier.cgWindowId) (native tab handling enabled)"
                )
                return nil
            }
            Logger.debug(
                "Native tab replacement: incoming live WindowServer frame available for pid \(pid), CGWindowID \(identifier.cgWindowId): \(frame)"
            )
            incomingWindowServerFrame = frame
        } else {
            incomingWindowServerFrame = nil
        }

        if let incomingWindowServerFrame {
            if let replacement = replaceNativeTabBackingIfNeeded(
                element: element,
                identifier: identifier,
                appElement: appElement,
                incomingFrame: incomingWindowServerFrame
            ) {
                return replacement
            }
        }

        if let existing {
            Logger.debug(
                "Native tab replacement: no placed coincident window found for unplaced existing managed window \(existing.windowId) (pid \(pid), CGWindowID \(identifier.cgWindowId)); allowReturningExisting=\(allowReturningExisting)"
            )
            return allowReturningExisting ? existing : nil
        }

        if pendingPrunedWindows.hasEntries(forPid: pid) {
            clearPendingPrunedWindowsForNewManagedWindow(pid: pid, discoveredIdentifier: identifier)
        }

        let elementKey = AccessibilityElementKey(element: element)
        let windowId = windowRegistry.allocateIdentifier()
        let managed = ManagedWindow(
            windowId: windowId,
            backing: ManagedWindowBacking(element: element, pid: pid, cgWindowId: identifier.cgWindowId)
        )
        // Seed the cached frame now so it is available even if placement issues no move
        // (e.g. the window is already at its target frame); refreshed on later move/resize.
        recordCachedFrame(for: managed)
        windowRegistry.insert(managed)
        externalWindowsByElement[elementKey] = managed
        externalWindows[identifier] = managed

        if isMinimized {
            Logger.debug("Captured minimized window \(identifier.cgWindowId) from pid \(pid) as managed id \(managed.windowId) (tracking only, no zone placement)")
        } else {
            Logger.debug("Captured external window \(identifier.cgWindowId) from pid \(pid) as managed id \(managed.windowId)")
        }

        registerAccessibilityNotifications(for: managed, appElement: appElement)

        // Only notify delegate for non-minimized windows (minimized windows are tracked but not placed in zones)
        if notifyDelegate && !isMinimized {
            Logger.debug("captureWindowIfNeeded: Notifying delegate about captured window \(managed.windowId) for pid \(pid)")
            delegate?.windowController(self, didCaptureExternalWindow: managed)
        }

        Logger.debug("captureWindowIfNeeded: Successfully captured window \(managed.windowId) for pid \(pid)")
        return managed
    }

    private func replaceNativeTabBackingIfNeeded(
        element: AXUIElement,
        identifier: ExternalWindowIdentifier,
        appElement: AXUIElement,
        incomingFrame: CGRect
    ) -> ManagedWindow? {
        let samePidWindows = windowRegistry.allWindows
            .filter { $0.backing.pid == identifier.pid }
            .sorted { $0.windowId < $1.windowId }

        Logger.debug(
            "Native tab replacement: evaluating \(samePidWindows.count) same-pid managed window(s) for incoming pid \(identifier.pid), CGWindowID \(identifier.cgWindowId), frame \(incomingFrame)"
        )

        var candidates: [NativeTabReplacementPolicy.Candidate] = []
        for managed in samePidWindows {
            let placement = nativeTabPlacementDescription(for: managed)

            guard managed.backing.cgWindowId != identifier.cgWindowId else {
                Logger.debug(
                    "Native tab replacement: skipping managed window \(managed.windowId) (\(placement)); same CGWindowID \(identifier.cgWindowId)"
                )
                continue
            }

            guard managed.isPlacedInZone else {
                Logger.debug(
                    "Native tab replacement: skipping managed window \(managed.windowId) (CGWindowID \(managed.backing.cgWindowId)); not placed in any zone"
                )
                continue
            }

            // A placed window that still exposes a live WindowServer frame is a genuinely separate
            // live window, not a switched-away tab. On a real tab switch the old tab's WindowServer
            // frame is withdrawn before the new tab's is exposed (verified across TextEdit/Terminal/
            // Finder via the same notifications we observe), so the switched-away tab has no live
            // frame by the time we get here. Matching a still-live window would be a false positive
            // (two distinct windows that merely share a frame), so only a window whose live frame is
            // gone — read from its Accessibility frame — is an eligible replacement target.
            if let liveFrame = WindowServerWindowList.frame(
                for: managed.backing.cgWindowId,
                ownerPid: managed.backing.pid
            ) {
                // Diagnostic so each skip self-classifies: if the incoming window sits at a
                // different position than this placed window (its live or remembered frame), they
                // are genuinely separate windows and the skip is correct. If they coincide, this is
                // either two distinct windows sharing a frame (still correct to skip) or a
                // same-group tab whose background frame reappeared before we evaluated — a missed
                // adoption worth investigating.
                let cachedFrame = managed.cachedFrame
                let coincides = NativeTabReplacementPolicy.positionAndWidthCoincide(incomingFrame, liveFrame)
                    || (cachedFrame.map { NativeTabReplacementPolicy.positionAndWidthCoincide(incomingFrame, $0) } ?? false)
                Logger.debug(
                    "Native tab replacement: skipping managed window \(managed.windowId) (\(placement), CGWindowID \(managed.backing.cgWindowId)); still exposes a live WindowServer frame. " +
                    "incoming=\(incomingFrame) live=\(liveFrame) cached=\(cachedFrame.map { "\($0)" } ?? "nil"); " +
                    (coincides
                        ? "frames COINCIDE -> separate windows sharing a frame (correct) OR a missed same-group adoption (investigate)"
                        : "frames DIFFER -> genuinely separate windows, skip is correct")
                )
                continue
            }

            let candidateFrame = managed.actualFrame
            guard candidateFrame.width > 0, candidateFrame.height > 0 else {
                Logger.debug(
                    "Native tab replacement: skipping managed window \(managed.windowId) (\(placement), CGWindowID \(managed.backing.cgWindowId)); no live WindowServer frame and ManagedWindow.actualFrame unavailable"
                )
                continue
            }
            let candidateFrameSource = "ManagedWindow.actualFrame (live WindowServer frame withdrawn)"
            Logger.debug(
                "Native tab replacement: managed window \(managed.windowId) (\(placement), CGWindowID \(managed.backing.cgWindowId)) eligible via \(candidateFrameSource): \(candidateFrame)"
            )

            let coincides = NativeTabReplacementPolicy.positionAndWidthCoincide(incomingFrame, candidateFrame)
            let deltaDescription = nativeTabFrameDeltaDescription(incomingFrame: incomingFrame, candidateFrame: candidateFrame)
            if coincides {
                Logger.debug(
                    "Native tab replacement: managed window \(managed.windowId) (\(placement), CGWindowID \(managed.backing.cgWindowId)) is a coincident candidate using \(candidateFrameSource); candidate frame \(candidateFrame); \(deltaDescription)"
                )
            } else {
                Logger.debug(
                    "Native tab replacement: managed window \(managed.windowId) (\(placement), CGWindowID \(managed.backing.cgWindowId)) rejected by frame check using \(candidateFrameSource); candidate frame \(candidateFrame); \(deltaDescription)"
                )
                continue
            }

            candidates.append(NativeTabReplacementPolicy.Candidate(
                windowId: managed.windowId,
                pid: managed.backing.pid,
                cgWindowId: managed.backing.cgWindowId,
                frame: candidateFrame,
                isPlacedInZone: managed.isPlacedInZone
            ))
        }

        guard !candidates.isEmpty else {
            Logger.debug(
                "Native tab replacement: no coincident candidates for incoming pid \(identifier.pid), CGWindowID \(identifier.cgWindowId); normal capture path will continue"
            )
            return nil
        }

        guard let match = NativeTabReplacementPolicy.replacementCandidate(
            incomingPid: identifier.pid,
            incomingCgWindowId: identifier.cgWindowId,
            incomingFrame: incomingFrame,
            candidates: candidates
        ),
              let managed = windowRegistry.window(withId: match.windowId) else {
            Logger.debug(
                "Native tab replacement: policy returned no live managed match from \(candidates.count) coincident candidate(s) for incoming pid \(identifier.pid), CGWindowID \(identifier.cgWindowId); normal capture path will continue"
            )
            return nil
        }

        let previousIdentifier = managed.externalIdentifier
        replaceTrackedWindowBacking(
            managed,
            newElement: element,
            newIdentifier: identifier,
            appElement: appElement
        )

        Logger.debug(
            "Native tab replacement: preserved managed window \(managed.windowId) in its existing zone " +
            "(pid \(identifier.pid), CGWindowID \(previousIdentifier.cgWindowId) -> \(identifier.cgWindowId), " +
            "old frame: \(match.frame), new frame: \(incomingFrame))"
        )

        return managed
    }

    private func nativeTabPlacementDescription(for managed: ManagedWindow) -> String {
        let screenDescription = managed.screenDisplayId.map { ScreenContextStore.logDescription(for: $0) } ?? "unknown screen"
        if let zoneIndex = managed.zoneIndex {
            return "zone \(zoneIndex) on \(screenDescription)"
        }
        if managed.isInFloatingZone {
            return "floating zone on \(screenDescription)"
        }
        return "not placed"
    }

    private func nativeTabFrameDeltaDescription(incomingFrame: CGRect, candidateFrame: CGRect) -> String {
        let dx = abs(incomingFrame.minX - candidateFrame.minX)
        let dy = abs(incomingFrame.minY - candidateFrame.minY)
        let dw = abs(incomingFrame.width - candidateFrame.width)
        let dh = abs(incomingFrame.height - candidateFrame.height)
        return "deltas x=\(formatNativeTabDelta(dx)), y=\(formatNativeTabDelta(dy)), width=\(formatNativeTabDelta(dw)), height=\(formatNativeTabDelta(dh)) " +
            "(limits x/y/width<=\(formatNativeTabDelta(NativeTabReplacementPolicy.frameTolerance)); height not checked for adoption)"
    }

    private func formatNativeTabDelta(_ value: CGFloat) -> String {
        String(format: "%.1f", Double(value))
    }

    /// Extract an `[AXUIElement]` from the value of a `kAXWindowsAttribute` query, handling both
    /// the bridged-array and raw-CFArray representations the Accessibility API may return.
    private func windowElements(from windowsObject: CFTypeRef) -> [AXUIElement] {
        if let windowElements = windowsObject as? [AXUIElement] {
            return windowElements
        }
        if CFGetTypeID(windowsObject) == CFArrayGetTypeID() {
            let array = unsafeBitCast(windowsObject, to: CFArray.self)
            return (0..<CFArrayGetCount(array)).map {
                unsafeBitCast(CFArrayGetValueAtIndex(array, $0), to: AXUIElement.self)
            }
        }
        return []
    }

    /// Drop a redundant managed window that already tracks `element` before another window adopts
    /// it as its new native-tab backing. The redundant window is always an unplaced duplicate of
    /// the same tab group — the switch path only adopts an unplaced incoming window, and the close
    /// path filters out siblings placed in a zone of their own — so removing it never vacates a zone.
    private func dropRedundantManagedWindow(for element: AXUIElement, keeping managed: ManagedWindow) {
        guard let redundant = existingManagedWindow(for: element),
              redundant.windowId != managed.windowId else {
            return
        }
        // Defensive: callers only ever route unplaced duplicates here (switch adopts an unplaced
        // incoming window; close filters out siblings placed in a zone). Never vacate a zone.
        guard !redundant.isPlacedInZone else {
            Logger.debug("Native tab replacement: refusing to drop placed managed window \(redundant.windowId) as a redundant backing for window \(managed.windowId)")
            return
        }
        Logger.debug(
            "Native tab replacement: removing redundant unplaced managed window \(redundant.windowId) " +
            "(pid \(redundant.backing.pid), CGWindowID \(redundant.backing.cgWindowId)) before window \(managed.windowId) adopts its tab"
        )
        windowLastActiveTime.removeValue(forKey: redundant.windowId)
        removeManagedWindowFromLiveTracking(redundant)
    }

    private func replaceTrackedWindowBacking(
        _ managed: ManagedWindow,
        newElement: AXUIElement,
        newIdentifier: ExternalWindowIdentifier,
        appElement: AXUIElement
    ) {
        // If the new backing element/CGWindowID is itself an already-tracked (unplaced) managed
        // window, drop that duplicate first so we never leave two managed windows sharing a backing.
        dropRedundantManagedWindow(for: newElement, keeping: managed)

        let previousIdentifier = managed.externalIdentifier
        removeAccessibilityTracking(for: managed)
        externalWindows.removeValue(forKey: previousIdentifier)
        clearBackingScopedState(for: managed.windowId, reason: "native-tab-replacement")

        managed.backing = ManagedWindowBacking(
            element: newElement,
            pid: newIdentifier.pid,
            cgWindowId: newIdentifier.cgWindowId
        )

        externalWindowsByElement[AccessibilityElementKey(element: newElement)] = managed
        externalWindows[newIdentifier] = managed
        registerAccessibilityNotifications(for: managed, appElement: appElement)

        // Refresh the cached frame from the new backing so a later tab-close rebind matches where
        // the window actually sits, even before the next move/resize notification arrives.
        recordCachedFrame(for: managed)
    }

    /// Refresh `managed.cachedFrame` from the live accessibility frame. Invoked on the
    /// AXMoved/AXResized notifications we already observe, so the cache tracks the window's
    /// real on-screen frame (including ActiveFit reveal and manual resizes).
    internal func recordCachedFrame(for managed: ManagedWindow) {
        guard let frame = actualFrameInAccessibilityCoordinates(for: managed),
              frame.width > 0, frame.height > 0 else {
            Logger.debug("recordCachedFrame: no usable accessibility frame for window \(managed.windowId) (pid \(managed.backing.pid), CGWindowID \(managed.backing.cgWindowId)); keeping previous cached frame")
            return
        }
        managed.cachedFrame = frame
    }

    /// When a placed managed window is being pruned — its backing tab is gone or no longer resolves
    /// to a live AX element — but other tabs of the same window survive, rebind it to a surviving
    /// sibling (same process, coincident with its cached frame) so it keeps its `windowId` and zone
    /// instead of being pruned. Called from `stagePendingPrunedWindow`, so it covers every prune
    /// trigger (the `AXUIElementDestroyed` notification and the validation sweep), whether the closed
    /// `CGWindowID` has vanished from the window list or merely no longer resolves to an element.
    /// Returns true when a sibling was adopted; false when the window should be pruned.
    internal func rebindClosedNativeTabWindowIfPossible(_ managed: ManagedWindow) -> Bool {
        guard !nativeTabHandlingDisabled, managed.isPlacedInZone else {
            return false
        }

        let identifier = managed.externalIdentifier
        guard let cachedFrame = managed.cachedFrame, cachedFrame.width > 0, cachedFrame.height > 0 else {
            Logger.debug("Native tab close: window \(managed.windowId) (pid \(identifier.pid), CGWindowID \(identifier.cgWindowId)) has no cached frame; cannot match a surviving sibling")
            return false
        }

        let appElement = accessibilityWatcher.applicationElement(for: identifier.pid)
        let siblings = nativeTabSiblingCandidates(
            pid: identifier.pid,
            excludingCgWindowId: identifier.cgWindowId,
            excludingElement: managed.backing.element,
            appElement: appElement
        )

        guard let match = NativeTabReplacementPolicy.bestSibling(
                  matching: cachedFrame,
                  among: siblings.map { $0.candidate }
              ),
              let adopted = siblings.first(where: { $0.candidate.cgWindowId == match.cgWindowId }) else {
            Logger.debug(
                "Native tab close: no surviving sibling coincident with cached frame \(cachedFrame) for window \(managed.windowId) (pid \(identifier.pid), closed CGWindowID \(identifier.cgWindowId), \(siblings.count) sibling candidate(s))"
            )
            return false
        }

        let newIdentifier = ExternalWindowIdentifier(pid: identifier.pid, cgWindowId: match.cgWindowId)
        replaceTrackedWindowBacking(
            managed,
            newElement: adopted.element,
            newIdentifier: newIdentifier,
            appElement: appElement
        )
        Logger.debug(
            "Native tab close: rebound window \(managed.windowId) to surviving sibling " +
            "(pid \(identifier.pid), CGWindowID \(identifier.cgWindowId) -> \(match.cgWindowId), " +
            "cached frame \(cachedFrame), sibling frame \(match.frame))"
        )
        return true
    }

    /// Enumerate the application's current windows (excluding `excludingElement` and
    /// `excludingCgWindowId`) as `SiblingCandidate`s paired with their live AX elements. A
    /// sibling's frame comes from the live WindowServer frame, falling back to its accessibility
    /// frame — mirroring the tab-switch path.
    private func nativeTabSiblingCandidates(
        pid: pid_t,
        excludingCgWindowId: Int,
        excludingElement: AXUIElement,
        appElement: AXUIElement
    ) -> [(element: AXUIElement, candidate: NativeTabReplacementPolicy.SiblingCandidate)] {
        var windowsObject: CFTypeRef?
        let status = AXCall.copyAttribute(appElement, kAXWindowsAttribute as CFString, &windowsObject)
        guard status == .success, let windowsObject else {
            return []
        }

        let excludedKey = AccessibilityElementKey(element: excludingElement)
        var results: [(element: AXUIElement, candidate: NativeTabReplacementPolicy.SiblingCandidate)] = []
        for element in windowElements(from: windowsObject) {
            guard AccessibilityElementKey(element: element) != excludedKey else {
                continue
            }
            // Never steal a window Zonogy already manages in a zone of its own; only untracked tabs
            // or redundant unplaced duplicates of this tab group are valid rebind targets.
            if let tracked = existingManagedWindow(for: element), tracked.isPlacedInZone {
                continue
            }
            guard let cgWindowId = cgWindowIdWithStatus(for: element, pid: pid, context: "native-tab-close-sibling").id else {
                continue
            }
            let cgWindowIdInt = Int(cgWindowId)
            guard cgWindowIdInt != excludingCgWindowId else {
                continue
            }

            let frame: CGRect
            if let wsFrame = WindowServerWindowList.frame(for: cgWindowIdInt, ownerPid: pid) {
                frame = wsFrame
            } else if let axFrame = ManagedWindow.frame(of: element), axFrame.width > 0, axFrame.height > 0 {
                frame = axFrame
            } else {
                continue
            }

            results.append((element, NativeTabReplacementPolicy.SiblingCandidate(cgWindowId: cgWindowIdInt, frame: frame)))
        }
        return results
    }

    /// Enumerate the application's current windows and return a *fresh* AX element
    /// whose CGWindowID matches `cgWindowId`, skipping `excludedElement` (typically a
    /// just-destroyed element that may still linger in the enumeration). Returns nil
    /// when no live element can be resolved right now — i.e. the window is truly gone
    /// or AX is transiently unavailable. Used to distinguish a real window close from
    /// an app recycling a live window's AX element.
    internal func liveWindowElement(
        forPid pid: pid_t,
        cgWindowId: Int,
        excluding excludedElement: AXUIElement,
        appElement: AXUIElement
    ) -> AXUIElement? {
        var windowsObject: CFTypeRef?
        let status = AXCall.copyAttribute(appElement, kAXWindowsAttribute as CFString, &windowsObject)
        guard status == .success, let windowsObject else {
            return nil
        }

        let excludedKey = AccessibilityElementKey(element: excludedElement)

        func matches(_ element: AXUIElement) -> Bool {
            guard AccessibilityElementKey(element: element) != excludedKey else {
                return false
            }
            let result = cgWindowIdWithStatus(for: element, pid: pid, context: "spurious-destroy-rebind")
            guard let resolved = result.id else {
                return false
            }
            return Int(resolved) == cgWindowId
        }

        return windowElements(from: windowsObject).first(where: matches)
    }
}
