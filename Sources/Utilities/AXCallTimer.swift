import AppKit
import ApplicationServices
import Foundation

// Bridge to the private AX API that reveals a window's CGWindowID. There is no public
// Accessibility attribute that exposes this identifier, so we must rely on this symbol.
// Lives here (next to the timing wrapper) because `AXCall.getWindow` is the only intended
// caller — direct callers should use the wrapper to pick up slow-call instrumentation.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

/// Times synchronous Accessibility API calls and logs anything that takes longer
/// than `thresholdSeconds`.
///
/// Each wrapped function performs IPC to the target application and runs
/// synchronously on the calling thread. When the target app is slow to respond
/// the call blocks for hundreds of milliseconds; on the main thread that surfaces
/// as a freeze, on a background queue (e.g. live-resize AX writes) it shows up as
/// stalled UI updates. We log both — the `thread=` tag distinguishes them.
///
/// Output is grep-able under the literal tag `[SLOW-AX]` and includes the call
/// name, attribute/action, duration, AX status, target pid, bundle ID, and the
/// thread the call ran on.
enum AXCall {
    /// Calls slower than this are logged. Anything below is silent.
    static var thresholdSeconds: TimeInterval = 0.1

    @discardableResult
    static func copyAttribute(
        _ element: AXUIElement,
        _ attribute: CFString,
        _ value: UnsafeMutablePointer<CFTypeRef?>
    ) -> AXError {
        let start = DispatchTime.now()
        let status = AXUIElementCopyAttributeValue(element, attribute, value)
        report(start: start, function: "AXUIElementCopyAttributeValue", detail: attribute as String, element: element, status: status)
        return status
    }

    @discardableResult
    static func setAttribute(
        _ element: AXUIElement,
        _ attribute: CFString,
        _ value: CFTypeRef
    ) -> AXError {
        let start = DispatchTime.now()
        let status = AXUIElementSetAttributeValue(element, attribute, value)
        report(start: start, function: "AXUIElementSetAttributeValue", detail: attribute as String, element: element, status: status)
        return status
    }

    @discardableResult
    static func performAction(
        _ element: AXUIElement,
        _ action: CFString
    ) -> AXError {
        let start = DispatchTime.now()
        let status = AXUIElementPerformAction(element, action)
        report(start: start, function: "AXUIElementPerformAction", detail: action as String, element: element, status: status)
        return status
    }

    @discardableResult
    static func copyElementAtPosition(
        _ application: AXUIElement,
        _ x: Float,
        _ y: Float,
        _ element: UnsafeMutablePointer<AXUIElement?>
    ) -> AXError {
        let start = DispatchTime.now()
        let status = AXUIElementCopyElementAtPosition(application, x, y, element)
        // Hit-tests are commonly issued against the system-wide element, which has no
        // useful pid of its own. When the call returned an element, prefer that — it
        // identifies the actual app whose AX server we just waited on.
        let reportingElement = element.pointee ?? application
        report(start: start, function: "AXUIElementCopyElementAtPosition", detail: "(\(x), \(y))", element: reportingElement, status: status)
        return status
    }

    @discardableResult
    static func isAttributeSettable(
        _ element: AXUIElement,
        _ attribute: CFString,
        _ settable: UnsafeMutablePointer<DarwinBoolean>
    ) -> AXError {
        let start = DispatchTime.now()
        let status = AXUIElementIsAttributeSettable(element, attribute, settable)
        report(start: start, function: "AXUIElementIsAttributeSettable", detail: attribute as String, element: element, status: status)
        return status
    }

    @discardableResult
    static func getWindow(
        _ element: AXUIElement,
        _ windowID: UnsafeMutablePointer<CGWindowID>
    ) -> AXError {
        let start = DispatchTime.now()
        let status = _AXUIElementGetWindow(element, windowID)
        report(start: start, function: "_AXUIElementGetWindow", detail: nil, element: element, status: status)
        return status
    }

    @discardableResult
    static func addObserverNotification(
        _ observer: AXObserver,
        _ element: AXUIElement,
        _ notification: CFString,
        _ refcon: UnsafeMutableRawPointer?
    ) -> AXError {
        let start = DispatchTime.now()
        let status = AXObserverAddNotification(observer, element, notification, refcon)
        report(start: start, function: "AXObserverAddNotification", detail: notification as String, element: element, status: status)
        return status
    }

    @discardableResult
    static func removeObserverNotification(
        _ observer: AXObserver,
        _ element: AXUIElement,
        _ notification: CFString
    ) -> AXError {
        let start = DispatchTime.now()
        let status = AXObserverRemoveNotification(observer, element, notification)
        report(start: start, function: "AXObserverRemoveNotification", detail: notification as String, element: element, status: status)
        return status
    }

    private static func report(
        start: DispatchTime,
        function: String,
        detail: String?,
        element: AXUIElement,
        status: AXError
    ) {
        let elapsedNs = DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds
        let durationSeconds = Double(elapsedNs) / 1_000_000_000
        guard durationSeconds >= thresholdSeconds else { return }
        let ms = Int((durationSeconds * 1000).rounded())
        let detailSuffix = detail.map { " \($0)" } ?? ""

        var pid: pid_t = 0
        let appComponent: String
        if AXUIElementGetPid(element, &pid) == .success, pid > 0 {
            let bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "unknown-bundle"
            appComponent = "pid=\(pid) bundle=\(bundle)"
        } else {
            appComponent = "pid=unknown bundle=unknown"
        }

        let threadTag = Thread.isMainThread ? "main" : "bg"

        Logger.debug(
            "[SLOW-AX] \(function)\(detailSuffix) took \(ms)ms (status: \(status.logDescription)) \(appComponent) thread=\(threadTag)"
        )
    }
}
