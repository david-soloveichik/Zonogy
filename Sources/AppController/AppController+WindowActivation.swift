import AppKit
import ApplicationServices
import Foundation

/// Window activation helpers shared across tiled and floating zone workflows.
extension AppController {
    /// Makes the window its app's main window, raises it, then activates the app (best-effort).
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

            // Make the window main and raise it before requesting activation: activation lands
            // asynchronously and fronts the app's main window, so writing main/raise afterward
            // (or racing with it) lets activation restore whichever window the app last had
            // frontmost instead of this one.
            _ = AXCall.setAttribute(element, kAXMainAttribute as CFString, kCFBooleanTrue)
            _ = AXCall.performAction(element, kAXRaiseAction as CFString)
            let result = app?.activate()

            if let logPrefix, let result {
                Logger.debug("\(logPrefix): activated pid \(pid) (result: \(result)) (reason: \(reason))")
            }

            afterRaise?()
        }
    }
}
