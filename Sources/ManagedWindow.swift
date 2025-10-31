import Foundation
import AppKit
import ApplicationServices

/// Stable identifier for an external (Accessibility) window.
struct ExternalWindowIdentifier: Hashable {
    let pid: pid_t
    let windowNumber: Int
}

/// Backing for a managed window. Placeholders use `.appKit`, external windows use `.accessibility`.
enum ManagedWindowBacking {
    case appKit(NSWindow)
    case accessibility(element: AXUIElement, pid: pid_t, windowNumber: Int?)
}

/// Represents a window managed by the window manager.
class ManagedWindow {
    /// Unique identifier for this window within the manager.
    let windowId: Int

    /// Backing implementation (AppKit or Accessibility).
    let backing: ManagedWindowBacking

    /// Whether this is a placeholder window for an empty zone.
    let isPlaceholder: Bool

    /// The zone index this window is currently assigned to, or `nil` if minimized/unassigned.
    var zoneIndex: Int?

    init(windowId: Int, backing: ManagedWindowBacking, isPlaceholder: Bool) {
        self.windowId = windowId
        self.backing = backing
        self.isPlaceholder = isPlaceholder
        self.zoneIndex = nil
    }

    /// The underlying AppKit window, if any.
    var appKitWindow: NSWindow? {
        if case .appKit(let window) = backing {
            return window
        }
        return nil
    }

    /// The underlying accessibility element, if any.
    var accessibilityElement: AXUIElement? {
        if case .accessibility(let element, _, _) = backing {
            return element
        }
        return nil
    }

    /// Stable identifier for an external window (pid + window number).
    var externalIdentifier: ExternalWindowIdentifier? {
        if case .accessibility(_, let pid, let windowNumber?) = backing {
            return ExternalWindowIdentifier(pid: pid, windowNumber: windowNumber)
        }
        return nil
    }

    /// The actual frame currently reported by the backing window.
    var actualFrame: CGRect {
        switch backing {
        case .appKit(let window):
            return window.frame
        case .accessibility(let element, _, _):
            guard let position = ManagedWindow.copyCGPointValue(element: element, attribute: kAXPositionAttribute as CFString),
                  let size = ManagedWindow.copyCGSizeValue(element: element, attribute: kAXSizeAttribute as CFString) else {
                return .zero
            }
            return CGRect(origin: position, size: size)
        }
    }

    /// Whether the window is currently minimized.
    var isMinimized: Bool {
        switch backing {
        case .appKit(let window):
            return window.isMiniaturized
        case .accessibility(let element, _, _):
            var value: AnyObject?
            let error = AXUIElementCopyAttributeValue(element, kAXMinimizedAttribute as CFString, &value)
            if error == .success, let boolValue = value as? Bool {
                return boolValue
            }
            return false
        }
    }
}
