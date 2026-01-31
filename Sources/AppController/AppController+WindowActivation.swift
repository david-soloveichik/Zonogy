import AppKit
import ApplicationServices
import Foundation

/// Window activation helpers shared across tiled and temporary zone workflows.
extension AppController {
    /// Activates the owning app (best-effort) and raises the window.
    ///
    /// This is intentionally scheduled on the main queue to avoid visual glitches where
    /// an activation/raise races with ongoing placement/resizing updates.
    internal func scheduleWindowRaise(
        pid: pid_t,
        element: AXUIElement,
        logPrefix: String? = nil,
        reason: String,
        afterRaise: (() -> Void)? = nil
    ) {
        DispatchQueue.main.async {
            let app = NSRunningApplication(processIdentifier: pid)
            if app == nil, let logPrefix {
                Logger.debug("\(logPrefix): unable to resolve application for pid \(pid) (reason: \(reason))")
            }

            let result = app?.activate()
            _ = AXUIElementPerformAction(element, kAXRaiseAction as CFString)

            if let logPrefix, let result {
                Logger.debug("\(logPrefix): activated pid \(pid) (result: \(result)) (reason: \(reason))")
            }

            afterRaise?()
        }
    }
}
