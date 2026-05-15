/// CGEventTap-based interceptor for recording keyboard shortcuts in preferences
/// Captures system-level shortcuts (like Cmd-Tab) that NSEvent monitors cannot intercept

import ApplicationServices
import Carbon
import Foundation

protocol ShortcutRecordingInterceptorDelegate: AnyObject {
    /// Called when a key event is captured. The delegate should handle the shortcut.
    func shortcutRecordingInterceptor(
        _ interceptor: ShortcutRecordingInterceptor,
        didCapture keyCode: CGKeyCode,
        modifiers: CGEventFlags
    )

    /// Called when Escape is pressed with no modifiers, indicating cancel.
    func shortcutRecordingInterceptorDidCancel(_ interceptor: ShortcutRecordingInterceptor)
}

final class ShortcutRecordingInterceptor {
    private enum Constants {
        static let relevantModifierFlags: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
        static let escapeKeyCode = CGKeyCode(kVK_Escape)
    }

    weak var delegate: ShortcutRecordingInterceptorDelegate?

    private var eventTap: EventTapController?

    func start(delegate: ShortcutRecordingInterceptorDelegate) {
        self.delegate = delegate

        guard eventTap == nil else {
            Logger.debug("ShortcutRecordingInterceptor already running")
            return
        }

        let tap = EventTapController(
            name: "ShortcutRecordingInterceptor",
            events: [.keyDown, .flagsChanged],
            handler: { [weak self] type, event in
                self?.processEvent(event, type: type) ?? .pass
            }
        )
        if tap.start() {
            eventTap = tap
        }
    }

    func stop() {
        eventTap?.stop()
        eventTap = nil
        delegate = nil
        Logger.debug("ShortcutRecordingInterceptor stopped")
    }

    var isRunning: Bool {
        eventTap?.isRunning == true
    }

    private func processEvent(_ event: CGEvent, type: CGEventType) -> EventTapDecision {
        switch type {
        case .keyDown, .flagsChanged:
            break
        default:
            return .pass
        }

        // Ignore pure modifier key presses (flagsChanged without a key)
        if type == .flagsChanged {
            return .pass
        }

        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let relevantFlags = event.flags.intersection(Constants.relevantModifierFlags)

        // Escape with no modifiers = cancel
        if keyCode == Constants.escapeKeyCode && relevantFlags.isEmpty {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.shortcutRecordingInterceptorDidCancel(self)
            }
            return .swallow
        }

        // Notify delegate of the captured key
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.shortcutRecordingInterceptor(self, didCapture: keyCode, modifiers: relevantFlags)
        }

        // Swallow the event to prevent system handling (e.g., Cmd-Tab app switching)
        return .swallow
    }

    deinit {
        stop()
    }
}
