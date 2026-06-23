import AppKit
import Foundation

/// Resolves per-app mouse-gesture exceptions (gesture-modifier click and external-drag interception).
extension AppController {
    /// True while the configured gesture modifiers (Control-Command by default) are all held.
    internal var areGestureModifiersHeld: Bool {
        NSEvent.modifierFlags.contains(MouseGestureModifierPreferences.shared.modifiers.nsEventFlags)
    }

    internal func shouldPassThroughGestureModifierClick(at location: CGPoint) -> Bool {
        guard let (managed, _) = managedWindowAtAccessibilityPoint(location) else {
            return false
        }

        return mouseGesturesDisabled(
            forBundleIdentifier: NSRunningApplication(processIdentifier: managed.backing.pid)?.bundleIdentifier
        )
    }

    internal func shouldApplyGestureModifierExternalDrag() -> Bool {
        areGestureModifiersHeld && !mouseGesturesDisabled(
            forBundleIdentifier: externalDragSourceBundleIdentifier
        )
    }

    internal func noteExternalDragSourceBundleIdentifierIfNeeded() {
        guard externalDragSourceBundleIdentifier == nil,
              let frontmostApp = NSWorkspace.shared.frontmostApplication,
              frontmostApp.processIdentifier != getpid() else {
            return
        }

        externalDragSourceBundleIdentifier = frontmostApp.bundleIdentifier
        if let bundleIdentifier = externalDragSourceBundleIdentifier {
            Logger.debug("Captured external drag source bundle \(bundleIdentifier)")
        }
    }

    internal func resetExternalDragSourceBundleIdentifier(reason: String) {
        guard let bundleIdentifier = externalDragSourceBundleIdentifier else {
            return
        }

        Logger.debug("Reset external drag source bundle \(bundleIdentifier) (reason: \(reason))")
        externalDragSourceBundleIdentifier = nil
    }

    private func mouseGesturesDisabled(forBundleIdentifier bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else {
            return false
        }

        return windowController.applicationExceptionPolicy
            .disablesMouseGestures(forBundleIdentifier: bundleIdentifier)
    }
}
