import Foundation
import AppKit
import ApplicationServices

/// Frame application, retry logic, and coordinate system handling for window positioning.
extension WindowController {
    /// Resize and reposition a window to match a frame (frame is in screen-local coordinates)
    func moveWindow(_ managedWindow: ManagedWindow, to frame: CGRect, on screen: ScreenDescriptor) {
        let currentFrame = actualFrameInScreenCoordinates(for: managedWindow, on: screen)

        if framesRoughlyEqual(currentFrame, frame) {
            let screenIndex = ScreenContextStore.screenIndex(for: screen.displayId) ?? Int(screen.displayId)
            Logger.debug("Skipping move for window \(managedWindow.windowId) on screen \(screenIndex) to frame \(frame) (already at target).")
            return
        }

        let element = managedWindow.backing.element
        // Accessibility API uses screen coordinates directly
        performProgrammaticUpdate(for: managedWindow.windowId) {
            applyScreenFrameWithBestEffort(
                windowId: managedWindow.windowId,
                element: element,
                targetScreenFrame: frame,
                screen: screen
            )
        }
        let screenIndex = ScreenContextStore.screenIndex(for: screen.displayId) ?? Int(screen.displayId)
        Logger.debug("Moved window \(managedWindow.windowId) on screen \(screenIndex) to frame \(frame)")
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

    internal enum AccessibilityFrameRetryPolicy {
        case onlyWhenOffscreen
        case forceAfterApplyFailure

        var logLabel: String {
            switch self {
            case .onlyWhenOffscreen: return "only-when-offscreen"
            case .forceAfterApplyFailure: return "force-after-apply-failure"
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
            scheduleAccessibilityFrameRetryIfNeeded(
                windowId: windowId,
                element: element,
                targetScreenFrame: targetScreenFrame,
                screen: screen,
                trigger: .applyFailure,
                policy: .forceAfterApplyFailure
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
                // Only schedule a delayed retry if the final frame still overflows the visible bounds.
                // If the window is fully on-screen but merely refuses to shrink to the exact zone size,
                // treat the current placement as "good enough" to avoid late jumps caused by retries.
                if !frameIsWithinBounds(final, bounds: visibleBounds) {
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
        trigger: AccessibilityFrameRetryTrigger,
        policy: AccessibilityFrameRetryPolicy = .onlyWhenOffscreen
    ) {
        // Avoid scheduling retries while a zone resize drag is in progress.
        if delegate?.isZoneResizeDragInProgress() ?? false {
            Logger.debug("Skipping frame retry for window \(windowId) - zone resize in progress")
            return
        }

        if policy == .onlyWhenOffscreen {
            // If the window is already fully within the visible screen bounds, do not
            // schedule a retry. This prevents late retries from nudging windows that
            // are visually in a good state (e.g., min-width windows that cannot shrink
            // to the exact requested zone size).
            if let current = accessibilityFrameForWindow(element: element, on: screen) {
                let visibleBounds = screen.visibleScreenBounds
                let cgFrame = actualCGWindowFrame(for: windowId)
                let boundsCheckFrame = cgFrame ?? current
                if frameIsWithinBounds(boundsCheckFrame, bounds: visibleBounds) {
                    Logger.debug("Skipping frame retry for window \(windowId) - frame already within visible bounds")
                    return
                }
            }
        }

        if let existing = accessibilityFrameRetryStates[windowId] {
            if framesRoughlyEqual(existing.targetScreenFrame, targetScreenFrame) {
                Logger.debug(
                    "Skipping frame retry schedule for window \(windowId) - retry already pending " +
                    "(trigger: \(trigger.logLabel), policy: \(policy.logLabel))"
                )
                return
            }
            // Target changed — cancel the stale chain and start fresh.
            Logger.debug(
                "Cancelling stale frame retry chain for window \(windowId) " +
                "(old target: \(existing.targetScreenFrame), new target: \(targetScreenFrame))"
            )
            var stale = existing
            stale.cancel()
            accessibilityFrameRetryStates.removeValue(forKey: windowId)
        }

        // Skip retry if window is being managed by ActiveFit
        if delegate?.isWindowManagedByActiveFit(windowId: windowId) ?? false {
            Logger.debug("Skipping frame retry for window \(windowId) - managed by ActiveFit")
            return
        }

        var state = FrameRetryState(targetScreenFrame: targetScreenFrame)
        scheduleNextFrameRetryAttempt(
            state: &state,
            windowId: windowId,
            element: element,
            targetScreenFrame: targetScreenFrame,
            screen: screen,
            trigger: trigger,
            policy: policy
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
        trigger: AccessibilityFrameRetryTrigger,
        policy: AccessibilityFrameRetryPolicy
    ) {
        let delays = WindowController.frameRetryDelays

        guard state.attempt < delays.count else {
            Logger.debug(
                "Frame retry exhausted for window \(windowId) after \(delays.count) attempt(s) " +
                "(trigger: \(trigger.logLabel))"
            )
            state.cancel()
            accessibilityFrameRetryStates.removeValue(forKey: windowId)
            return
        }

        let delay = delays[state.attempt]
        state.attempt += 1
        let currentAttempt = state.attempt

        state.cancel()

        let targetAccessibilityFrame = screen.screenToAccessibility(targetScreenFrame)

        Logger.debug(
            "Scheduling frame retry \(currentAttempt)/\(delays.count) for window \(windowId) " +
            "in \(String(format: "%.2f", delay))s " +
            "(trigger: \(trigger.logLabel), policy: \(policy.logLabel), target: \(targetScreenFrame))"
        )

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }

            // Clear the work item reference but keep the state (with attempt counter) for potential re-scheduling.
            if var stored = self.accessibilityFrameRetryStates[windowId] {
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

            // If the window is already at the target frame, no further retries are needed.
            if let current = self.accessibilityFrameForWindow(element: element, on: screen),
               self.framesRoughlyEqual(current, targetScreenFrame) {
                Logger.debug(
                    "Frame retry \(currentAttempt)/\(delays.count) for window \(windowId) " +
                    "- frame already at target, stopping retries"
                )
                self.accessibilityFrameRetryStates.removeValue(forKey: windowId)
                return
            }

            Logger.debug(
                "Executing frame retry \(currentAttempt)/\(delays.count) for window \(windowId) " +
                "(trigger: \(trigger.logLabel), policy: \(policy.logLabel))"
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
                    // Apply failed; schedule next attempt if available.
                    self.scheduleFollowUpRetryIfNeeded(
                        windowId: windowId, element: element,
                        targetScreenFrame: targetScreenFrame, screen: screen,
                        trigger: trigger, policy: policy
                    )
                    return
                }

                guard let final = self.accessibilityFrameForWindow(element: element, on: screen) else {
                    self.logFrameReadFailure(windowId: windowId, screen: screen, context: "retry-\(currentAttempt)")
                    self.scheduleFollowUpRetryIfNeeded(
                        windowId: windowId, element: element,
                        targetScreenFrame: targetScreenFrame, screen: screen,
                        trigger: trigger, policy: policy
                    )
                    return
                }

                if self.framesRoughlyEqual(final, targetScreenFrame) {
                    Logger.debug(
                        "Frame retry \(currentAttempt)/\(delays.count) for window \(windowId) " +
                        "- frame now matches target, stopping retries"
                    )
                    self.accessibilityFrameRetryStates.removeValue(forKey: windowId)
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
                        trigger: trigger, policy: policy
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
        trigger: AccessibilityFrameRetryTrigger,
        policy: AccessibilityFrameRetryPolicy
    ) {
        guard var state = accessibilityFrameRetryStates[windowId] else { return }

        // Re-check bounds on follow-up attempts so we stop retrying once the frame
        // is on-screen, matching the gate applied at initial scheduling time.
        if policy == .onlyWhenOffscreen {
            if let current = accessibilityFrameForWindow(element: element, on: screen) {
                let cgFrame = actualCGWindowFrame(for: windowId)
                let boundsCheckFrame = cgFrame ?? current
                if frameIsWithinBounds(boundsCheckFrame, bounds: screen.visibleScreenBounds) {
                    Logger.debug("Stopping frame retry chain for window \(windowId) - frame now within visible bounds")
                    accessibilityFrameRetryStates.removeValue(forKey: windowId)
                    return
                }
            }
        }
        scheduleNextFrameRetryAttempt(
            state: &state,
            windowId: windowId,
            element: element,
            targetScreenFrame: targetScreenFrame,
            screen: screen,
            trigger: trigger,
            policy: policy
        )
    }

    // MARK: - Update Order Decision

    /// Decide whether to set size or position first so intermediate frames stay on-screen when possible.
    private func preferredAccessibilityUpdateOrder(
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
        let status = AXUIElementSetAttributeValue(element, attribute, value)
        return status == .success
    }

    internal func setAccessibilitySize(element: AXUIElement, size: CGSize) -> Bool {
        var mutableSize = size
        guard let value = AXValueCreate(AXValueType(rawValue: kAXValueCGSizeType)!, &mutableSize) else {
            return false
        }
        let status = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value)
        return status == .success
    }
}
