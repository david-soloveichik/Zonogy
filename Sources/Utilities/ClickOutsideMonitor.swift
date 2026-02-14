/// Monitors for mouse clicks outside a given window and fires a dismiss callback.
///
/// Two modes control which clicks count as "outside":
///   - `.globalOnly`:      Only clicks delivered to other processes trigger dismissal.
///                         Clicks on the app's own windows (e.g. placeholders) are ignored.
///   - `.includeOwnApp`:   Any click outside the target window triggers dismissal,
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
    private weak var window: NSWindow?
    private let onClickOutside: () -> Void

    private var globalMonitor: Any?
    private var localMonitor: Any?

    init(window: NSWindow, mode: Mode, onClickOutside: @escaping () -> Void) {
        self.window = window
        self.mode = mode
        self.onClickOutside = onClickOutside
    }

    func start() {
        guard globalMonitor == nil else { return }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, let window = self.window else { return }
            let screenPoint = NSEvent.mouseLocation
            if !window.frame.contains(screenPoint) {
                self.onClickOutside()
            }
        }

        if mode == .includeOwnApp {
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self, let window = self.window else { return event }
                // Click landed in our own app — dismiss unless it's on the monitored window itself.
                if event.window !== window {
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
