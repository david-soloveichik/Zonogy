import Foundation
import AppKit
import ApplicationServices

/// Frame application, retry logic, and coordinate system handling for window positioning.
extension WindowController {
    func cancelAccessibilityFrameRetryIfSuperseded(
        windowId: Int,
        newTargetScreenFrame: CGRect,
        reason: String
    ) {
        guard let existing = accessibilityFrameRetryStates[windowId] else {
            return
        }
        guard !framesRoughlyEqual(existing.targetScreenFrame, newTargetScreenFrame) else {
            return
        }

        Logger.debug(
            "Cancelling stale frame retry chain for window \(windowId) " +
            "(old target: \(existing.targetScreenFrame), new target: \(newTargetScreenFrame), reason: \(reason))"
        )
        var stale = existing
        stale.cancel()
        accessibilityFrameRetryStates.removeValue(forKey: windowId)
    }

    /// Resize and reposition a window to match a frame (frame is in screen-local coordinates)
    func moveWindow(_ managedWindow: ManagedWindow, to frame: CGRect, on screen: ScreenDescriptor) {
        let currentFrame = accessibilityFrameForWindow(element: managedWindow.backing.element, on: screen)
        let effectiveTargetScreenFrame = resolvedTargetScreenFrame(
            for: managedWindow,
            requestedFrame: frame,
            on: screen,
            currentScreenFrame: currentFrame
        )

        cancelAccessibilityFrameRetryIfSuperseded(
            windowId: managedWindow.windowId,
            newTargetScreenFrame: effectiveTargetScreenFrame,
            reason: "new-programmatic-move"
        )

        let currentFrameForSkip = currentFrame ?? .zero
        if framesRoughlyEqual(currentFrameForSkip, effectiveTargetScreenFrame) {
            let screenIndex = ScreenContextStore.screenIndex(for: screen.displayId) ?? Int(screen.displayId)
            Logger.debug("Skipping move for window \(managedWindow.windowId) on screen \(screenIndex) to frame \(effectiveTargetScreenFrame) (already at target).")
            return
        }

        let element = managedWindow.backing.element
        // Accessibility API uses screen coordinates directly
        performProgrammaticUpdate(for: managedWindow.windowId) {
            applyScreenFrameWithBestEffort(
                windowId: managedWindow.windowId,
                element: element,
                targetScreenFrame: effectiveTargetScreenFrame,
                screen: screen
            )
        }
        let screenIndex = ScreenContextStore.screenIndex(for: screen.displayId) ?? Int(screen.displayId)
        Logger.debug("Moved window \(managedWindow.windowId) on screen \(screenIndex) to frame \(effectiveTargetScreenFrame)")
    }

    internal func resolvedTargetScreenFrame(
        for managedWindow: ManagedWindow,
        requestedFrame: CGRect,
        on screen: ScreenDescriptor,
        currentScreenFrame: CGRect? = nil
    ) -> CGRect {
        let preserveWidth: Bool
        if let bundleIdentifier = NSRunningApplication(processIdentifier: managedWindow.backing.pid)?.bundleIdentifier {
            preserveWidth = applicationExceptionPolicy.doesNotResizeWidth(forBundleIdentifier: bundleIdentifier)
        } else {
            preserveWidth = false
        }

        let resolvedCurrentFrame = currentScreenFrame ?? accessibilityFrameForWindow(element: managedWindow.backing.element, on: screen)
        return WidthPreservingFramePolicy.resolvedFrame(
            requestedFrame: requestedFrame,
            currentFrame: resolvedCurrentFrame,
            preserveWidth: preserveWidth
        )
    }

    // MARK: - Frame Application

    internal enum AccessibilityUpdateOrder {
        case sizeThenPosition
        case positionThenSize

        var logLabel: String {
            switch self {
            case .sizeThenPosition: return "size-then-position"
            case .positionThenSize: return "position-then-size"
            }
        }

        var opposite: AccessibilityUpdateOrder {
            switch self {
            case .sizeThenPosition: return .positionThenSize
            case .positionThenSize: return .sizeThenPosition
            }
        }
    }

    internal enum AccessibilityFrameRetryTrigger {
        case applyFailure
        case postApplyFrameReadFailure
        case oppositeOrderApplyFailure
        case postRetryOverflow

        var logLabel: String {
            switch self {
            case .applyFailure: return "apply-failure"
            case .postApplyFrameReadFailure: return "post-apply-frame-read-failure"
            case .oppositeOrderApplyFailure: return "opposite-order-apply-failure"
            case .postRetryOverflow: return "post-retry-overflow"
            }
        }
    }

    /// Apply a desired screen-frame to an AX-managed window, choosing a safe order,
    /// retrying with the opposite order if needed, and scheduling a delayed retry
    /// when the actual frame still doesn't match the target.
    internal func applyScreenFrameWithBestEffort(
        windowId: Int,
        element: AXUIElement,
        targetScreenFrame: CGRect,
        screen: ScreenDescriptor
    ) {
        let targetAccessibilityFrame = screen.screenToAccessibility(targetScreenFrame)
        let currentFrame = accessibilityFrameForWindow(element: element, on: screen)
        let visibleBounds = screen.visibleScreenBounds
        // Decide whether to move first or resize first so the in-between frame stays on-screen if possible
        let order = preferredAccessibilityUpdateOrder(
            currentFrame: currentFrame,
            targetFrame: targetScreenFrame,
            visibleBounds: visibleBounds
        )

        let firstPass = applyAccessibilityFrame(
            element: element,
            targetAccessibilityFrame: targetAccessibilityFrame,
            order: order,
            windowId: windowId,
            screen: screen
        )

        guard firstPass.applied else {
            // AX call failed entirely — window hasn't moved.
            scheduleAccessibilityFrameRetryIfNeeded(
                windowId: windowId,
                element: element,
                targetScreenFrame: targetScreenFrame,
                screen: screen,
                trigger: .applyFailure
            )
            return
        }

        guard let actual = accessibilityFrameForWindow(element: element, on: screen) else {
            logFrameReadFailure(windowId: windowId, screen: screen, context: "post-apply")
            scheduleAccessibilityFrameRetryIfNeeded(
                windowId: windowId,
                element: element,
                targetScreenFrame: targetScreenFrame,
                screen: screen,
                trigger: .postApplyFrameReadFailure
            )
            return
        }

        if !framesRoughlyEqual(actual, targetScreenFrame) {
            logFrameMismatch(
                windowId: windowId,
                screen: screen,
                context: "post-apply",
                target: targetScreenFrame,
                actual: actual,
                order: order
            )
        }

        // Try opposite order immediately
        let retryOrder = order.opposite
        let retryPass = applyAccessibilityFrame(
            element: element,
            targetAccessibilityFrame: targetAccessibilityFrame,
            order: retryOrder,
            windowId: windowId,
            screen: screen
        )

        if retryPass.applied, let final = accessibilityFrameForWindow(element: element, on: screen) {
            if !framesRoughlyEqual(final, targetScreenFrame) {
                logFrameMismatch(
                    windowId: windowId,
                    screen: screen,
                    context: "post-retry",
                    target: targetScreenFrame,
                    actual: final,
                    order: retryOrder
                )
                // Only schedule a delayed retry if the origin is still wrong.
                // Once position is correct, stop — regardless of size differences
                // (e.g., a min-width window that can't shrink to the zone width).
                if !originsRoughlyEqual(final.origin, targetScreenFrame.origin) {
                    scheduleAccessibilityFrameRetryIfNeeded(
                        windowId: windowId,
                        element: element,
                        targetScreenFrame: targetScreenFrame,
                        screen: screen,
                        trigger: .postRetryOverflow
                    )
                }
            }
        } else {
            // Could not apply opposite order; schedule delayed retry
            scheduleAccessibilityFrameRetryIfNeeded(
                windowId: windowId,
                element: element,
                targetScreenFrame: targetScreenFrame,
                screen: screen,
                trigger: .oppositeOrderApplyFailure
            )
        }
    }

    /// Applies AX size/position in a specified order and logs detailed success state.
    private func applyAccessibilityFrame(
        element: AXUIElement,
        targetAccessibilityFrame: CGRect,
        order: AccessibilityUpdateOrder,
        windowId: Int,
        screen: ScreenDescriptor
    ) -> (applied: Bool, positionResult: Bool, sizeResult: Bool) {
        let sizeFirst = order == .sizeThenPosition

        let sizeResult: Bool
        let positionResult: Bool

        if sizeFirst {
            sizeResult = setAccessibilitySize(element: element, size: targetAccessibilityFrame.size)
            positionResult = setAccessibilityPoint(element: element, attribute: kAXPositionAttribute as CFString, point: targetAccessibilityFrame.origin)
        } else {
            positionResult = setAccessibilityPoint(element: element, attribute: kAXPositionAttribute as CFString, point: targetAccessibilityFrame.origin)
            sizeResult = setAccessibilitySize(element: element, size: targetAccessibilityFrame.size)
        }

        if !(sizeResult && positionResult) {
            let screenIndex = ScreenContextStore.screenIndex(for: screen.displayId) ?? Int(screen.displayId)
            Logger.debug("Failed to set frame for window \(windowId) on screen \(screenIndex); order: \(order.logLabel), positionSuccess: \(positionResult), sizeSuccess: \(sizeResult), requested frame: \(screen.accessibilityToScreen(targetAccessibilityFrame))")
        }

        return (sizeResult && positionResult, positionResult, sizeResult)
    }

    private func scheduleAccessibilityFrameRetryIfNeeded(
        windowId: Int,
        element: AXUIElement,
        targetScreenFrame: CGRect,
        screen: ScreenDescriptor,
        trigger: AccessibilityFrameRetryTrigger
    ) {
        // Avoid scheduling retries while a zone resize drag is in progress.
        if delegate?.isZoneResizeDragInProgress() ?? false {
            Logger.debug("Skipping frame retry for window \(windowId) - zone resize in progress")
            return
        }

        // If the window's origin already matches the target, don't retry — the position
        // is correct even if the window's size differs (e.g., min-width constraints).
        if let current = accessibilityFrameForWindow(element: element, on: screen),
           originsRoughlyEqual(current.origin, targetScreenFrame.origin) {
            Logger.debug("Skipping frame retry for window \(windowId) - origin already at target")
            return
        }

        if let existing = accessibilityFrameRetryStates[windowId] {
            if framesRoughlyEqual(existing.targetScreenFrame, targetScreenFrame) {
                Logger.debug(
                    "Skipping frame retry schedule for window \(windowId) - retry already pending " +
                    "(trigger: \(trigger.logLabel))"
                )
                return
            }
            // Target changed — cancel the stale chain and start fresh.
            cancelAccessibilityFrameRetryIfSuperseded(
                windowId: windowId,
                newTargetScreenFrame: targetScreenFrame,
                reason: "retry-target-changed"
            )
        }

        // Skip retry if window is being managed by ActiveFit
        if delegate?.isWindowManagedByActiveFit(windowId: windowId) ?? false {
            Logger.debug("Skipping frame retry for window \(windowId) - managed by ActiveFit")
            return
        }

        let chainId = nextAccessibilityFrameRetryChainId
        nextAccessibilityFrameRetryChainId &+= 1
        var state = FrameRetryState(chainId: chainId, targetScreenFrame: targetScreenFrame)
        scheduleNextFrameRetryAttempt(
            state: &state,
            windowId: windowId,
            element: element,
            targetScreenFrame: targetScreenFrame,
            screen: screen,
            trigger: trigger
        )
    }

    /// Schedules the next attempt in a frame retry chain. Advances the attempt counter,
    /// picks the corresponding delay, and dispatches a work item that re-applies the frame.
    /// When attempts are exhausted the state is removed and no further retries are scheduled.
    private func scheduleNextFrameRetryAttempt(
        state: inout FrameRetryState,
        windowId: Int,
        element: AXUIElement,
        targetScreenFrame: CGRect,
        screen: ScreenDescriptor,
        trigger: AccessibilityFrameRetryTrigger
    ) {
        let delays = WindowController.frameRetryDelays

        guard state.attempt < delays.count else {
            Logger.debug(
                "Frame retry exhausted for window \(windowId) after \(delays.count) attempt(s) " +
                "(trigger: \(trigger.logLabel))"
            )
            state.cancel()
            accessibilityFrameRetryStates.removeValue(forKey: windowId)
            delegate?.frameRetryDidSettle(windowId: windowId)
            return
        }

        let delay = delays[state.attempt]
        state.attempt += 1
        let currentAttempt = state.attempt
        let chainId = state.chainId

        state.cancel()

        let targetAccessibilityFrame = screen.screenToAccessibility(targetScreenFrame)

        Logger.debug(
            "Scheduling frame retry \(currentAttempt)/\(delays.count) for window \(windowId) " +
            "in \(String(format: "%.2f", delay))s " +
            "(trigger: \(trigger.logLabel), target: \(targetScreenFrame))"
        )

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }

            guard var stored = self.accessibilityFrameRetryStates[windowId] else {
                return
            }
            guard stored.chainId == chainId else {
                Logger.debug(
                    "Skipping stale frame retry execution for window \(windowId) " +
                    "- retry chain was replaced"
                )
                return
            }

            // Clear the work item reference but keep the state (with attempt counter) for potential re-scheduling.
            if stored.workItem != nil {
                stored.workItem = nil
                self.accessibilityFrameRetryStates[windowId] = stored
            }

            // Skip the delayed retry if a zone resize is now active.
            if self.delegate?.isZoneResizeDragInProgress() ?? false {
                Logger.debug("Skipping frame retry execution for window \(windowId) - zone resize in progress")
                self.accessibilityFrameRetryStates.removeValue(forKey: windowId)
                return
            }

            // Check again at execution time in case ActiveFit was activated after scheduling.
            if self.delegate?.isWindowManagedByActiveFit(windowId: windowId) ?? false {
                Logger.debug("Skipping frame retry execution for window \(windowId) - now managed by ActiveFit")
                self.accessibilityFrameRetryStates.removeValue(forKey: windowId)
                return
            }

            // If the window's origin already matches the target, no further retries needed.
            if let current = self.accessibilityFrameForWindow(element: element, on: screen),
               self.originsRoughlyEqual(current.origin, targetScreenFrame.origin) {
                Logger.debug(
                    "Frame retry \(currentAttempt)/\(delays.count) for window \(windowId) " +
                    "- origin already at target, stopping retries"
                )
                self.accessibilityFrameRetryStates.removeValue(forKey: windowId)
                self.delegate?.frameRetryDidSettle(windowId: windowId)
                return
            }

            Logger.debug(
                "Executing frame retry \(currentAttempt)/\(delays.count) for window \(windowId) " +
                "(trigger: \(trigger.logLabel))"
            )

            self.performProgrammaticUpdate(for: windowId) {
                let currentFrame = self.accessibilityFrameForWindow(element: element, on: screen)
                let order = self.preferredAccessibilityUpdateOrder(
                    currentFrame: currentFrame,
                    targetFrame: targetScreenFrame,
                    visibleBounds: screen.visibleScreenBounds
                )

                let result = self.applyAccessibilityFrame(
                    element: element,
                    targetAccessibilityFrame: targetAccessibilityFrame,
                    order: order,
                    windowId: windowId,
                    screen: screen
                )

                guard result.applied else {
                    // Apply failed — window hasn't moved.
                    self.scheduleFollowUpRetryIfNeeded(
                        windowId: windowId, element: element,
                        targetScreenFrame: targetScreenFrame, screen: screen,
                        trigger: trigger
                    )
                    return
                }

                guard let final = self.accessibilityFrameForWindow(element: element, on: screen) else {
                    self.logFrameReadFailure(windowId: windowId, screen: screen, context: "retry-\(currentAttempt)")
                    self.scheduleFollowUpRetryIfNeeded(
                        windowId: windowId, element: element,
                        targetScreenFrame: targetScreenFrame, screen: screen,
                        trigger: trigger
                    )
                    return
                }

                if self.originsRoughlyEqual(final.origin, targetScreenFrame.origin) {
                    Logger.debug(
                        "Frame retry \(currentAttempt)/\(delays.count) for window \(windowId) " +
                        "- origin now at target, stopping retries"
                    )
                    self.accessibilityFrameRetryStates.removeValue(forKey: windowId)
                    self.delegate?.frameRetryDidSettle(windowId: windowId)
                } else {
                    self.logFrameMismatch(
                        windowId: windowId,
                        screen: screen,
                        context: "retry-\(currentAttempt)",
                        target: targetScreenFrame,
                        actual: final,
                        order: order
                    )
                    self.scheduleFollowUpRetryIfNeeded(
                        windowId: windowId, element: element,
                        targetScreenFrame: targetScreenFrame, screen: screen,
                        trigger: trigger
                    )
                }
            }
        }

        state.workItem = workItem
        accessibilityFrameRetryStates[windowId] = state
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    /// If the retry state for a window still has remaining attempts, schedule the next one.
    /// Otherwise clean up the state (retries exhausted).
    private func scheduleFollowUpRetryIfNeeded(
        windowId: Int,
        element: AXUIElement,
        targetScreenFrame: CGRect,
        screen: ScreenDescriptor,
        trigger: AccessibilityFrameRetryTrigger
    ) {
        guard var state = accessibilityFrameRetryStates[windowId] else { return }

        // Stop retrying once the origin matches — position is correct even if the
        // window's size differs (e.g., a min-width window that can't shrink to zone width).
        if let current = accessibilityFrameForWindow(element: element, on: screen),
           originsRoughlyEqual(current.origin, targetScreenFrame.origin) {
            Logger.debug("Stopping frame retry chain for window \(windowId) - origin now at target")
            accessibilityFrameRetryStates.removeValue(forKey: windowId)
            delegate?.frameRetryDidSettle(windowId: windowId)
            return
        }
        scheduleNextFrameRetryAttempt(
            state: &state,
            windowId: windowId,
            element: element,
            targetScreenFrame: targetScreenFrame,
            screen: screen,
            trigger: trigger
        )
    }

    // MARK: - Update Order Decision

    /// Decide whether to set size or position first so intermediate frames stay on-screen when possible.
    internal func preferredAccessibilityUpdateOrder(
        currentFrame: CGRect?,
        targetFrame: CGRect,
        visibleBounds: CGRect
    ) -> AccessibilityUpdateOrder {
        guard let currentFrame else {
            // Without a current frame, prefer position first to reduce the chance of expanding off-screen before moving.
            return .positionThenSize
        }

        let sizeFirstIntermediate = CGRect(origin: currentFrame.origin, size: targetFrame.size)
        let positionFirstIntermediate = CGRect(origin: targetFrame.origin, size: currentFrame.size)

        let sizeFirstSafe = frameIsWithinBounds(sizeFirstIntermediate, bounds: visibleBounds) && frameIsWithinBounds(targetFrame, bounds: visibleBounds)
        let positionFirstSafe = frameIsWithinBounds(positionFirstIntermediate, bounds: visibleBounds) && frameIsWithinBounds(targetFrame, bounds: visibleBounds)

        if positionFirstSafe && !sizeFirstSafe { return .positionThenSize }
        if sizeFirstSafe && !positionFirstSafe { return .sizeThenPosition }
        if positionFirstSafe && sizeFirstSafe { return .positionThenSize } // stable default

        // If neither order keeps everything on-screen, choose the one with less overflow area.
        let sizeFirstOverflow = overflowArea(for: sizeFirstIntermediate, bounds: visibleBounds)
        let positionFirstOverflow = overflowArea(for: positionFirstIntermediate, bounds: visibleBounds)
        return positionFirstOverflow <= sizeFirstOverflow ? .positionThenSize : .sizeThenPosition
    }

    // MARK: - Frame Utilities

    private func frameIsWithinBounds(_ frame: CGRect, bounds: CGRect, tolerance: CGFloat = 1.0) -> Bool {
        return frame.minX >= bounds.minX - tolerance &&
               frame.minY >= bounds.minY - tolerance &&
               frame.maxX <= bounds.maxX + tolerance &&
               frame.maxY <= bounds.maxY + tolerance
    }

    internal func originsRoughlyEqual(_ lhs: CGPoint, _ rhs: CGPoint, tolerance: CGFloat = 2.0) -> Bool {
        abs(lhs.x - rhs.x) <= tolerance && abs(lhs.y - rhs.y) <= tolerance
    }

    internal func framesRoughlyEqual(_ lhs: CGRect, _ rhs: CGRect, tolerance: CGFloat = 2.0) -> Bool {
        abs(lhs.minX - rhs.minX) <= tolerance &&
        abs(lhs.minY - rhs.minY) <= tolerance &&
        abs(lhs.width - rhs.width) <= tolerance &&
        abs(lhs.height - rhs.height) <= tolerance
    }

    private func logFrameReadFailure(windowId: Int, screen: ScreenDescriptor, context: String) {
        let screenIndex = ScreenContextStore.screenIndex(for: screen.displayId) ?? Int(screen.displayId)
        Logger.debug("Could not read actual AX frame for window \(windowId) on screen \(screenIndex) (context: \(context))")
    }

    private func logFrameMismatch(
        windowId: Int,
        screen: ScreenDescriptor,
        context: String,
        target: CGRect,
        actual: CGRect,
        order: AccessibilityUpdateOrder
    ) {
        let screenIndex = ScreenContextStore.screenIndex(for: screen.displayId) ?? Int(screen.displayId)
        let cgFrame = actualCGWindowFrame(for: windowId)
        if let cgFrame {
            Logger.debug("Frame mismatch (\(context)) for window \(windowId) on screen \(screenIndex); target: \(target), AX actual: \(actual), CG actual: \(cgFrame), order: \(order.logLabel)")
        } else {
            Logger.debug("Frame mismatch (\(context)) for window \(windowId) on screen \(screenIndex); target: \(target), AX actual: \(actual), CG actual: unavailable, order: \(order.logLabel)")
        }
    }

    internal func actualCGWindowFrame(for windowId: Int) -> CGRect? {
        guard let managed = windowRegistry.window(withId: windowId) else {
            return nil
        }
        let cgWindowId = managed.backing.cgWindowId

        guard let windowInfo = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(cgWindowId)) as? [[String: Any]],
              let boundsDict = windowInfo.first?[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: boundsDict) else {
            return nil
        }
        // CGWindow bounds are already in screen/global coordinates with y:0 at top-left.
        return rect
    }

    private func overflowArea(for frame: CGRect, bounds: CGRect) -> CGFloat {
        let intersection = frame.intersection(bounds)
        let frameArea = frame.width * frame.height
        let intersectionArea = intersection.width * intersection.height
        return max(0, frameArea - intersectionArea)
    }

    /// Current window frame in screen coordinates, or nil if it cannot be read.
    internal func accessibilityFrameForWindow(element: AXUIElement, on screen: ScreenDescriptor) -> CGRect? {
        guard let position = ManagedWindow.copyCGPointValue(element: element, attribute: kAXPositionAttribute as CFString),
              let size = ManagedWindow.copyCGSizeValue(element: element, attribute: kAXSizeAttribute as CFString) else {
            return nil
        }
        let accessibilityFrame = CGRect(origin: position, size: size)
        return screen.accessibilityToScreen(accessibilityFrame)
    }

    // MARK: - Programmatic Update Tracking

    internal func performProgrammaticUpdate(for windowId: Int, _ block: () -> Void) {
        // Cancel any pending cleanup for this window (debouncing).
        programmaticUpdateWorkItems[windowId]?.cancel()

        programmaticUpdateWindowIds.insert(windowId)
        block()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.programmaticUpdateWindowIds.remove(windowId)
            self.programmaticUpdateWorkItems.removeValue(forKey: windowId)
        }

        programmaticUpdateWorkItems[windowId] = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
    }

    // MARK: - Accessibility Attribute Setters

    internal func setAccessibilityPoint(element: AXUIElement, attribute: CFString, point: CGPoint) -> Bool {
        var mutablePoint = point
        guard let value = AXValueCreate(AXValueType(rawValue: kAXValueCGPointType)!, &mutablePoint) else {
            return false
        }
        let status = AXCall.setAttribute(element, attribute, value)
        return status == .success
    }

    internal func setAccessibilitySize(element: AXUIElement, size: CGSize) -> Bool {
        var mutableSize = size
        guard let value = AXValueCreate(AXValueType(rawValue: kAXValueCGSizeType)!, &mutableSize) else {
            return false
        }
        let status = AXCall.setAttribute(element, kAXSizeAttribute as CFString, value)
        return status == .success
    }

    // MARK: - Live Resize (Async)

    /// Lightweight window move for live zone resize drags.
    ///
    /// Compares the new target to the previous target to skip unchanged AX attributes,
    /// then dispatches only the needed AX writes to a serial background queue.
    /// Avoids readback, retry, and the opposite-order pass; width-preserving exceptions
    /// may still consult the current frame on the first tick to keep the existing width.
    /// The final full sync on drag end handles correctness.
    @discardableResult
    func moveWindowForLiveResize(
        _ managedWindow: ManagedWindow,
        targetScreenFrame: CGRect,
        previousTargetScreenFrame: CGRect?,
        screen: ScreenDescriptor
    ) -> CGRect {
        let effectiveTargetScreenFrame = resolvedTargetScreenFrame(
            for: managedWindow,
            requestedFrame: targetScreenFrame,
            on: screen,
            currentScreenFrame: previousTargetScreenFrame
        )
        let positionChanged: Bool
        let sizeChanged: Bool
        let tolerance: CGFloat = 0.5

        if let prev = previousTargetScreenFrame {
            positionChanged = abs(effectiveTargetScreenFrame.origin.x - prev.origin.x) > tolerance
                           || abs(effectiveTargetScreenFrame.origin.y - prev.origin.y) > tolerance
            sizeChanged = abs(effectiveTargetScreenFrame.width - prev.width) > tolerance
                       || abs(effectiveTargetScreenFrame.height - prev.height) > tolerance
        } else {
            // First tick of the drag — must set both.
            positionChanged = true
            sizeChanged = true
        }

        guard positionChanged || sizeChanged else { return effectiveTargetScreenFrame }

        // Mark as programmatic update on the main thread BEFORE dispatching, so
        // AXMoved/AXResized observation handlers won't trigger spurious reflows.
        performProgrammaticUpdate(for: managedWindow.windowId) { /* no-op: actual work is async */ }

        // Compute accessibility-coordinate frame on the main thread (pure math).
        let targetAXFrame = screen.screenToAccessibility(effectiveTargetScreenFrame)

        // Choose size-vs-position order using the previous target as "current frame"
        // (no AX read needed) so intermediate frames stay on-screen when possible.
        let order: AccessibilityUpdateOrder
        if positionChanged && sizeChanged {
            order = preferredAccessibilityUpdateOrder(
                currentFrame: previousTargetScreenFrame,
                targetFrame: effectiveTargetScreenFrame,
                visibleBounds: screen.visibleScreenBounds
            )
        } else {
            order = .sizeThenPosition // only one attribute changing; order irrelevant
        }

        // Accumulate the AX write as a closure. The caller is responsible for
        // calling flushLiveResizeWrites() after all per-window calls to dispatch
        // the batch as a single queue item.
        pendingLiveResizeWrites.append { [weak self] in
            guard let self else { return }
            switch order {
            case .sizeThenPosition:
                if sizeChanged {
                    _ = self.setAccessibilitySize(element: managedWindow.backing.element, size: targetAXFrame.size)
                }
                if positionChanged {
                    _ = self.setAccessibilityPoint(
                        element: managedWindow.backing.element,
                        attribute: kAXPositionAttribute as CFString,
                        point: targetAXFrame.origin
                    )
                }
            case .positionThenSize:
                if positionChanged {
                    _ = self.setAccessibilityPoint(
                        element: managedWindow.backing.element,
                        attribute: kAXPositionAttribute as CFString,
                        point: targetAXFrame.origin
                    )
                }
                if sizeChanged {
                    _ = self.setAccessibilitySize(element: managedWindow.backing.element, size: targetAXFrame.size)
                }
            }
        }

        return effectiveTargetScreenFrame
    }

    /// Dispatch all pending live-resize AX writes as a single batch on the
    /// background queue. One batch = one in-flight flag, so the frame-skip
    /// check in ZoneResizeHandleManager sees a precise busy signal.
    func flushLiveResizeWrites() {
        guard !pendingLiveResizeWrites.isEmpty else { return }
        let writes = pendingLiveResizeWrites
        pendingLiveResizeWrites = []
        isLiveResizeAXBatchInFlight = true
        liveResizeAXQueue.async {
            for write in writes { write() }
            DispatchQueue.main.async { [weak self] in
                self?.isLiveResizeAXBatchInFlight = false
            }
        }
    }

    /// Block until all pending live-resize AX writes have completed.
    /// Called before the drag-end full sync to prevent stale async writes
    /// from overwriting the final corrected frames.
    func drainLiveResizeQueue() {
        flushLiveResizeWrites()
        liveResizeAXQueue.sync {}
    }
}
