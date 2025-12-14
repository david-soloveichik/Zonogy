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

    private(set) var isActive = false

    func toggle() {
        if isActive {
            hide()
        } else {
            show()
        }
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
            } else if let screenId = delegate.targetedScreenId() {
                window?.centerOnScreen(screenId)
            } else {
                // Fall back to main screen
                if NSScreen.main != nil {
                    window?.center()
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

        isActive = false
        Logger.debug("Launcher: Closed")

        delegate?.launcherControllerDidDismiss(self)
    }

    // MARK: - Event Handling

    private func handleAppLaunch(url: URL) {
        hide()
        delegate?.launcherController(self, didLaunchApp: url)
    }

    private func handleWindowSelection(window: LauncherWindowItem) {
        hide()
        delegate?.launcherController(self, didSelectWindow: window)
    }

    private func handleAppActivation(bundleId: String) {
        hide()
        delegate?.launcherController(self, didActivateApp: bundleId)
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
