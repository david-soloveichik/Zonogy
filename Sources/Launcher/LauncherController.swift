/// Coordinates the Launcher UI, key monitoring, and window/app selection

import AppKit
import SwiftUI

protocol LauncherControllerDelegate: AnyObject {
    /// Called when a window is selected from the window list
    func launcherController(_ controller: LauncherController, didSelectWindow window: LauncherWindowItem)

    /// Called when an application should be launched
    func launcherController(_ controller: LauncherController, didLaunchApp url: URL)

    /// Called when an app header is selected (activate app without targeting a window)
    func launcherController(_ controller: LauncherController, didActivateApp bundleIdentifier: String)

    /// Called when the launcher is dismissed
    func launcherControllerDidDismiss(_ controller: LauncherController)

    /// Returns the frame of the targeted zone in screen coordinates, and its screen descriptor
    func targetedZoneFrame() -> (CGRect, ScreenDescriptor)?

    /// Returns the screen ID for the targeted zone (for fallback centering)
    func targetedScreenId() -> CGDirectDisplayID?

    /// Provides window information for the launcher
    var launcherWindowProvider: LauncherWindowProvider { get }
}

final class LauncherController {
    weak var delegate: LauncherControllerDelegate?

    private var window: LauncherWindow?
    private var model: LauncherModel?
    private var hostingView: NSHostingView<LauncherView>?
    private var keyMonitor: Any?
    private var clickMonitor: Any?
    private var lastAnchor: Anchor?
    private var autoShowGraceUntil: Date?

    private(set) var isActive = false

    /// Grace period duration for auto-show (prevents immediate dismissal from macOS auto-focus)
    private static let autoShowGracePeriod: TimeInterval = 0.5

    private enum Anchor: Equatable {
        case zone(frame: CGRect, screenId: CGDirectDisplayID)
        case screen(screenId: CGDirectDisplayID)
        case main
    }

    func toggle() {
        if isActive {
            hide()
        } else {
            show()
        }
    }

    /// Show the Launcher with a grace period that prevents immediate dismissal from focus changes.
    /// Use this when auto-showing (e.g., zone became empty) to handle macOS auto-focus behavior.
    func autoShow() {
        autoShowGraceUntil = Date().addingTimeInterval(Self.autoShowGracePeriod)
        show()
    }

    /// Returns true if the Launcher is within its auto-show grace period.
    /// During this period, focus-based dismissals should be skipped.
    var isInAutoShowGracePeriod: Bool {
        guard let graceUntil = autoShowGraceUntil else { return false }
        return Date() < graceUntil
    }

    func show() {
        guard let delegate = delegate else {
            Logger.debug("Launcher: Cannot show - no delegate")
            return
        }

        // Create model with Zonogy integration (must be on main actor)
        MainActor.assumeIsolated {
            let model = LauncherModel()
            model.windowProvider = delegate.launcherWindowProvider
            self.model = model

            // Create window if needed
            if window == nil {
                window = LauncherWindow()
            }

            // Create the SwiftUI view
            let launcherView = LauncherView(
                model: model,
                onDismiss: { [weak self] in self?.hide() },
                onLaunchApp: { [weak self] url in self?.handleAppLaunch(url: url) },
                onSelectWindow: { [weak self] window in self?.handleWindowSelection(window: window) },
                onActivateApp: { [weak self] bundleId in self?.handleAppActivation(bundleId: bundleId) }
            )

            let hostingView = NSHostingView(rootView: launcherView)
            hostingView.translatesAutoresizingMaskIntoConstraints = false
            self.hostingView = hostingView

            // Add hosting view to the visual effect view
            if let visualEffectView = window?.visualEffectView {
                visualEffectView.subviews.forEach { $0.removeFromSuperview() }
                visualEffectView.addSubview(hostingView)
                NSLayoutConstraint.activate([
                    hostingView.leadingAnchor.constraint(equalTo: visualEffectView.leadingAnchor),
                    hostingView.trailingAnchor.constraint(equalTo: visualEffectView.trailingAnchor),
                    hostingView.topAnchor.constraint(equalTo: visualEffectView.topAnchor),
                    hostingView.bottomAnchor.constraint(equalTo: visualEffectView.bottomAnchor),
                ])
            }

            // Position window on targeted zone
            if let (zoneFrame, descriptor) = delegate.targetedZoneFrame() {
                window?.centerOnZone(frame: zoneFrame, screenDescriptor: descriptor)
                self.lastAnchor = .zone(frame: zoneFrame, screenId: descriptor.displayId)
            } else if let screenId = delegate.targetedScreenId() {
                window?.centerOnScreen(screenId)
                self.lastAnchor = .screen(screenId: screenId)
            } else {
                // Fall back to main screen
                if NSScreen.main != nil {
                    window?.center()
                    self.lastAnchor = .main
                }
            }

            window?.makeKeyAndOrderFront(nil)
        }

        startKeyMonitor()
        startClickMonitor()

        isActive = true
        Logger.debug("Launcher: Opened")
    }

    func hide() {
        stopKeyMonitor()
        stopClickMonitor()

        window?.orderOut(nil)
        hostingView = nil
        model = nil
        lastAnchor = nil
        autoShowGraceUntil = nil

        isActive = false
        Logger.debug("Launcher: Closed")

        delegate?.launcherControllerDidDismiss(self)
    }

    func repositionToCurrentTarget() {
        guard isActive,
              let delegate,
              let window else {
            return
        }

        if let (zoneFrame, descriptor) = delegate.targetedZoneFrame() {
            window.centerOnZone(frame: zoneFrame, screenDescriptor: descriptor)
            lastAnchor = .zone(frame: zoneFrame, screenId: descriptor.displayId)
        } else if let screenId = delegate.targetedScreenId() {
            window.centerOnScreen(screenId)
            lastAnchor = .screen(screenId: screenId)
        } else {
            if NSScreen.main != nil {
                window.center()
            }
            lastAnchor = .main
        }
    }

    /// Makes the Launcher window key if it is currently active.
    /// Call this after system events (like wake from sleep) that may have caused the window to lose key status.
    func makeKeyIfActive() {
        guard isActive, window != nil else { return }

        // After wake from sleep, the nonactivatingPanel may not properly receive keyboard
        // focus with just makeKeyAndOrderFront. We need to also activate the app.
        // NSApp.activate is asynchronous, so we must defer makeKeyAndOrderFront until
        // the next run loop iteration when the app will be active.
        NSApp.activate(ignoringOtherApps: true)

        DispatchQueue.main.async { [weak self] in
            guard let self, self.isActive, let window = self.window else { return }
            window.makeKeyAndOrderFront(nil)
            self.model?.requestSearchFieldFocus()
            Logger.debug("Launcher: Made key after system event - isNowKey:\(window.isKeyWindow)")
        }
    }

    func repositionIfNeeded() {
        guard isActive,
              let delegate,
              let window else {
            return
        }

        let zoneInfo = delegate.targetedZoneFrame()
        let screenId = delegate.targetedScreenId()

        let newAnchor: Anchor
        if let (zoneFrame, descriptor) = zoneInfo {
            newAnchor = .zone(frame: zoneFrame, screenId: descriptor.displayId)
        } else if let screenId {
            newAnchor = .screen(screenId: screenId)
        } else {
            newAnchor = .main
        }

        guard newAnchor != lastAnchor else {
            return
        }

        if let (zoneFrame, descriptor) = zoneInfo {
            window.centerOnZone(frame: zoneFrame, screenDescriptor: descriptor)
        } else if let screenId {
            window.centerOnScreen(screenId)
        } else {
            if NSScreen.main != nil {
                window.center()
            }
        }

        lastAnchor = newAnchor
    }

    // MARK: - Event Handling

    private func handleAppLaunch(url: URL) {
        hide()
        // Dispatch async to let the UI hide before doing work
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.launcherController(self, didLaunchApp: url)
        }
    }

    private func handleWindowSelection(window: LauncherWindowItem) {
        hide()
        // Dispatch async to let the UI hide before doing work
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.launcherController(self, didSelectWindow: window)
        }
    }

    private func handleAppActivation(bundleId: String) {
        hide()
        // Dispatch async to let the UI hide before doing work
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.launcherController(self, didActivateApp: bundleId)
        }
    }

    // MARK: - Key Monitoring

    private func startKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.isActive else { return event }
            return self.handleKeyDown(event) ? nil : event
        }
    }

    private func stopKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        return MainActor.assumeIsolated {
            guard let model = model else { return false }

            switch event.keyCode {
            case 53:  // Escape
                switch model.mode {
                case .appList:
                    hide()
                case .windowList:
                    model.exitWindowMode()
                }
                return true

            case 126:  // Up arrow
                switch model.mode {
                case .appList:
                    model.moveSelection(by: -1)
                case .windowList:
                    model.moveWindowSelection(by: -1)
                }
                return true

            case 125:  // Down arrow
                switch model.mode {
                case .appList:
                    model.moveSelection(by: 1)
                case .windowList:
                    model.moveWindowSelection(by: 1)
                }
                return true

            case 36:  // Return/Enter
                switch model.mode {
                case .appList:
                    if let url = model.recordAndGetSelectedItem() {
                        handleAppLaunch(url: url)
                    }
                case .windowList:
                    if model.isAppHeaderSelected {
                        if let bundleId = model.windowModeBundleIdentifier() {
                            handleAppActivation(bundleId: bundleId)
                        }
                    } else if let windowItem = model.selectedWindowItem() {
                        handleWindowSelection(window: windowItem)
                    }
                }
                return true

            case 48:  // Tab
                let shiftPressed = event.modifierFlags.contains(.shift)
                if shiftPressed {
                    // Shift-Tab: exit window mode if in it
                    if case .windowList = model.mode {
                        model.exitWindowMode()
                        return true
                    }
                } else {
                    // Tab: enter window mode if app has multiple windows
                    if case .appList = model.mode {
                        model.enterWindowMode()
                        return true
                    }
                }
                return false

            default:
                return false
            }
        }
    }

    // MARK: - Click Outside Monitoring

    private func startClickMonitor() {
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self = self, self.isActive else { return }

            // Check if click is outside our window
            if let window = self.window {
                let windowFrame = window.frame
                let screenPoint = NSEvent.mouseLocation

                if !windowFrame.contains(screenPoint) {
                    self.hide()
                }
            }
        }
    }

    private func stopClickMonitor() {
        if let monitor = clickMonitor {
            NSEvent.removeMonitor(monitor)
            clickMonitor = nil
        }
    }
}
