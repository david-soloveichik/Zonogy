import Foundation
import AppKit
import ApplicationServices

struct WindowIdentity {
    let windowId: Int
    let externalIdentifier: ExternalWindowIdentifier?
    let bundleIdentifier: String?
    let windowTitle: String?

    static func make(from managed: ManagedWindow) -> WindowIdentity {
        let bundle: String?
        if case .accessibility(_, let pid, _) = managed.backing {
            bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        } else {
            bundle = nil
        }

        let title: String?
        if let window = managed.appKitWindow {
            title = window.title.isEmpty ? nil : window.title
        } else if case .accessibility(let element, _, _) = managed.backing {
            var value: AnyObject?
            if AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &value) == .success,
               let candidate = value as? String,
               !candidate.isEmpty {
                title = candidate
            } else {
                title = nil
            }
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
        if let identifier = externalIdentifier,
           let candidate = managed.externalIdentifier,
           candidate == identifier {
            return true
        }
        if let bundleIdentifier,
           let candidateBundle: String = {
               if case .accessibility(_, let pid, _) = managed.backing {
                   return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
               }
               return nil
           }(),
           bundleIdentifier == candidateBundle,
           let windowTitle,
           let candidateTitle = currentTitle(for: managed),
           windowTitle == candidateTitle {
            return true
        }
        return false
    }

    private func currentTitle(for managed: ManagedWindow) -> String? {
        if let window = managed.appKitWindow {
            return window.title.isEmpty ? nil : window.title
        }
        if case .accessibility(let element, _, _) = managed.backing {
            var value: AnyObject?
            if AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &value) == .success,
               let title = value as? String,
               !title.isEmpty {
                return title
            }
        }
        return nil
    }
}
