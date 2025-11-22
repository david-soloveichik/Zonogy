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
            Logger.debug(
                "focusedWindowIfTracked: pid \(pid) -> window \(managed.windowId) (zone: \(managed.zoneIndex.map(String.init) ?? "none"), screen: \(managed.screenDisplayId.map(String.init) ?? "unknown"))"
            )
        } else {
            Logger.debug("focusedWindowIfTracked: pid \(pid) has no tracked focused window")
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
        let windowResult = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowObject)
        guard windowResult == .success, let windowObject else {
            Logger.debug("Failed to obtain focused window for pid \(pid) (AX error \(windowResult.rawValue))")
            return nil
        }

        guard CFGetTypeID(windowObject) == AXUIElementGetTypeID() else {
            Logger.debug("Focused element for pid \(pid) is not a window element")
            return nil
        }

        let windowElement = unsafeBitCast(windowObject, to: AXUIElement.self)

        if let existing = existingManagedWindow(for: windowElement) {
            Logger.debug("captureFocusedWindow: returning existing managed window \(existing.windowId) for pid \(pid)")
            return existing
        }

        guard allowCreating else {
            Logger.debug("captureFocusedWindow: focused window for pid \(pid) is not yet tracked and allowCreating=false")
            return nil
        }

        return captureWindowIfNeeded(
            element: windowElement,
            pid: pid,
            appElement: appElement,
            allowReturningExisting: true,
            notifyDelegate: true
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
        let status = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsObject)
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

        if let windowElements = windowsObject as? [AXUIElement] {
            for element in windowElements {
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
        } else if CFGetTypeID(windowsObject) == CFArrayGetTypeID() {
            let array = unsafeBitCast(windowsObject, to: CFArray.self)
            let count = CFArrayGetCount(array)
            for index in 0..<count {
                let rawElement = CFArrayGetValueAtIndex(array, index)
                let element = unsafeBitCast(rawElement, to: AXUIElement.self)
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
        }

        return CaptureResult(windows: captured, needsRetry: needsRetry)
    }

    private func captureWindowIfNeeded(
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

        guard isStandardWindow(element) else {
            Logger.debug("captureWindowIfNeeded: Window (CGWindowID: \(windowNumStr)) is not a standard window for pid \(pid)")
            return nil
        }

        if isWindowMinimized(element) {
            Logger.debug("captureWindowIfNeeded: Window is minimized for pid \(pid)")
            return nil
        }

        if let existing = existingManagedWindow(for: element) {
            Logger.debug("captureWindowIfNeeded: Window already exists for pid \(pid), allowReturningExisting=\(allowReturningExisting)")
            return allowReturningExisting ? existing : nil
        }

        let identifier = ExternalWindowIdentifier(pid: pid, cgWindowId: Int(cgWindowId))
        let elementKey = AccessibilityElementKey(element: element)
        let windowId = windowRegistry.allocateIdentifier()
        let managed = ManagedWindow(
            windowId: windowId,
            backing: .accessibility(element: element, pid: pid, cgWindowId: identifier.cgWindowId),
            isPlaceholder: false
        )
        windowRegistry.insert(managed)
        externalWindowsByElement[elementKey] = managed
        externalWindows[identifier] = managed
        Logger.debug("Captured external window \(identifier.cgWindowId) from pid \(pid) as managed id \(managed.windowId)")

        registerAccessibilityNotifications(for: managed, appElement: appElement)

        if notifyDelegate {
            Logger.debug("captureWindowIfNeeded: Notifying delegate about captured window \(managed.windowId) for pid \(pid)")
            delegate?.windowController(self, didCaptureExternalWindow: managed)
        }

        Logger.debug("captureWindowIfNeeded: Successfully captured window \(managed.windowId) for pid \(pid)")
        return managed
    }

    /// Best-effort minimization of all standard windows belonging to other applications.
    func minimizeAllExternalWindows() {
        guard ensureAccessibilityPermissions() else {
            return
        }

        for app in NSWorkspace.shared.runningApplications where !app.isTerminated && app.processIdentifier != getpid() {
            let pid = app.processIdentifier
            if let bundleId = app.bundleIdentifier,
               ignoredBundleIdentifiers.contains(bundleId) {
                Logger.debug("Skipping minimization for ignored bundle \(bundleId)")
                continue
            }
            let appElement = accessibilityWatcher.applicationElement(for: pid)

            var windowsObject: AnyObject?
            let status = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsObject)
            guard status == .success, let windowElements = windowsObject as? [AXUIElement] else {
                continue
            }

            for windowElement in windowElements {
                _ = AXUIElementSetAttributeValue(windowElement, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
            }
        }
    }

    /// Get a managed window by ID
    func window(withId windowId: Int) -> ManagedWindow? {
        return windowRegistry.window(withId: windowId)
    }

    /// Show a window at the specified frame (frame is in screen-local coordinates)
    func showWindow(_ managedWindow: ManagedWindow, at frame: CGRect, on screen: ScreenDescriptor) {
        switch managedWindow.backing {
        case .appKit(let window):
            // Convert accessibility coordinates back to Cocoa for AppKit windows
            let accessibilityFrame = screen.screenToAccessibility(frame)
            let cocoaFrame = CoordinateConversion.accessibilityToCocoa(
                accessibilityFrame: accessibilityFrame,
                primaryScreenBounds: primaryScreenBounds
            )
            window.setFrame(cocoaFrame, display: true)
            if managedWindow.isPlaceholder {
                Logger.debug("Bringing placeholder window \(managedWindow.windowId) to front via orderFront")
            }
            window.orderFront(nil)
        case .accessibility(let element, _, _):
            // Accessibility API uses screen coordinates directly
            performProgrammaticUpdate(for: managedWindow.windowId) {
                applyScreenFrameWithBestEffort(
                    windowId: managedWindow.windowId,
                    element: element,
                    targetScreenFrame: frame,
                    screen: screen
                )
            }
            _ = AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        }
        let screenIndex = ScreenContextStore.screenIndex(for: screen.displayId) ?? Int(screen.displayId)
        Logger.debug("Showed window \(managedWindow.windowId) on screen \(screenIndex) at frame \(frame)")
    }

    /// Minimize a window
    func minimizeWindow(_ managedWindow: ManagedWindow) {
        switch managedWindow.backing {
        case .appKit(let window):
            window.miniaturize(nil)
        case .accessibility(let element, _, _):
            _ = AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
        }
        Logger.debug("Minimized window \(managedWindow.windowId)")
    }

    /// Unminimize a window
    func unminimizeWindow(_ managedWindow: ManagedWindow) {
        switch managedWindow.backing {
        case .appKit(let window):
            window.deminiaturize(nil)
        case .accessibility(let element, _, _):
            _ = AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            _ = AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        }
        Logger.debug("Unminimized window \(managedWindow.windowId)")
    }

    /// Close a window
    func closeWindow(_ managedWindow: ManagedWindow) {
        switch managedWindow.backing {
        case .appKit(let window):
            window.close()
        case .accessibility(let element, _, _):
            removeAccessibilityTracking(for: managedWindow)
            _ = AXUIElementPerformAction(element, axCloseAction)
        }
        windowRegistry.removeWindow(withId: managedWindow.windowId)
        windowDelegates.removeValue(forKey: managedWindow.windowId)
        if let identifier = managedWindow.externalIdentifier {
            externalWindows.removeValue(forKey: identifier)
        }
        Logger.debug("Closed window \(managedWindow.windowId)")
    }

    /// Resize and reposition a window to match a frame (frame is in screen-local coordinates)
    func moveWindow(_ managedWindow: ManagedWindow, to frame: CGRect, on screen: ScreenDescriptor) {
        switch managedWindow.backing {
        case .appKit(let window):
            let accessibilityFrame = screen.screenToAccessibility(frame)
            let cocoaFrame = CoordinateConversion.accessibilityToCocoa(
                accessibilityFrame: accessibilityFrame,
                primaryScreenBounds: primaryScreenBounds
            )
            window.setFrame(cocoaFrame, display: true, animate: false)
        case .accessibility(let element, _, _):
            // Accessibility API uses screen coordinates directly
            performProgrammaticUpdate(for: managedWindow.windowId) {
                applyScreenFrameWithBestEffort(
                    windowId: managedWindow.windowId,
                    element: element,
                    targetScreenFrame: frame,
                    screen: screen
                )
            }
        }
        let screenIndex = ScreenContextStore.screenIndex(for: screen.displayId) ?? Int(screen.displayId)
        Logger.debug("Moved window \(managedWindow.windowId) on screen \(screenIndex) to frame \(frame)")
    }

    private enum AccessibilityUpdateOrder {
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
    private func applyScreenFrameWithBestEffort(
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
                scheduleAccessibilityFrameRetryIfNeeded(
                    windowId: windowId,
                    element: element,
                    targetScreenFrame: targetScreenFrame,
                    screen: screen
                )
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
        guard !pendingAccessibilityFrameRetryWindowIds.contains(windowId) else { return }

        // Skip retry if window is being managed by ActiveFit
        if delegate?.isWindowManagedByActiveFit(windowId: windowId) ?? false {
            Logger.debug("Skipping frame retry for window \(windowId) - managed by ActiveFit")
            return
        }

        pendingAccessibilityFrameRetryWindowIds.insert(windowId)

        let targetAccessibilityFrame = screen.screenToAccessibility(targetScreenFrame)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.pendingAccessibilityFrameRetryWindowIds.remove(windowId)

            // Check again at execution time in case ActiveFit was activated after scheduling
            if self.delegate?.isWindowManagedByActiveFit(windowId: windowId) ?? false {
                Logger.debug("Skipping delayed retry execution for window \(windowId) - now managed by ActiveFit")
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
    }

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

    private func frameIsWithinBounds(_ frame: CGRect, bounds: CGRect, tolerance: CGFloat = 1.0) -> Bool {
        return frame.minX >= bounds.minX - tolerance &&
               frame.minY >= bounds.minY - tolerance &&
               frame.maxX <= bounds.maxX + tolerance &&
               frame.maxY <= bounds.maxY + tolerance
    }

    private func framesRoughlyEqual(_ lhs: CGRect, _ rhs: CGRect, tolerance: CGFloat = 1.0) -> Bool {
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

    private func actualCGWindowFrame(for windowId: Int) -> CGRect? {
        guard let managed = windowRegistry.window(withId: windowId),
              case .accessibility(_, _, let cgWindowId) = managed.backing else {
            return nil
        }

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
    private func accessibilityFrameForWindow(element: AXUIElement, on screen: ScreenDescriptor) -> CGRect? {
        guard let position = ManagedWindow.copyCGPointValue(element: element, attribute: kAXPositionAttribute as CFString),
              let size = ManagedWindow.copyCGSizeValue(element: element, attribute: kAXSizeAttribute as CFString) else {
            return nil
        }
        let accessibilityFrame = CGRect(origin: position, size: size)
        return screen.accessibilityToScreen(accessibilityFrame)
    }

    private func performProgrammaticUpdate(for windowId: Int, _ block: () -> Void) {
        programmaticUpdateWindowIds.insert(windowId)
        block()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.programmaticUpdateWindowIds.remove(windowId)
        }
    }

    private func setAccessibilityPoint(element: AXUIElement, attribute: CFString, point: CGPoint) -> Bool {
        var mutablePoint = point
        guard let value = AXValueCreate(AXValueType(rawValue: kAXValueCGPointType)!, &mutablePoint) else {
            return false
        }
        let status = AXUIElementSetAttributeValue(element, attribute, value)
        return status == .success
    }

    private func setAccessibilitySize(element: AXUIElement, size: CGSize) -> Bool {
        var mutableSize = size
        guard let value = AXValueCreate(AXValueType(rawValue: kAXValueCGSizeType)!, &mutableSize) else {
            return false
        }
        let status = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value)
        return status == .success
    }

    private func isWindowMinimized(_ element: AXUIElement) -> Bool {
        var minimizedValue: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, kAXMinimizedAttribute as CFString, &minimizedValue)
        guard status == .success, let minimizedValue else {
            return false
        }
        if CFGetTypeID(minimizedValue) == CFBooleanGetTypeID() {
            return CFBooleanGetValue(unsafeBitCast(minimizedValue, to: CFBoolean.self))
        }
        if let number = minimizedValue as? NSNumber {
            return number.boolValue
        }
        return false
    }

    private func ensureAccessibilityPermissions() -> Bool {
        if AXIsProcessTrusted() {
            return true
        }
        if !accessibilityPermissionWarningShown {
            accessibilityPermissionWarningShown = true
            print("Zonogy requires Accessibility access. Enable it in System Settings ▸ Privacy & Security ▸ Accessibility.")
        }
        return false
    }

    private func isStandardWindow(_ element: AXUIElement) -> Bool {
        var roleObject: AnyObject?
        let roleStatus = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleObject)
        guard roleStatus == .success, let role = roleObject as? String, role == kAXWindowRole as String else {
            if roleStatus != .success {
                Logger.debug("isStandardWindow: Failed to get role attribute, AX error \(roleStatus.rawValue)")
            }
            return false
        }

        var subroleObject: AnyObject?
        let subroleStatus = AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleObject)
        if subroleStatus == .success, let subrole = subroleObject as? String {
            guard subrole == kAXStandardWindowSubrole as String else {
                Logger.debug("isStandardWindow: Window has non-standard subrole: \(subrole)")
                return false
            }
        } else if subroleStatus != .success {
            Logger.debug("isStandardWindow: Failed to get subrole attribute, AX error \(subroleStatus.rawValue)")
        }

        // Check isMovable attribute (per SPECIFICATION.md)
        // Use the same approach as winmanmon: check if position is settable
        var isPositionSettable: DarwinBoolean = false
        let settableStatus = AXUIElementIsAttributeSettable(element, kAXPositionAttribute as CFString, &isPositionSettable)
        if settableStatus != .success || !isPositionSettable.boolValue {
            if settableStatus != .success {
                Logger.debug("isStandardWindow: Failed to check if position is settable, AX error \(settableStatus.rawValue)")
            } else {
                Logger.debug("isStandardWindow: Window position is not settable (not movable)")
            }
            return false
        }

        // Check for zoom button (hasZoom) attribute (per SPECIFICATION.md)
        var zoomButtonValue: CFTypeRef?
        let zoomStatus = AXUIElementCopyAttributeValue(element, kAXZoomButtonAttribute as CFString, &zoomButtonValue)

        var hasZoomButton = false
        if zoomStatus == .success {
            if let zoomButtonValue {
                let typeId = CFGetTypeID(zoomButtonValue)
                if typeId == CFNullGetTypeID() {
                    Logger.debug("isStandardWindow: Zoom button attribute returned CFNull (no zoom button)")
                } else if typeId == AXValueGetTypeID() {
                    let axValue = zoomButtonValue as! AXValue
                    let valueType = AXValueGetType(axValue)
                    let axErrorTypeRawValue: UInt32 = 5  // kAXValueAXErrorType
                    if valueType.rawValue == axErrorTypeRawValue {
                        var underlyingError = AXError.success
                        if AXValueGetValue(axValue, valueType, &underlyingError) {
                            Logger.debug("isStandardWindow: Zoom button attribute returned AX error \(underlyingError.rawValue)")
                        } else {
                            Logger.debug("isStandardWindow: Zoom button attribute returned AX error type value without readable code")
                        }
                    } else {
                        hasZoomButton = true
                    }
                } else {
                    hasZoomButton = true
                }
            } else {
                Logger.debug("isStandardWindow: Zoom button attribute returned nil (no zoom button)")
            }
        } else if zoomStatus == .noValue {
            Logger.debug("isStandardWindow: Zoom button attribute reports no value (no zoom button)")
        } else {
            Logger.debug("isStandardWindow: Failed to get zoom button attribute, AX error \(zoomStatus.rawValue)")
        }

        if !hasZoomButton {
            Logger.debug("isStandardWindow: Window has no zoom button")
            return false
        }

        // Check window height (must be >= 250px tall)
        if let size = ManagedWindow.copyCGSizeValue(element: element, attribute: kAXSizeAttribute as CFString) {
            if size.height < 250 {
                Logger.debug("isStandardWindow: Window height \(size.height) is less than 250px minimum")
                return false
            }
        } else {
            // If we can't get the size, we treat it as not meeting the criteria
            Logger.debug("isStandardWindow: Unable to get window size for height check")
            return false
        }

        return true
    }

    private func externalIdentifier(for element: AXUIElement) -> ExternalWindowIdentifier? {
        var pid: pid_t = 0
        let pidStatus = AXUIElementGetPid(element, &pid)
        guard pidStatus == .success else {
            return nil
        }

        let result = cgWindowIdWithStatus(for: element, pid: pid, context: "externalIdentifier")
        guard let cgWindowId = result.id else {
            return nil
        }

        return ExternalWindowIdentifier(pid: pid, cgWindowId: Int(cgWindowId))
    }

    private func cgWindowIdWithStatus(for element: AXUIElement, pid: pid_t, context: String) -> (id: CGWindowID?, axError: AXError?) {
        var cgWindowId: CGWindowID = 0
        let status = _AXUIElementGetWindow(element, &cgWindowId)
        guard status == .success else {
            Logger.debug("cgWindowId(\(context)): _AXUIElementGetWindow failed for pid \(pid) with AXError \(status.rawValue)")
            return (nil, status)
        }
        guard cgWindowId != 0 else {
            Logger.debug("cgWindowId(\(context)): Received CGWindowID 0 for pid \(pid); treating as missing")
            return (nil, nil)
        }
        return (cgWindowId, nil)
    }

    private var retryableAXWindowErrors: Set<AXError> {
        [.cannotComplete, .illegalArgument]
    }

    private func registerAccessibilityNotifications(for managed: ManagedWindow, appElement: AXUIElement) {
        guard case .accessibility(let element, let pid, _) = managed.backing else {
            return
        }

        let bundleId = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        guard accessibilityWatcher.ensureObserver(for: pid, appElement: appElement, bundleIdentifier: bundleId) != nil else {
            return
        }

        accessibilityWatcher.registerWindowNotifications(for: element, pid: pid)
    }

    private func managedWindow(matching element: AXUIElement) -> ManagedWindow? {
        for window in windowRegistry.allWindows {
            if let candidate = window.accessibilityElement, CFEqual(candidate, element) {
                return window
            }
        }
        if let identifier = externalIdentifier(for: element) {
            return externalWindows[identifier]
        }
        return nil
    }

    func handleAXNotification(element: AXUIElement, notification: CFString) {
        DispatchQueue.main.async { [weak self] in
            self?.handleAXNotificationOnMain(element: element, notification: notification)
        }
    }

    private func handleAXNotificationOnMain(element: AXUIElement, notification: CFString) {
        let notificationName = notification as String

        Logger.debug("AX notification received: \(notificationName)")

        if notificationName == axWindowCreatedNotificationName {
            var pid: pid_t = 0
            let status = AXUIElementGetPid(element, &pid)
            guard status == .success, pid != getpid() else {
                return
            }

            if let bundleId = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
               ignoredBundleIdentifiers.contains(bundleId) {
                return
            }

            // Get window title for debugging
            var titleValue: AnyObject?
            var windowTitle = "unknown"
            if AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleValue) == .success,
               let title = titleValue as? String {
                windowTitle = title.isEmpty ? "(empty title)" : title
            }

            Logger.debug("AXWindowCreated notification received for pid \(pid), window title: \(windowTitle)")

            let appElement = accessibilityWatcher.applicationElement(for: pid)

            let capturedWindow = captureWindowIfNeeded(
                element: element,
                pid: pid,
                appElement: appElement,
                allowReturningExisting: false,
                notifyDelegate: true
            )

            if capturedWindow == nil {
                Logger.debug("AXWindowCreated: Failed to capture window '\(windowTitle)' for pid \(pid), requesting capture retry")
                // If the window couldn't be captured (likely due to .cannotComplete errors),
                // notify delegate to schedule a retry
                delegate?.windowCreationFailedRetryNeeded(forPid: pid)
            }
            return
        }

        if notificationName == axMainWindowChangedNotificationName {
            var pid: pid_t = 0
            let status = AXUIElementGetPid(element, &pid)

            var resolvedPid: pid_t?
            if status == .success {
                resolvedPid = pid
            } else if let managed = managedWindow(matching: element),
                      case .accessibility(_, let managedPid, _) = managed.backing {
                resolvedPid = managedPid
            }

            guard let targetPid = resolvedPid, targetPid != getpid() else {
                return
            }

            Logger.debug("AX main window changed for pid \(targetPid)")

            let appElement = accessibilityWatcher.applicationElement(for: targetPid)
            var focusedWindowId: Int?

            if status == .success {
                let captured = captureWindowIfNeeded(
                    element: element,
                    pid: targetPid,
                    appElement: appElement,
                    allowReturningExisting: true,
                    notifyDelegate: true
                )
                focusedWindowId = captured?.windowId
            } else if let managed = managedWindow(matching: element) {
                focusedWindowId = managed.windowId
            }

            delegate?.windowFocusChanged(pid: targetPid, focusedWindowId: focusedWindowId)
            return
        }

        if notificationName == "AXFocusedWindowChanged" {
            // When focus changes, validate windows for the application
            // This catches window closures that didn't fire destroy notifications
            var pid: pid_t = 0
            let status = AXUIElementGetPid(element, &pid)
            if status == .success, pid != getpid() {
                Logger.debug("Focus changed in app pid \(pid), validating windows")
                var focusedWindowId: Int?
                let appElement = accessibilityWatcher.applicationElement(for: pid)
                let captured = captureWindowIfNeeded(
                    element: element,
                    pid: pid,
                    appElement: appElement,
                    allowReturningExisting: true,
                    notifyDelegate: true
                )
                if let captured {
                    focusedWindowId = captured.windowId
                } else if let managed = managedWindow(matching: element) {
                    focusedWindowId = managed.windowId
                }
                delegate?.windowFocusChanged(pid: pid, focusedWindowId: focusedWindowId)
            }
            return
        }

        guard let managed = managedWindow(matching: element) else {
            return
        }

        switch notificationName {
        case axDestroyedNotification:
            Logger.debug("*** AXUIElementDestroyed notification received for window \(managed.windowId)")
            delegate?.windowWillClose(windowId: managed.windowId)
            removeAccessibilityTracking(for: managed)
            if let identifier = managed.externalIdentifier {
                externalWindows.removeValue(forKey: identifier)
            }
            windowRegistry.removeWindow(withId: managed.windowId)

        case axMiniaturizedNotification:
            Logger.debug("External window \(managed.windowId) minimized")
            delegate?.windowDidMiniaturize(windowId: managed.windowId)

        case axDeminiaturizedNotification:
            Logger.debug("External window \(managed.windowId) deminiaturized")
            delegate?.windowDidDeminiaturize(windowId: managed.windowId)

        case axMovedNotificationName:
            let isProgrammatic = programmaticUpdateWindowIds.contains(managed.windowId)
            let targetDescription = delegate?.debugTargetedZoneDescription() ?? "unknown"
            if isProgrammatic {
                Logger.debug("External window \(managed.windowId) moved (ignored programmatic update; placeholderResizeActive: \(isPlaceholderLiveResizeActive), targetedZone: \(targetDescription))")
                return
            }

            Logger.debug("External window \(managed.windowId) moved by user (placeholderResizeActive: \(isPlaceholderLiveResizeActive), targetedZone: \(targetDescription))")
            let accessibilityFrame = actualFrameInAccessibilityCoordinates(for: managed) ?? .zero
            if ensureManualDragBegan(for: managed, frame: accessibilityFrame) {
                delegate?.windowManualMoveDidUpdate(windowId: managed.windowId, frame: accessibilityFrame)
            }

        case axResizedNotificationName:
            guard !programmaticUpdateWindowIds.contains(managed.windowId) else {
                return
            }
            Logger.debug("External window \(managed.windowId) resized by user")
            if let screenFrame = actualFrameInScreenCoordinates(for: managed) {
                delegate?.windowManualResizeDidEnd(windowId: managed.windowId, screenId: managed.screenDisplayId, frame: screenFrame)
            } else {
                delegate?.windowManualResizeDidEnd(windowId: managed.windowId, screenId: managed.screenDisplayId, frame: .zero)
            }

        default:
            break
        }
    }

    internal func removeAccessibilityTracking(for managed: ManagedWindow) {
        guard case .accessibility(let element, let pid, _) = managed.backing else {
            return
        }

        externalWindowsByElement.removeValue(forKey: AccessibilityElementKey(element: element))
        accessibilityWatcher.removeWindowNotifications(for: element, pid: pid)

        let stillManaged = windowRegistry.contains { window in
            guard case .accessibility(_, let otherPid, _) = window.backing else {
                return false
            }
            return otherPid == pid && window.windowId != managed.windowId
        }

        if !stillManaged {
            accessibilityWatcher.removeObserver(for: pid)
        }
    }

    /// Detect and prune external windows whose accessibility elements have been destroyed.
    /// Uses the window server as the ground truth source.
    /// - Returns: The window identifiers that were removed.
}
