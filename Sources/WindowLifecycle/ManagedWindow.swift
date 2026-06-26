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
    var element: AXUIElement
    let pid: pid_t
    let cgWindowId: Int  // CGWindowID from window server
}

/// Represents an external window (from another application) managed by the window manager.
/// Placeholder windows are not tracked here - they are managed separately by PlaceholderCoordinator.
class ManagedWindow {
    /// Unique identifier for this window within the manager.
    let windowId: Int

    /// Backing implementation via accessibility.
    var backing: ManagedWindowBacking

    /// The zone index this window is currently assigned to, or `nil` if minimized/unassigned.
    var zoneIndex: Int?

    /// Identifier for the display this window is currently associated with.
    var screenDisplayId: CGDirectDisplayID?

    /// Whether this window is currently in the floating zone (floating).
    /// Maintained by FloatingZoneCoordinator.
    var isInFloatingZone: Bool = false

    /// Most recent on-screen frame in accessibility coordinates (primary-display top-left
    /// origin), refreshed on AXMoved/AXResized. Used to find a surviving native-tab sibling
    /// when the tab currently backing this window is closed — matched against the sibling's
    /// live frame, which can differ from the zone frame (ActiveFit reveal, manual/Sticky
    /// resize). Nil until the first move/resize is observed.
    var cachedFrame: CGRect?

    /// Whether this window is placed in any zone (tiled or floating).
    /// A window not placed in any zone is considered minimized from Zonogy's perspective.
    var isPlacedInZone: Bool {
        zoneIndex != nil || isInFloatingZone
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
        ManagedWindow.frame(of: backing.element) ?? .zero
    }

    /// Whether the window is currently minimized according to the Accessibility API.
    /// Prefer `isPlacedInZone` for most checks - this is only needed for edge cases
    /// like the recapture pipeline that must detect the actual OS state.
    var isMinimizedPerAccessibility: Bool {
        var value: CFTypeRef?
        let error = AXCall.copyAttribute(backing.element, kAXMinimizedAttribute as CFString, &value)
        if error == .success, let boolValue = value as? Bool {
            return boolValue
        }
        return false
    }
}
