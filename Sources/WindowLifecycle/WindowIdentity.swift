import Foundation
import AppKit
import ApplicationServices

/// Snapshot of a window's identifying information for logging and debugging.
struct WindowIdentity {
    let windowId: Int
    let externalIdentifier: ExternalWindowIdentifier
    let bundleIdentifier: String?
    let windowTitle: String?

    static func make(from managed: ManagedWindow) -> WindowIdentity {
        let pid = managed.backing.pid
        let bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier

        let title: String?
        let element = managed.backing.element
        var value: CFTypeRef?
        if AXCall.copyAttribute(element, kAXTitleAttribute as CFString, &value) == .success,
           let candidate = value as? String,
           !candidate.isEmpty {
            title = candidate
        } else {
            title = nil
        }

        return WindowIdentity(
            windowId: managed.windowId,
            externalIdentifier: managed.externalIdentifier,
            bundleIdentifier: bundle,
            windowTitle: title
        )
    }

    func matches(_ managed: ManagedWindow) -> Bool {
        if managed.windowId == windowId {
            return true
        }
        if managed.externalIdentifier == externalIdentifier {
            return true
        }
        let candidateBundle = NSRunningApplication(processIdentifier: managed.backing.pid)?.bundleIdentifier
        if let bundleIdentifier,
           let candidateBundle,
           bundleIdentifier == candidateBundle,
           let windowTitle,
           let candidateTitle = currentTitle(for: managed),
           windowTitle == candidateTitle {
            return true
        }
        return false
    }

    private func currentTitle(for managed: ManagedWindow) -> String? {
        let element = managed.backing.element
        var value: CFTypeRef?
        if AXCall.copyAttribute(element, kAXTitleAttribute as CFString, &value) == .success,
           let title = value as? String,
           !title.isEmpty {
            return title
        }
        return nil
    }
}
