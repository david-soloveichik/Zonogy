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

    /// Refresh the per-window liveness timestamp used by `pruneDestroyedExternalWindows`.
    /// Receiving an AX notification (or completing any successful AX read) for a window
    /// is direct evidence that its element is still alive, so this lets the prune cache
    /// stay warm without needing a dedicated AX round trip on the next sync.
    ///
    /// `sourceElement` must be the AX element the signal was observed on. We require it
    /// to equal the window's currently-stored backing element so that a delayed
    /// notification arriving from a pre-rebind element does not falsely refresh the
    /// timestamp for the now-different backing.
    internal func noteWindowAliveFromAX(windowId: Int, sourceElement: AXUIElement) {
        guard let managed = windowRegistry.window(withId: windowId),
              CFEqual(managed.backing.element, sourceElement) else {
            return
        }
        lastConfirmedAliveAt[windowId] = Date()
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

        // Any notification we successfully resolved to a managed window is itself proof
        // that the window's AX element is alive — except the destroy notification, which
        // contradicts the signal. Refreshing here keeps the prune cache warm across the
        // long quiet periods between bursty ZoneSyncs.
        if notificationName != axDestroyedNotification {
            noteWindowAliveFromAX(windowId: managed.windowId, sourceElement: element)
        }

        switch notificationName {
        case axDestroyedNotification:
            Logger.debug("*** AXUIElementDestroyed notification received for window \(managed.windowId)")
            // Stage before notifying the delegate so deferred-prune-aware cleanup
            // (e.g. remembered-size preservation) can detect the pending entry and
            // avoid dropping state on a spurious AXDestroyed + restore cycle.
            stagePendingPrunedWindow(managed, reason: "ax-destroyed-notification")
            delegate?.windowWillClose(windowId: managed.windowId)

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
        var titleValue: CFTypeRef?
        var windowTitle = "unknown"
        if AXCall.copyAttribute(element, kAXTitleAttribute as CFString, &titleValue) == .success,
           let title = titleValue as? String {
            windowTitle = title.isEmpty ? "(empty title)" : title
        }

        Logger.debug("AXWindowCreated notification received for pid \(pid), window title: \(windowTitle)")

        let appElement = accessibilityWatcher.applicationElement(for: pid)

        // Check if this element belongs to an already-tracked window (same CGWindowID).
        // This commonly happens when macOS fires AXWindowCreated after an unminimize,
        // providing a fresh AXUIElement for the same window. We must rebind to keep
        // the stored element reference current for future AX operations (minimize, etc).
        if let identifier = externalIdentifier(for: element),
           let existing = externalWindows[identifier] {
            rebindElement(for: existing, newElement: element, appElement: appElement)
            delegate?.windowElementDidCreate(element: element, pid: pid)
            return
        }

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

        if let focusedWindowId {
            noteWindowAliveFromAX(windowId: focusedWindowId, sourceElement: element)
        } else {
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
            if let focusedWindowId {
                noteWindowAliveFromAX(windowId: focusedWindowId, sourceElement: element)
            } else {
                let bundleId = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "unknown"
                Logger.debug("AXFocusedWindowChanged: unable to resolve focused window id for pid \(pid) (bundle: \(bundleId))")
            }
            delegate?.windowFocusChanged(pid: pid, focusedWindowId: focusedWindowId)
        }
    }

    private func handleWindowMovedNotification(managed: ManagedWindow) {
        let isProgrammatic = programmaticUpdateWindowIds.contains(managed.windowId)
        let targetDescription = delegate?.debugTargetedZoneDescription() ?? "unknown"
        let accessibilityFrame = actualFrameInAccessibilityCoordinates(for: managed) ?? .zero
        if isProgrammatic {
            Logger.debug("External window \(managed.windowId) moved to \(accessibilityFrame) (ignored programmatic update; cursorTargetedZone: \(targetDescription))")
            return
        }

        Logger.debug("External window \(managed.windowId) moved to \(accessibilityFrame) (cursorTargetedZone: \(targetDescription))")
        if ensureManualDragBegan(for: managed, frame: accessibilityFrame) {
            delegate?.windowManualMoveDidUpdate(windowId: managed.windowId, frame: accessibilityFrame)
        } else {
            Logger.debug("External window \(managed.windowId) move not part of an active manual drag; no zone update issued")
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

    // MARK: - Element Rebinding

    /// Atomically rebind a managed window to a new AXUIElement (same CGWindowID).
    /// Called when macOS provides a fresh element for an already-tracked window
    /// (e.g. after a minimize→unminimize cycle fires AXWindowCreated).
    internal func rebindElement(for managed: ManagedWindow, newElement: AXUIElement, appElement: AXUIElement) {
        let oldKey = AccessibilityElementKey(element: managed.backing.element)
        let newKey = AccessibilityElementKey(element: newElement)

        guard oldKey != newKey else {
            // Same element instance; nothing to rebind.
            return
        }

        // 1. Tear down old element tracking
        removeAccessibilityTracking(for: managed)

        // 2. Update the managed window's backing element
        managed.backing.element = newElement

        // 3. Re-establish tracking with the new element
        externalWindowsByElement[newKey] = managed
        registerAccessibilityNotifications(for: managed, appElement: appElement)

        // 4. Drop any cached liveness result — it referred to the old AX element.
        lastConfirmedAliveAt.removeValue(forKey: managed.windowId)

        Logger.debug("Rebound AX element for window \(managed.windowId) (pid \(managed.backing.pid), CGWindowID \(managed.backing.cgWindowId))")
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
