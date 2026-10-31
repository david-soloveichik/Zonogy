/// Applications that stopped answering Accessibility requests. A request to such an application
/// waits out the macOS timeout before failing, so once a request fails that way, `AXCall` fails
/// the application's further requests at once, until a background check gets an answer from the
/// application or the application quits.

import ApplicationServices
import Darwin
import os

enum AXUnavailableApps {
    /// A request that fails with `.cannotComplete` after at least this long counts as a timeout,
    /// marking its application unavailable.
    static let slowFailureSeconds: TimeInterval = 1.0

    /// Pause between background checks of an unavailable application.
    static let checkIntervalSeconds: TimeInterval = 1.0

    private static let pids = OSAllocatedUnfairLock(initialState: Set<pid_t>())

    static func contains(_ pid: pid_t) -> Bool {
        pids.withLock { $0.contains(pid) }
    }

    /// Marks `pid` unavailable after one of its requests timed out, and starts checking it.
    /// `appDescription` identifies the application in the log ("pid=… bundle=…").
    static func markTimedOut(_ pid: pid_t, appDescription: String) {
        guard pids.withLock({ $0.insert(pid).inserted }) else { return }
        Logger.keep(
            "[AX-UNAVAILABLE] \(appDescription) stopped answering; its AX calls fail at once until it answers",
            category: AXCall.slowCallCategory
        )
        scheduleCheck(pid, appDescription: appDescription, since: .now())
    }

    private static func scheduleCheck(_ pid: pid_t, appDescription: String, since start: DispatchTime) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + checkIntervalSeconds) {
            let quit = kill(pid, 0) != 0 && errno == ESRCH
            // Asks directly rather than through `AXCall`, which would fail the request at once.
            var role: CFTypeRef?
            guard quit || AXUIElementCopyAttributeValue(
                AXUIElementCreateApplication(pid), kAXRoleAttribute as CFString, &role
            ) == .success else {
                scheduleCheck(pid, appDescription: appDescription, since: start)
                return
            }
            pids.withLock { _ = $0.remove(pid) }
            let seconds = Double(DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds) / 1_000_000_000
            Logger.keep(
                "[AX-UNAVAILABLE] \(appDescription) \(quit ? "quit" : "answered") after \(String(format: "%.1f", seconds))s; its AX calls resume",
                category: AXCall.slowCallCategory
            )
        }
    }
}
