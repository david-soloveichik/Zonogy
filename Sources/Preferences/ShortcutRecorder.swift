/// One shortcut-recording session, shared by the shortcut table and the Zone Navigation editor.
///
/// Recording runs an event tap, so system chords (⌘⇥) can be captured, and pauses the global
/// hotkeys, so pressing one records it rather than firing it. Every captured key goes to the
/// owner, who decides whether to take it — the table takes the first acceptable chord, the editor
/// keeps listening after refusing a reserved key. The session ends when the owner stops it, on a
/// bare Escape, on a click outside the recording control, or when Zonogy stops being the active
/// app; `onEnd` runs once however it ended, so the owner has one place to redraw.
import AppKit
import Carbon

final class ShortcutRecorder: ShortcutRecordingInterceptorDelegate {
    private var interceptor: ShortcutRecordingInterceptor?
    private var clickMonitor: Any?
    private var deactivationObserver: NSObjectProtocol?
    private var recordingControl: (() -> NSView?)?
    private var onKey: ((CGKeyCode, CGEventFlags) -> Void)?
    private var onEnd: (() -> Void)?

    var isRecording: Bool { interceptor != nil }

    /// Starts a session, ending any session already running. `recordingControl` is read per
    /// click, since a table cell may be rebuilt while recording. Returns false — after showing
    /// the Input Monitoring alert — when the event tap can't start.
    @discardableResult
    func start(
        recordingControl: @escaping () -> NSView?,
        onKey: @escaping (CGKeyCode, CGEventFlags) -> Void,
        onEnd: @escaping () -> Void
    ) -> Bool {
        stop()

        AppController.shared.hotkeyService.suspend()
        let interceptor = ShortcutRecordingInterceptor()
        interceptor.start(delegate: self)
        guard interceptor.isRunning else {
            AppController.shared.hotkeyService.resume()
            Self.showInputMonitoringAlert()
            return false
        }
        self.interceptor = interceptor
        self.recordingControl = recordingControl
        self.onKey = onKey
        self.onEnd = onEnd

        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            if let self, !self.isInsideRecordingControl(event) {
                self.stop()
            }
            return event
        }
        deactivationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.stop()
        }
        return true
    }

    /// Ends the session, if one is running, and tells the owner.
    func stop() {
        guard let interceptor else { return }
        interceptor.stop()
        self.interceptor = nil
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
            self.clickMonitor = nil
        }
        if let deactivationObserver {
            NotificationCenter.default.removeObserver(deactivationObserver)
            self.deactivationObserver = nil
        }
        AppController.shared.hotkeyService.resume()

        let end = onEnd
        recordingControl = nil
        onKey = nil
        onEnd = nil
        end?()
    }

    private func isInsideRecordingControl(_ event: NSEvent) -> Bool {
        guard let control = recordingControl?(), let window = control.window, event.window === window else {
            return false
        }
        return control.convert(control.bounds, to: nil).contains(event.locationInWindow)
    }

    // MARK: - ShortcutRecordingInterceptorDelegate

    func shortcutRecordingInterceptor(
        _ interceptor: ShortcutRecordingInterceptor,
        didCapture keyCode: CGKeyCode,
        modifiers: CGEventFlags
    ) {
        onKey?(keyCode, modifiers)
    }

    func shortcutRecordingInterceptorDidCancel(_ interceptor: ShortcutRecordingInterceptor) {
        stop()
    }

    private static func showInputMonitoringAlert() {
        let alert = NSAlert()
        alert.messageText = "Input Monitoring permission is required"
        alert.informativeText = "Zonogy needs Input Monitoring permission to record system shortcuts like ⌘⇥ (Cmd-Tab). Enable it in System Settings ▸ Privacy & Security ▸ Input Monitoring, then try again."
        alert.addButton(withTitle: "OK")
        alert.alertStyle = .warning
        alert.runModal()
    }

    deinit {
        stop()
    }
}
