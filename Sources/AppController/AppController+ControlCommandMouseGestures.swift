import AppKit
import Foundation

/// Resolves per-app Control-Command mouse gesture exceptions for click and external-drag interception.
extension AppController {
    internal var isControlCommandModifierHeld: Bool {
        let flags = NSEvent.modifierFlags
        return flags.contains(.command) && flags.contains(.control)
    }

    internal func shouldPassThroughControlCommandClick(at location: CGPoint) -> Bool {
        guard let (managed, _) = managedWindowAtAccessibilityPoint(location) else {
            return false
        }

        return controlCommandMouseGesturesDisabled(
            forBundleIdentifier: NSRunningApplication(processIdentifier: managed.backing.pid)?.bundleIdentifier
        )
    }

    internal func shouldApplyControlCommandExternalDragGestures() -> Bool {
        isControlCommandModifierHeld && !controlCommandMouseGesturesDisabled(
            forBundleIdentifier: controlCommandExternalDragSourceBundleIdentifier
        )
    }

    internal func noteExternalDragSourceBundleIdentifierIfNeeded() {
        guard controlCommandExternalDragSourceBundleIdentifier == nil,
              let frontmostApp = NSWorkspace.shared.frontmostApplication,
              frontmostApp.processIdentifier != getpid() else {
            return
        }

        controlCommandExternalDragSourceBundleIdentifier = frontmostApp.bundleIdentifier
        if let bundleIdentifier = controlCommandExternalDragSourceBundleIdentifier {
            Logger.debug("Captured external drag source bundle \(bundleIdentifier)")
        }
    }

    internal func resetExternalDragSourceBundleIdentifier(reason: String) {
        guard let bundleIdentifier = controlCommandExternalDragSourceBundleIdentifier else {
            return
        }

        Logger.debug("Reset external drag source bundle \(bundleIdentifier) (reason: \(reason))")
        controlCommandExternalDragSourceBundleIdentifier = nil
    }

    private func controlCommandMouseGesturesDisabled(forBundleIdentifier bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else {
            return false
        }

        return windowController.applicationExceptionPolicy
            .disablesControlCommandMouseGestures(forBundleIdentifier: bundleIdentifier)
    }
}
