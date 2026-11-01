import AppKit

/// An application that quit, identified as it was while running: a terminated
/// `NSRunningApplication` no longer reports its pid or bundle identifier.
struct TerminatedApplication {
    let pid: pid_t
    let bundleIdentifier: String?
    let localizedName: String?
}

/// Manages NSEvent monitors, workspace notifications, and application quits, forwarding to a delegate
final class SystemEventMonitor {
    weak var delegate: SystemEventMonitorDelegate?

    private var localMonitor: Any?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var defaultCenterObservers: [NSObjectProtocol] = []
    private var runningApplicationsObservation: NSKeyValueObservation?
    /// The running applications by pid as of the last change, so a quit one can still be identified.
    private var runningApplicationsByPid: [pid_t: TerminatedApplication] = [:]

    func start(delegate: SystemEventMonitorDelegate) {
        self.delegate = delegate
        installLocalMonitor()
        installWorkspaceObservers()
        installQuitObserver()
        delegate.systemEventMonitor(self, didActivate: NSWorkspace.shared.frontmostApplication)
    }

    func stop() {
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
        runningApplicationsObservation?.invalidate()
        runningApplicationsObservation = nil

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers {
            workspaceCenter.removeObserver(observer)
        }
        workspaceObservers.removeAll()

        let defaultCenter = NotificationCenter.default
        for observer in defaultCenterObservers {
            defaultCenter.removeObserver(observer)
        }
        defaultCenterObservers.removeAll()
    }

    private func installLocalMonitor() {
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged], handler: { [weak self] event in
            guard let self = self,
                  let delegate = self.delegate else {
                return event
            }

            guard event.type == .keyDown else {
                // Key-ups and modifier changes are observed (never consumed) so locally
                // triggered hold-follow-up shortcuts can detect their chord breaking.
                delegate.systemEventMonitor(self, observeChordBreak: event)
                return event
            }

            if delegate.systemEventMonitor(self, handleKeyEvent: event) {
                return nil
            }

            return event
        })
    }

    private func installWorkspaceObservers() {
        let center = NSWorkspace.shared.notificationCenter

        // Screen sleep/wake notifications
        let screensDidSleep = center.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.delegate?.systemEventMonitorScreensDidSleep(self)
        }
        workspaceObservers.append(screensDidSleep)

        let screensDidWake = center.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.delegate?.systemEventMonitorScreensDidWake(self)
        }
        workspaceObservers.append(screensDidWake)

        // Screen configuration changes, includes when Dock position/size changes
        // NSApplication.didChangeScreenParametersNotification is posted to the default center
        let screenChanged = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.delegate?.systemEventMonitorScreensDidChange(self)
        }
        defaultCenterObservers.append(screenChanged)

        let activation = center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self.delegate?.systemEventMonitor(self, didActivate: application)
        }
        workspaceObservers.append(activation)

        let launch = center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self.delegate?.systemEventMonitor(self, didLaunch: application)
        }
        workspaceObservers.append(launch)

        let unhide = center.addObserver(
            forName: NSWorkspace.didUnhideApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self.delegate?.systemEventMonitor(self, didUnhide: application)
        }
        workspaceObservers.append(unhide)

        let deactivate = center.addObserver(
            forName: NSWorkspace.didDeactivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self.delegate?.systemEventMonitor(self, didDeactivate: application)
        }
        workspaceObservers.append(deactivate)

        let hide = center.addObserver(
            forName: NSWorkspace.didHideApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self.delegate?.systemEventMonitor(self, didHide: application)
        }
        workspaceObservers.append(hide)

        let activeSpaceChanged = center.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.delegate?.systemEventMonitorActiveSpaceDidChange(self)
        }
        workspaceObservers.append(activeSpaceChanged)
    }

    /// Reports quits from changes to `NSWorkspace.runningApplications` (delivered on the main thread),
    /// not NSWorkspace's termination notification, which macOS skips for an application that is not a
    /// regular (Dock) application when it exits: agents, and applications such as Find My that turn
    /// background-only while quitting.
    private func installQuitObserver() {
        runningApplicationsByPid = Self.currentApplicationsByPid()
        runningApplicationsObservation = NSWorkspace.shared.observe(\.runningApplications) { [weak self] _, _ in
            guard let self else { return }
            let current = Self.currentApplicationsByPid()
            let terminated = self.runningApplicationsByPid.values.filter { current[$0.pid] == nil }
            self.runningApplicationsByPid = current
            for application in terminated {
                self.delegate?.systemEventMonitor(self, didTerminate: application)
            }
        }
    }

    private static func currentApplicationsByPid() -> [pid_t: TerminatedApplication] {
        var applications: [pid_t: TerminatedApplication] = [:]
        for application in NSWorkspace.shared.runningApplications where application.processIdentifier > 0 {
            applications[application.processIdentifier] = TerminatedApplication(
                pid: application.processIdentifier,
                bundleIdentifier: application.bundleIdentifier,
                localizedName: application.localizedName
            )
        }
        return applications
    }

    deinit {
        stop()
    }
}

protocol SystemEventMonitorDelegate: AnyObject {
    func systemEventMonitor(_ monitor: SystemEventMonitor, handleKeyEvent event: NSEvent) -> Bool
    /// A local key-up or modifier change, observed without consuming it (chord-break detection).
    func systemEventMonitor(_ monitor: SystemEventMonitor, observeChordBreak event: NSEvent)
    func systemEventMonitor(_ monitor: SystemEventMonitor, didActivate application: NSRunningApplication?)
    func systemEventMonitor(_ monitor: SystemEventMonitor, didLaunch application: NSRunningApplication?)
    func systemEventMonitor(_ monitor: SystemEventMonitor, didUnhide application: NSRunningApplication?)
    func systemEventMonitor(_ monitor: SystemEventMonitor, didDeactivate application: NSRunningApplication?)
    func systemEventMonitor(_ monitor: SystemEventMonitor, didHide application: NSRunningApplication?)
    func systemEventMonitor(_ monitor: SystemEventMonitor, didTerminate application: TerminatedApplication)
    func systemEventMonitorScreensDidSleep(_ monitor: SystemEventMonitor)
    func systemEventMonitorScreensDidWake(_ monitor: SystemEventMonitor)
    func systemEventMonitorScreensDidChange(_ monitor: SystemEventMonitor)
    func systemEventMonitorActiveSpaceDidChange(_ monitor: SystemEventMonitor)
}
