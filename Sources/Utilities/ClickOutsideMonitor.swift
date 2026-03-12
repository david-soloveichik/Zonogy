/// Monitors for mouse clicks outside one or more windows and fires a dismiss callback.
///
/// Two modes control which clicks count as "outside":
///   - `.globalOnly`:      Only clicks delivered to other processes trigger dismissal.
///                         Clicks on the app's own windows (e.g. placeholders) are ignored.
///   - `.includeOwnApp`:   Any click outside the monitored windows triggers dismissal,
///                         including clicks on other windows within the same app.

import AppKit

final class ClickOutsideMonitor {
    enum Mode {
        /// Dismiss only when the user clicks in another app's window or the desktop.
        case globalOnly
        /// Dismiss on any click outside the monitored window, including other
        /// windows owned by this app (placeholders, indicators, etc.).
        case includeOwnApp
    }

    private let mode: Mode
    private let windowsProvider: () -> [NSWindow]
    private let onClickOutside: () -> Void

    private var globalMonitor: Any?
    private var localMonitor: Any?

    init(window: NSWindow, mode: Mode, onClickOutside: @escaping () -> Void) {
        self.windowsProvider = { [weak window] in
            guard let window else {
                return []
            }
            return [window]
        }
        self.mode = mode
        self.onClickOutside = onClickOutside
    }

    init(windowsProvider: @escaping () -> [NSWindow], mode: Mode, onClickOutside: @escaping () -> Void) {
        self.windowsProvider = windowsProvider
        self.mode = mode
        self.onClickOutside = onClickOutside
    }

    private func monitoredWindows() -> [NSWindow] {
        windowsProvider().filter { $0.isVisible && !$0.isMiniaturized }
    }

    private func containsScreenPoint(_ point: CGPoint, within windows: [NSWindow]) -> Bool {
        windows.contains { $0.frame.contains(point) }
    }

    private func containsEventWindow(_ eventWindow: NSWindow?, within windows: [NSWindow]) -> Bool {
        guard let eventWindow else {
            return false
        }
        return windows.contains { $0 === eventWindow }
    }

    func start() {
        guard globalMonitor == nil else { return }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self else { return }
            let windows = self.monitoredWindows()
            let screenPoint = NSEvent.mouseLocation
            if !self.containsScreenPoint(screenPoint, within: windows) {
                self.onClickOutside()
            }
        }

        if mode == .includeOwnApp {
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self else { return event }
                let windows = self.monitoredWindows()
                // Click landed in our own app — dismiss unless it's on one of the monitored windows.
                if !self.containsEventWindow(event.window, within: windows) {
                    self.onClickOutside()
                }
                return event
            }
        }
    }

    func stop() {
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
        }
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
    }

    deinit {
        stop()
    }
}
