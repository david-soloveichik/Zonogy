import Foundation
import AppKit
import ApplicationServices

/// Manages AXObservers and application/window notification registration
final class AccessibilityWatcher {
    struct ObserverSetupResult {
        let needsRetry: Bool
    }

    weak var delegate: AccessibilityWatcherDelegate?

    private let windowNotifications: [CFString]
    private let applicationNotificationNames: [String]

    private var observersByPid: [pid_t: AXObserver] = [:]
    private var applicationsByPid: [pid_t: AXUIElement] = [:]
    private var pendingNotificationNamesByPid: [pid_t: Set<String>] = [:]

    private lazy var observerRefcon: UnsafeMutableRawPointer = {
        Unmanaged.passUnretained(self).toOpaque()
    }()

    init(
        windowNotifications: [CFString],
        applicationNotifications: [CFString],
        delegate: AccessibilityWatcherDelegate? = nil
    ) {
        self.windowNotifications = windowNotifications
        self.applicationNotificationNames = applicationNotifications.map { $0 as String }
        self.delegate = delegate
    }

    func applicationElement(for pid: pid_t) -> AXUIElement {
        if let existing = applicationsByPid[pid] {
            return existing
        }
        let element = AXUIElementCreateApplication(pid)
        applicationsByPid[pid] = element
        return element
    }

    func ensureObserver(
        for pid: pid_t,
        appElement: AXUIElement,
        bundleIdentifier: String?
    ) -> ObserverSetupResult? {
        let observer: AXObserver
        let isNewObserver: Bool

        if let existing = observersByPid[pid] {
            observer = existing
            isNewObserver = false
        } else {
            var createdObserver: AXObserver?
            let status = AXObserverCreate(pid, AccessibilityWatcherObserverCallback, &createdObserver)
            guard status == .success, let createdObserver else {
                Logger.debug("Unable to create AXObserver for pid \(pid): \(status.rawValue)")
                return nil
            }
            observer = createdObserver
            observersByPid[pid] = observer
            isNewObserver = true

            let runLoopSource = AXObserverGetRunLoopSource(observer)
            CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, CFRunLoopMode.commonModes)
        }

        applicationsByPid[pid] = appElement

        var notificationsToAttempt: Set<String>
        if isNewObserver {
            notificationsToAttempt = Set(applicationNotificationNames)
        } else if let pending = pendingNotificationNamesByPid[pid] {
            notificationsToAttempt = pending
        } else {
            notificationsToAttempt = []
        }

        var stillPending: Set<String> = []
        var needsRetry = false

        for notificationName in notificationsToAttempt {
            let notification = notificationName as CFString
            let status = AXObserverAddNotification(observer, appElement, notification, observerRefcon)
            if status == .success || status == .notificationAlreadyRegistered {
                Logger.debug("Registered application AX notification '\(notificationName)' for pid \(pid)")
                continue
            }

            Logger.debug("Failed to register application AX notification \(notificationName) for pid \(pid) (AX error \(status.rawValue))")
            if status == .cannotComplete {
                stillPending.insert(notificationName)
                needsRetry = true
            }
        }

        if stillPending.isEmpty {
            pendingNotificationNamesByPid.removeValue(forKey: pid)
        } else {
            pendingNotificationNamesByPid[pid] = stillPending
            needsRetry = true
        }

        return ObserverSetupResult(needsRetry: needsRetry)
    }

    func registerWindowNotifications(for element: AXUIElement, pid: pid_t) {
        guard let observer = observersByPid[pid] else {
            return
        }

        for notification in windowNotifications {
            let status = AXObserverAddNotification(observer, element, notification, observerRefcon)
            if status == .success || status == .notificationAlreadyRegistered {
                Logger.debug("Registered window AX notification '\(notification as String)' for pid \(pid)")
            } else {
                Logger.debug("Failed to register window AX notification \(notification) for pid \(pid) (AX error \(status.rawValue))")
            }
        }
    }

    func removeWindowNotifications(for element: AXUIElement, pid: pid_t) {
        guard let observer = observersByPid[pid] else {
            return
        }

        for notification in windowNotifications {
            AXObserverRemoveNotification(observer, element, notification)
        }
    }

    func removeObserver(for pid: pid_t) {
        guard let observer = observersByPid.removeValue(forKey: pid) else {
            return
        }

        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), CFRunLoopMode.commonModes)
        applicationsByPid.removeValue(forKey: pid)
        pendingNotificationNamesByPid.removeValue(forKey: pid)
    }

    func cancelAllObservers() {
        for (pid, observer) in observersByPid {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), CFRunLoopMode.commonModes)
            applicationsByPid.removeValue(forKey: pid)
            pendingNotificationNamesByPid.removeValue(forKey: pid)
        }
        observersByPid.removeAll()
    }

    fileprivate func handleCallback(element: AXUIElement, notification: CFString) {
        delegate?.accessibilityWatcher(self, didReceive: notification, element: element)
    }
}

protocol AccessibilityWatcherDelegate: AnyObject {
    func accessibilityWatcher(_ watcher: AccessibilityWatcher, didReceive notification: CFString, element: AXUIElement)
}

private func AccessibilityWatcherObserverCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ refcon: UnsafeMutableRawPointer?
) -> Void {
    guard let refcon else { return }
    let watcher = Unmanaged<AccessibilityWatcher>.fromOpaque(refcon).takeUnretainedValue()
    watcher.handleCallback(element: element, notification: notification)
}
