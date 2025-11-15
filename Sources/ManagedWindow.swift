import Foundation
import AppKit
import ApplicationServices

/// Stable identifier for an external (Accessibility) window. Derived from
/// `_AXUIElementGetWindow`, since no public Accessibility attribute exposes a
/// Core Graphics window number.
struct ExternalWindowIdentifier: Hashable {
    let pid: pid_t
    let cgWindowId: Int  // CGWindowID from the window server
}

/// Backing for a managed window. Placeholders use `.appKit`, external windows use `.accessibility`.
enum ManagedWindowBacking {
    case appKit(NSWindow)
    // CGWindowID is captured up front via `_AXUIElementGetWindow`; we refuse to manage the
    // window if it cannot be obtained, so this value is always present once tracked.
    case accessibility(element: AXUIElement, pid: pid_t, cgWindowId: Int)  // CGWindowID from window server
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

    /// Identifier for the display this window is currently associated with.
    var screenDisplayId: CGDirectDisplayID?

    init(windowId: Int, backing: ManagedWindowBacking, isPlaceholder: Bool) {
        self.windowId = windowId
        self.backing = backing
        self.isPlaceholder = isPlaceholder
        self.zoneIndex = nil
        self.screenDisplayId = nil
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

    /// Stable identifier for an external window (pid + CGWindowID).
    var externalIdentifier: ExternalWindowIdentifier? {
        if case .accessibility(_, let pid, let cgWindowId) = backing {
            return ExternalWindowIdentifier(pid: pid, cgWindowId: cgWindowId)
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
