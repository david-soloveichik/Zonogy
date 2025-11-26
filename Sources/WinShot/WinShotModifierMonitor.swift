/// Monitors modifier key state for WinShot chooser interaction (Command-Tab-like behavior)
import AppKit
import Carbon

protocol WinShotModifierMonitorDelegate: AnyObject {
    /// Called when the required modifier keys (Control-Command) are released
    func winShotModifierMonitorDidReleaseModifiers(_ monitor: WinShotModifierMonitor)
}

final class WinShotModifierMonitor {
    weak var delegate: WinShotModifierMonitorDelegate?

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private(set) var isActive = false

    /// Start monitoring for modifier key releases
    func start() {
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

        // Check if required modifiers (Control-Command) were released
        let hasControl = current.contains(.control)
        let hasCommand = current.contains(.command)

        if !hasControl || !hasCommand {
            Logger.debug("WinShot: Modifier release detected (control: \(hasControl), command: \(hasCommand))")
            delegate?.winShotModifierMonitorDidReleaseModifiers(self)
        }
    }

    deinit {
        stop()
    }
}
