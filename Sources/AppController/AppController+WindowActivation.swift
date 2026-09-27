import AppKit
import ApplicationServices
import Foundation

/// Window activation helpers shared across tiled and floating zone workflows.
extension AppController {
    /// Brings the window to the front as its app's key window and activates the app (best-effort).
    /// When the app isn't frontmost and `cgWindowId` is given, the window server activates the app
    /// with this window (`WindowServerFocus`) and the window is then raised; otherwise, or if that
    /// fails, the window is made main and raised before the app is activated. See "Focusing a
    /// specific window of another application" in SPECIFICATION-IMPLEMENTATION.md for why.
    ///
    /// This is intentionally scheduled on the main queue to avoid visual glitches where
    /// an activation/raise races with ongoing placement/resizing updates.
    internal func scheduleWindowRaise(
        pid: pid_t,
        element: AXUIElement,
        cgWindowId: Int? = nil,
        logPrefix: String? = nil,
        reason: String,
        afterRaise: (() -> Void)? = nil
    ) {
        DispatchQueue.main.async {
            if let cgWindowId,
               NSWorkspace.shared.frontmostApplication?.processIdentifier != pid,
               WindowServerFocus.activate(pid: pid, windowId: CGWindowID(cgWindowId)) {
                // The app is frontmost now, so the raise fronts the window if it is covered.
                _ = AXCall.performAction(element, kAXRaiseAction as CFString)
                if let logPrefix {
                    Logger.debug("\(logPrefix): activated pid \(pid) with window \(cgWindowId) (reason: \(reason))")
                }
            } else {
                let app = NSRunningApplication(processIdentifier: pid)
                if app == nil, let logPrefix {
                    Logger.debug("\(logPrefix): unable to resolve application for pid \(pid) (reason: \(reason))")
                }
                _ = AXCall.setAttribute(element, kAXMainAttribute as CFString, kCFBooleanTrue)
                _ = AXCall.performAction(element, kAXRaiseAction as CFString)
                let result = app?.activate()
                if let logPrefix, let result {
                    Logger.debug("\(logPrefix): activated pid \(pid) (result: \(result)) (reason: \(reason))")
                }
            }

            afterRaise?()
        }
    }
}
