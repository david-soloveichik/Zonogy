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
        let windowResult = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowObject)
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

        if let existing = existingManagedWindow(for: element) {
            Logger.debug(
                "captureWindowIfNeeded: Window already exists for pid \(pid) as managed \(existing.windowId) (CGWindowID: \(windowNumStr)), allowReturningExisting=\(allowReturningExisting)"
            )
            return allowReturningExisting ? existing : nil
        }

        let identifier = ExternalWindowIdentifier(pid: pid, cgWindowId: Int(cgWindowId))
        let elementKey = AccessibilityElementKey(element: element)
        let windowId = windowRegistry.allocateIdentifier()
        let managed = ManagedWindow(
            windowId: windowId,
            backing: ManagedWindowBacking(element: element, pid: pid, cgWindowId: identifier.cgWindowId)
        )
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
}
