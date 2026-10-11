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
/// Placeholder windows are not tracked here - they are owned by PlaceholderCoordinator.
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
    ///
    /// A managed window in no zone is normally minimized. Exceptions include a window holding a
    /// display in full screen, one not placed yet, one being dragged between zones, and a
    /// displaced window waiting out its deferred minimize. Code that must not ask the application
    /// relies on this; code that must tell the exceptions apart asks `isMinimizedPerAccessibility`.
    /// (Conversely, a window parked behind a full-screen Space is placed but effectively
    /// minimized; see `AppController.isWindowBehindFullScreenSpace`.)
    var isPlacedInZone: Bool {
        zoneIndex != nil || isInFloatingZone
    }

    /// The zone this window currently holds, as a placement destination: its floating zone,
    /// its tiling zone, or nil when it holds neither (per this window's own bookkeeping; the
    /// floating booking wins if records ever disagree).
    var zoneDestination: TargetedZoneManager.TargetedDestination? {
        if isInFloatingZone, let screenDisplayId {
            return .floating(screenId: screenDisplayId)
        }
        if let zoneIndex, let screenDisplayId {
            return .tiled(ZoneKey(screenId: screenDisplayId, index: zoneIndex))
        }
        return nil
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

    /// Whether the window is minimized according to the Accessibility API. This asks the window's
    /// application, so prefer `isPlacedInZone` unless the exceptions listed there matter.
    var isMinimizedPerAccessibility: Bool {
        ManagedWindow.isMinimizedPerAccessibility(backing.element)
    }

    /// Whether `element` is minimized according to the Accessibility API (false when the
    /// attribute cannot be read).
    static func isMinimizedPerAccessibility(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXCall.copyAttribute(element, kAXMinimizedAttribute as CFString, &value) == .success else {
            return false
        }
        return (value as? NSNumber)?.boolValue ?? false
    }
}
