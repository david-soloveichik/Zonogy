/// Detects the notifications Notification Center shows on screen, with their frames and applications.
import AppKit
import ApplicationServices

/// Watches Notification Center through Accessibility and reports the notifications it shows
/// (banners, alerts, and those in its panel) whenever that set changes.
///
/// Structure (verified on macOS 27): while notifications show, Notification Center has a
/// display-sized window (subrole AXSystemDialog) holding one AXGroup per notification, with
/// subrole AXNotificationCenterBanner or AXNotificationCenterAlert, a per-notification UUID as its
/// identifier, and a description that begins with the application's name ("<app>, <title>,
/// <subtitle>, <body>"). Its other windows are desktop widgets. A notification's frame is final
/// when it appears (it does not follow the slide-in animation). Notification Center posts AXCreated,
/// AXLayoutChanged, or AXUIElementDestroyed on its application element whenever a notification
/// appears, replaces another, moves, or leaves, so each of them triggers a rescan.
///
/// All Accessibility work runs on a private serial queue: Notification Center can take a tenth of a
/// second to answer while it builds a banner's window, and the main thread must not wait on it. The
/// observer's callback, on the main run loop, only hands the event to that queue; changes come back
/// through `MainRunLoop`, which also delivers them while a modal alert runs.
///
/// The observer is bound to Notification Center's process and goes silently inert if that process
/// exits, so the monitor watches for the exit (NSWorkspace does not report agents like it), reports
/// no notifications, and binds to the relaunched process.
final class NotificationCenterMonitor {
    struct ShownNotification: Equatable {
        let identifier: String
        /// The running application whose name begins the notification's description; nil when none
        /// matches (its application is not running, say).
        let pid: pid_t?
        /// In accessibility coordinates (origin at the primary display's top-left).
        let frame: CGRect
    }

    private static let bundleIdentifier = "com.apple.notificationcenterui"
    private static let notificationSubroles: Set<String> = ["AXNotificationCenterBanner", "AXNotificationCenterAlert"]
    private static let observedNotifications: [CFString] = [
        kAXCreatedNotification as CFString,
        kAXLayoutChangedNotification as CFString,
        kAXUIElementDestroyedNotification as CFString,
    ]
    /// Read from every element the walk visits in a single request, since Notification Center
    /// answers each request separately.
    private static let walkAttributes = [
        kAXSubroleAttribute, kAXIdentifierAttribute, kAXDescriptionAttribute,
        kAXPositionAttribute, kAXSizeAttribute, kAXChildrenAttribute,
    ] as CFArray
    /// Notifications sit four levels below their window; the bound only stops a runaway walk.
    private static let maxDepth = 8
    /// Notification Center reports each step of an animation (a hovered notification growing, the
    /// panel scrolling) as a layout change, about every 30 ms. A rescan starts at least this long
    /// after the previous one ended, and the events in between are merged into it; an event after a
    /// quiet spell rescans at once, so notifications that come or go are seen promptly.
    private static let rescanInterval: DispatchTimeInterval = .milliseconds(100)
    /// Binding attempts while Notification Center is missing or not yet observable (at login, or
    /// while launchd relaunches it), a second apart.
    private static let bindAttempts = 10
    private static let bindRetryInterval: DispatchTimeInterval = .seconds(1)

    /// Called on the main thread.
    var onChange: (([ShownNotification]) -> Void)?
    /// The notifications last reported to `onChange`; main thread only.
    private(set) var notifications: [ShownNotification] = []

    private let queue = DispatchQueue(label: "Zonogy Notification Center monitor", qos: .userInitiated)
    // The rest is confined to `queue`.
    private var observer: AXObserver?
    private var appElement: AXUIElement?
    private var exitSource: DispatchSourceProcess?
    private var lastRescan: DispatchTime?
    private var isRescanScheduled = false
    /// The notifications as of the last rescan, for detecting changes.
    private var scanned: [ShownNotification] = []

    /// Begins observing, for the rest of the process.
    func start() {
        queue.async { [weak self] in
            self?.bind(attemptsLeft: Self.bindAttempts)
        }
    }

    private func bind(attemptsLeft: Int) {
        if let pid = ApplicationIdentity.runningApplication(bundleIdentifier: Self.bundleIdentifier)?.processIdentifier,
           installObserver(pid: pid) {
            watchForExit(pid: pid)
            Logger.debug("NotificationCenterMonitor: observing Notification Center (pid \(pid))")
            // Notifications already showing produce no event until the next change.
            rescan()
            return
        }
        guard attemptsLeft > 1 else {
            Logger.error("NotificationCenterMonitor: Notification Center could not be observed; notification presses will not pre-position windows")
            return
        }
        queue.asyncAfter(deadline: .now() + Self.bindRetryInterval) { [weak self] in
            self?.bind(attemptsLeft: attemptsLeft - 1)
        }
    }

    /// Installs an observer for every event, or nothing (returning false) if any cannot be observed.
    private func installObserver(pid: pid_t) -> Bool {
        var createdObserver: AXObserver?
        guard AXCall.createObserver(pid, Self.axObserverCallback, &createdObserver) == .success, let createdObserver else {
            return false
        }
        let appElement = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for notification in Self.observedNotifications {
            let status = AXCall.addObserverNotification(createdObserver, appElement, notification, refcon)
            guard status == .success else {
                Logger.debug("NotificationCenterMonitor: cannot observe \(notification as String) yet (AX error \(status.rawValue))")
                return false
            }
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(createdObserver), .commonModes)
        observer = createdObserver
        self.appElement = appElement
        return true
    }

    private func watchForExit(pid: pid_t) {
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        source.setEventHandler { [weak self] in
            self?.handleExit()
        }
        exitSource = source
        source.resume()
    }

    private func handleExit() {
        Logger.debug("NotificationCenterMonitor: Notification Center exited; binding to its relaunch")
        exitSource?.cancel()
        exitSource = nil
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observer = nil
        appElement = nil
        publish([])
        bind(attemptsLeft: Self.bindAttempts)
    }

    /// Runs on the main run loop; everything else happens on `queue`.
    private static let axObserverCallback: AXObserverCallback = { _, _, _, refcon in
        guard let refcon else { return }
        let monitor = Unmanaged<NotificationCenterMonitor>.fromOpaque(refcon).takeUnretainedValue()
        monitor.queue.async {
            monitor.requestRescan()
        }
    }

    private func requestRescan() {
        guard !isRescanScheduled else { return }
        guard let lastRescan, DispatchTime.now() < lastRescan + Self.rescanInterval else {
            rescan()
            return
        }
        isRescanScheduled = true
        queue.asyncAfter(deadline: lastRescan + Self.rescanInterval) { [weak self] in
            self?.isRescanScheduled = false
            self?.rescan()
        }
    }

    private func rescan() {
        guard let appElement else { return }
        defer { lastRescan = .now() }
        var found: [ShownNotification] = []
        for window in elements(of: appElement, kAXWindowsAttribute) where string(of: window, kAXSubroleAttribute) == "AXSystemDialog" {
            collectNotifications(in: window, depth: 0, into: &found)
        }
        publish(found)
    }

    private func publish(_ found: [ShownNotification]) {
        guard found != scanned else { return }
        // Logged when notifications come or go, not on every frame of their animations.
        if found.map(\.identifier) != scanned.map(\.identifier) {
            let summary = found.map { notification in
                let name = notification.pid.flatMap { NSRunningApplication(processIdentifier: $0)?.localizedName }
                return "\(name ?? "unknown app") at \(notification.frame)"
            }.joined(separator: "; ")
            Logger.debug("NotificationCenterMonitor: \(found.count) notification(s) shown\(found.isEmpty ? "" : ": \(summary)")")
        }
        scanned = found
        MainRunLoop.perform { [weak self] in
            self?.notifications = found
            self?.onChange?(found)
        }
    }

    private func collectNotifications(
        in element: AXUIElement,
        depth: Int,
        into found: inout [ShownNotification]
    ) {
        var valuesArray: CFArray?
        // Empty options: an attribute the element lacks comes back as an error placeholder.
        guard AXCall.copyMultipleAttributes(element, Self.walkAttributes, AXCopyMultipleAttributeOptions(), &valuesArray) == .success,
              let values = valuesArray as? [AnyObject], values.count == 6 else {
            return
        }
        if let subrole = values[0] as? String, Self.notificationSubroles.contains(subrole) {
            if let identifier = values[1] as? String, let frame = Self.frame(position: values[3], size: values[4]) {
                let pid = Self.pid(forDescription: values[2] as? String ?? "")
                found.append(ShownNotification(identifier: identifier, pid: pid, frame: frame))
            }
            return
        }
        guard depth < Self.maxDepth, let children = AXCall.elementArray(from: values[5]) else { return }
        for child in children {
            collectNotifications(in: child, depth: depth + 1, into: &found)
        }
    }

    private static func frame(position: AnyObject, size: AnyObject) -> CGRect? {
        guard CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
              AXValueGetValue(size as! AXValue, .cgSize, &extent) else {
            return nil
        }
        return CGRect(origin: origin, size: extent)
    }

    /// Matching running applications' names, rather than cutting the description at its first comma,
    /// also keeps the notification's content out of the log. Every rescan matches anew (a lookup takes
    /// microseconds), so a notification follows its application across a relaunch.
    private static func pid(forDescription description: String) -> pid_t? {
        NSWorkspace.shared.runningApplications.first { application in
            guard let name = application.localizedName else { return false }
            return description == name || description.hasPrefix(name + ", ")
        }?.processIdentifier
    }

    private func string(of element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXCall.copyAttribute(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private func elements(of element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXCall.copyAttribute(element, attribute as CFString, &value) == .success, let value else { return [] }
        return AXCall.elementArray(from: value) ?? []
    }
}
