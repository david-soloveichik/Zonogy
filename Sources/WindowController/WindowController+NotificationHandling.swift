import Foundation
import AppKit
import ApplicationServices

/// Accessibility notification registration and handling.
extension WindowController {
    /// Register accessibility notifications for a managed window.
    internal func registerAccessibilityNotifications(for managed: ManagedWindow, appElement: AXUIElement) {
        let element = managed.backing.element
        let pid = managed.backing.pid

        let bundleId = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        guard accessibilityWatcher.ensureObserver(for: pid, appElement: appElement, bundleIdentifier: bundleId) != nil else {
            return
        }

        accessibilityWatcher.registerWindowNotifications(for: element, pid: pid)
    }

    /// Find a managed window matching an accessibility element.
    internal func managedWindow(matching element: AXUIElement) -> ManagedWindow? {
        let elementKey = AccessibilityElementKey(element: element)
        if let existing = externalWindowsByElement[elementKey] {
            return existing
        }
        if let identifier = externalIdentifier(for: element),
           let managed = externalWindows[identifier] {
            externalWindowsByElement[elementKey] = managed
            return managed
        }
        return nil
    }

    /// Handle an accessibility notification (called from observer callback).
    func handleAXNotification(element: AXUIElement, notification: CFString) {
        DispatchQueue.main.async { [weak self] in
            self?.handleAXNotificationOnMain(element: element, notification: notification)
        }
    }

    private func handleAXNotificationOnMain(element: AXUIElement, notification: CFString) {
        let notificationName = notification as String

        Logger.debug("AX notification received: \(notificationName)")

        if notificationName == axWindowCreatedNotificationName {
            handleWindowCreatedNotification(element: element)
            return
        }

        if notificationName == axMainWindowChangedNotificationName {
            handleMainWindowChangedNotification(element: element)
            return
        }

        if notificationName == "AXFocusedWindowChanged" {
            handleFocusedWindowChangedNotification(element: element)
            return
        }

        guard let managed = managedWindow(matching: element) else {
            var pid: pid_t = 0
            if AXUIElementGetPid(element, &pid) == .success, pid != getpid() {
                switch notificationName {
                case axResizedNotificationName:
                    delegate?.windowElementDidResize(element: element, pid: pid)
                case axDestroyedNotification:
                    accessibilityWatcher.removeWindowNotifications(for: element, pid: pid)
                    delegate?.windowElementDidClose(element: element, pid: pid)
                default:
                    break
                }
            }
            return
        }

        switch notificationName {
        case axDestroyedNotification:
            Logger.debug("*** AXUIElementDestroyed notification received for window \(managed.windowId)")
            delegate?.windowWillClose(windowId: managed.windowId)
            removeAccessibilityTracking(for: managed)
            externalWindows.removeValue(forKey: managed.externalIdentifier)
            windowRegistry.removeWindow(withId: managed.windowId)

        case axMiniaturizedNotification:
            Logger.debug("External window \(managed.windowId) minimized")
            delegate?.windowDidMiniaturize(windowId: managed.windowId)

        case axDeminiaturizedNotification:
            Logger.debug("External window \(managed.windowId) deminiaturized")
            delegate?.windowDidDeminiaturize(windowId: managed.windowId)

        case axMovedNotificationName:
            handleWindowMovedNotification(managed: managed)

        case axResizedNotificationName:
            handleWindowResizedNotification(managed: managed)

        default:
            break
        }
    }

    // MARK: - Notification Handlers

    private func handleWindowCreatedNotification(element: AXUIElement) {
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
            accessibilityWatcher.registerWindowNotifications(for: element, pid: pid)
        }
        delegate?.windowElementDidCreate(element: element, pid: pid)

        if capturedWindow == nil {
            Logger.debug("AXWindowCreated: Failed to capture window '\(windowTitle)' for pid \(pid), requesting capture retry")
            // If the window couldn't be captured (likely due to .cannotComplete errors),
            // notify delegate to schedule a retry
            delegate?.windowCreationFailedRetryNeeded(forPid: pid)
        }
    }

    private func handleMainWindowChangedNotification(element: AXUIElement) {
        var pid: pid_t = 0
        let status = AXUIElementGetPid(element, &pid)

        var resolvedPid: pid_t?
        if status == .success {
            resolvedPid = pid
        } else if let managed = managedWindow(matching: element) {
            resolvedPid = managed.backing.pid
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

        if focusedWindowId == nil {
            let bundleId = NSRunningApplication(processIdentifier: targetPid)?.bundleIdentifier ?? "unknown"
            Logger.debug("AXMainWindowChanged: unable to resolve focused window id for pid \(targetPid) (bundle: \(bundleId))")
        }
        delegate?.windowFocusChanged(pid: targetPid, focusedWindowId: focusedWindowId)
    }

    private func handleFocusedWindowChangedNotification(element: AXUIElement) {
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
            if focusedWindowId == nil {
                let bundleId = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "unknown"
                Logger.debug("AXFocusedWindowChanged: unable to resolve focused window id for pid \(pid) (bundle: \(bundleId))")
            }
            delegate?.windowFocusChanged(pid: pid, focusedWindowId: focusedWindowId)
        }
    }

    private func handleWindowMovedNotification(managed: ManagedWindow) {
        let isProgrammatic = programmaticUpdateWindowIds.contains(managed.windowId)
        let targetDescription = delegate?.debugTargetedZoneDescription() ?? "unknown"
        if isProgrammatic {
            Logger.debug("External window \(managed.windowId) moved (ignored programmatic update; targetedZone: \(targetDescription))")
            return
        }

        Logger.debug("External window \(managed.windowId) moved by user (targetedZone: \(targetDescription))")
        let accessibilityFrame = actualFrameInAccessibilityCoordinates(for: managed) ?? .zero
        if ensureManualDragBegan(for: managed, frame: accessibilityFrame) {
            delegate?.windowManualMoveDidUpdate(windowId: managed.windowId, frame: accessibilityFrame)
        }
    }

    private func handleWindowResizedNotification(managed: ManagedWindow) {
        // Always check full-screen state on resize (even for programmatic updates)
        // since entering/exiting full-screen fires resize notifications
        delegate?.windowDidResize(windowId: managed.windowId)

        guard !programmaticUpdateWindowIds.contains(managed.windowId) else {
            return
        }
        Logger.debug("External window \(managed.windowId) resized (non-programmatic)")
        if let screenFrame = actualFrameInScreenCoordinates(for: managed) {
            delegate?.windowManualResizeDidEnd(windowId: managed.windowId, screenId: managed.screenDisplayId, frame: screenFrame)
        } else {
            delegate?.windowManualResizeDidEnd(windowId: managed.windowId, screenId: managed.screenDisplayId, frame: .zero)
        }
    }

    // MARK: - Cleanup

    /// Remove accessibility tracking for a managed window.
    internal func removeAccessibilityTracking(for managed: ManagedWindow) {
        let element = managed.backing.element
        let pid = managed.backing.pid
        externalWindowsByElement.removeValue(forKey: AccessibilityElementKey(element: element))
        accessibilityWatcher.removeWindowNotifications(for: element, pid: pid)
    }
}
