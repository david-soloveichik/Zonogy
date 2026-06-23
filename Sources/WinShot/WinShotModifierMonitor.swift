/// Monitors modifier key state for WinShot chooser interaction (Command-Tab-like behavior)
import AppKit
import Carbon

protocol WinShotModifierMonitorDelegate: AnyObject {
    /// Called when any of the chooser's required modifier keys are released
    func winShotModifierMonitorDidReleaseModifiers(_ monitor: WinShotModifierMonitor)
}

final class WinShotModifierMonitor {
    weak var delegate: WinShotModifierMonitorDelegate?

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private(set) var isActive = false

    /// Modifiers that must stay held to keep the chooser open; releasing any of them confirms the
    /// selection. Derived from the configured "Show WinShot Switcher" shortcut.
    private var requiredModifiers: NSEvent.ModifierFlags = [.control, .command]

    /// Start monitoring for modifier key releases.
    /// - Parameter requiredModifiers: the modifier combination whose release confirms the selection.
    func start(requiredModifiers: NSEvent.ModifierFlags) {
        self.requiredModifiers = requiredModifiers

        guard !isActive else { return }

        // Monitor flagsChanged events globally (when our app is not focused)
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
        }

        // Monitor flagsChanged events locally (when our app is focused)
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }

        isActive = true
        Logger.debug("WinShot: Modifier monitor started")
    }

    /// Stop monitoring for modifier key releases
    func stop() {
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
            globalMonitor = nil
        }

        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }

        isActive = false
        Logger.debug("WinShot: Modifier monitor stopped")
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        let current = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Confirm the selection once any required modifier is released.
        if !current.contains(requiredModifiers) {
            Logger.debug("WinShot: Modifier release detected (held: \(current.rawValue), required: \(requiredModifiers.rawValue))")
            delegate?.winShotModifierMonitorDidReleaseModifiers(self)
        }
    }

    deinit {
        stop()
    }
}
