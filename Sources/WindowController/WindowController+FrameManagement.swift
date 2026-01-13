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

        guard firstPass.applied else { return }

        guard let actual = accessibilityFrameForWindow(element: element, on: screen) else {
            logFrameReadFailure(windowId: windowId, screen: screen, context: "post-apply")
            scheduleAccessibilityFrameRetryIfNeeded(
                windowId: windowId,
                element: element,
                targetScreenFrame: targetScreenFrame,
                screen: screen
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
                        screen: screen
                    )
                }
            }
        } else {
            // Could not apply opposite order; schedule delayed retry
            scheduleAccessibilityFrameRetryIfNeeded(
                windowId: windowId,
                element: element,
                targetScreenFrame: targetScreenFrame,
                screen: screen
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
        delay: TimeInterval = 0.25
    ) {
        // Avoid scheduling retries while a zone resize drag is in progress.
        if delegate?.isZoneResizeDragInProgress() ?? false {
            Logger.debug("Skipping frame retry for window \(windowId) - zone resize in progress")
            return
        }

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

        guard !pendingAccessibilityFrameRetryWindowIds.contains(windowId) else { return }

        // Skip retry if window is being managed by ActiveFit
        if delegate?.isWindowManagedByActiveFit(windowId: windowId) ?? false {
            Logger.debug("Skipping frame retry for window \(windowId) - managed by ActiveFit")
            return
        }

        pendingAccessibilityFrameRetryWindowIds.insert(windowId)

        let targetAccessibilityFrame = screen.screenToAccessibility(targetScreenFrame)

        // Cancel any existing work item for this window before scheduling a new one.
        accessibilityFrameRetryWorkItems[windowId]?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }

            // Clear bookkeeping for this window's retry regardless of whether we proceed.
            self.pendingAccessibilityFrameRetryWindowIds.remove(windowId)
            self.accessibilityFrameRetryWorkItems.removeValue(forKey: windowId)

            // Skip the delayed retry as well if a zone resize is still active.
            if self.delegate?.isZoneResizeDragInProgress() ?? false {
                Logger.debug("Skipping delayed frame retry execution for window \(windowId) - zone resize in progress")
                return
            }

            // Check again at execution time in case ActiveFit was activated after scheduling
            if self.delegate?.isWindowManagedByActiveFit(windowId: windowId) ?? false {
                Logger.debug("Skipping delayed frame retry execution for window \(windowId) - now managed by ActiveFit")
                return
            }

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

                guard result.applied else { return }

                guard let final = self.accessibilityFrameForWindow(element: element, on: screen) else {
                    self.logFrameReadFailure(windowId: windowId, screen: screen, context: "delayed-retry")
                    return
                }

                if !self.framesRoughlyEqual(final, targetScreenFrame) {
                    self.logFrameMismatch(
                        windowId: windowId,
                        screen: screen,
                        context: "delayed-retry",
                        target: targetScreenFrame,
                        actual: final,
                        order: order
                    )
                }
            }
        }

        accessibilityFrameRetryWorkItems[windowId] = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
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
