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

/// Backing for a managed external window via accessibility.
/// CGWindowID is captured up front via `_AXUIElementGetWindow`; we refuse to manage the
/// window if it cannot be obtained, so this value is always present once tracked.
struct ManagedWindowBacking {
    let element: AXUIElement
    let pid: pid_t
    let cgWindowId: Int  // CGWindowID from window server
}

/// Represents an external window (from another application) managed by the window manager.
/// Placeholder windows are not tracked here - they are managed separately by PlaceholderCoordinator.
class ManagedWindow {
    /// Unique identifier for this window within the manager.
    let windowId: Int

    /// Backing implementation via accessibility.
    let backing: ManagedWindowBacking

    /// The zone index this window is currently assigned to, or `nil` if minimized/unassigned.
    var zoneIndex: Int?

    /// Identifier for the display this window is currently associated with.
    var screenDisplayId: CGDirectDisplayID?

    /// Whether this window is currently in the temporary zone (floating).
    /// Maintained by TemporaryZoneCoordinator.
    var isInTemporaryZone: Bool = false

    /// Whether this window is placed in any zone (tiled or temporary).
    /// A window not placed in any zone is considered minimized from Zonogy's perspective.
    var isPlacedInZone: Bool {
        zoneIndex != nil || isInTemporaryZone
    }

    init(windowId: Int, backing: ManagedWindowBacking) {
        self.windowId = windowId
        self.backing = backing
        self.zoneIndex = nil
        self.screenDisplayId = nil
    }

    /// The underlying accessibility element.
    var accessibilityElement: AXUIElement {
        backing.element
    }

    /// Stable identifier for this external window (pid + CGWindowID).
    var externalIdentifier: ExternalWindowIdentifier {
        ExternalWindowIdentifier(pid: backing.pid, cgWindowId: backing.cgWindowId)
    }

    /// The actual frame currently reported by the backing window.
    var actualFrame: CGRect {
        guard let position = ManagedWindow.copyCGPointValue(element: backing.element, attribute: kAXPositionAttribute as CFString),
              let size = ManagedWindow.copyCGSizeValue(element: backing.element, attribute: kAXSizeAttribute as CFString) else {
            return .zero
        }
        return CGRect(origin: position, size: size)
    }

    /// Whether the window is currently minimized according to the Accessibility API.
    /// Prefer `isPlacedInZone` for most checks - this is only needed for edge cases
    /// like the recapture pipeline that must detect the actual OS state.
    var isMinimizedPerAccessibility: Bool {
        var value: AnyObject?
        let error = AXUIElementCopyAttributeValue(backing.element, kAXMinimizedAttribute as CFString, &value)
        if error == .success, let boolValue = value as? Bool {
            return boolValue
        }
        return false
    }
}
