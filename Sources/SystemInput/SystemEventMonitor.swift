import AppKit

/// Manages NSEvent monitors and workspace notifications, forwarding to a delegate
final class SystemEventMonitor {
    weak var delegate: SystemEventMonitorDelegate?

    private var localMonitor: Any?
    private var workspaceObservers: [NSObjectProtocol] = []

    func start(delegate: SystemEventMonitorDelegate) {
        self.delegate = delegate
        installLocalMonitor()
        installWorkspaceObservers()
        delegate.systemEventMonitor(self, didActivate: NSWorkspace.shared.frontmostApplication)
    }

    func stop() {
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }

        let center = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers {
            center.removeObserver(observer)
        }
        workspaceObservers.removeAll()
    }

    private func installLocalMonitor() {
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard let self = self,
                  let delegate = self.delegate else {
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

        // Screen configuration changes
        let screenChanged = center.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.delegate?.systemEventMonitorScreensDidChange(self)
        }
        workspaceObservers.append(screenChanged)

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

        let terminate = center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self.delegate?.systemEventMonitor(self, didTerminate: application)
        }
        workspaceObservers.append(terminate)
    }

    deinit {
        stop()
    }
}

protocol SystemEventMonitorDelegate: AnyObject {
    func systemEventMonitor(_ monitor: SystemEventMonitor, handleKeyEvent event: NSEvent) -> Bool
    func systemEventMonitor(_ monitor: SystemEventMonitor, didActivate application: NSRunningApplication?)
    func systemEventMonitor(_ monitor: SystemEventMonitor, didLaunch application: NSRunningApplication?)
    func systemEventMonitor(_ monitor: SystemEventMonitor, didUnhide application: NSRunningApplication?)
    func systemEventMonitor(_ monitor: SystemEventMonitor, didDeactivate application: NSRunningApplication?)
    func systemEventMonitor(_ monitor: SystemEventMonitor, didHide application: NSRunningApplication?)
    func systemEventMonitor(_ monitor: SystemEventMonitor, didTerminate application: NSRunningApplication?)
    func systemEventMonitorScreensDidSleep(_ monitor: SystemEventMonitor)
    func systemEventMonitorScreensDidWake(_ monitor: SystemEventMonitor)
    func systemEventMonitorScreensDidChange(_ monitor: SystemEventMonitor)
}
