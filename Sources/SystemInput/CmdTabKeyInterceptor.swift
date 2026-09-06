/// Intercepts the configured CmdTab keyboard chord via a global CGEventTap (Input Monitoring).
///
/// The tap is serviced by `EventTapThread`, so its callback answers while the main thread is busy
/// and never holds up keystrokes bound for other apps. The callback decides only what a keystroke
/// means for the engaged session and hands every action to the main queue, in keystroke order; the
/// delegate acts on the chooser there, ignoring an action that arrives after the chooser is gone.
/// A session ends on the tap thread at the keys that end it (modifier release, Escape, N), so a
/// fresh press of the chord starts the next session at once, and from the main thread when the
/// chooser is dismissed some other way (`endEngagement`), so the session state is guarded by a lock.

import ApplicationServices
import Carbon
import Foundation

/// Mode for CmdTab window filtering
enum CmdTabMode {
    case allWindows
    case currentAppOnly
}

/// Every call arrives on the main queue in keystroke order, after the show that opened its session.
/// A call for a chooser that is not showing (never shown, or dismissed since) is ignored there.
protocol CmdTabKeyInterceptorDelegate: AnyObject {
    /// Show CmdTab for a newly engaged session. `engagement` names the session to `endEngagement`.
    func cmdTabKeyInterceptorShowCmdTab(_ interceptor: CmdTabKeyInterceptor, engagement: CmdTabKeyInterceptor.Engagement, initialDirection: CmdTabKeyInterceptor.Direction, mode: CmdTabMode)

    /// Cycle CmdTab selection in the given direction.
    func cmdTabKeyInterceptor(_ interceptor: CmdTabKeyInterceptor, cycle direction: CmdTabKeyInterceptor.Direction)

    /// Activate the currently selected CmdTab window (the chord's modifiers were released).
    func cmdTabKeyInterceptorActivateSelection(_ interceptor: CmdTabKeyInterceptor)

    /// Switch CmdTab to a different mode (e.g., all-windows ↔ current-app).
    func cmdTabKeyInterceptorSwitchMode(_ interceptor: CmdTabKeyInterceptor, mode: CmdTabMode)

    /// Cancel CmdTab without activation.
    func cmdTabKeyInterceptorCancel(_ interceptor: CmdTabKeyInterceptor)

    /// Forward a "new window" request (Cmd-N) to the current app, then dismiss CmdTab.
    func cmdTabKeyInterceptorForwardNewWindow(_ interceptor: CmdTabKeyInterceptor)
}

final class CmdTabKeyInterceptor {
    enum Direction {
        case next
        case previous
    }

    /// Names one engaged session, so an ending decided on the main thread (the chooser shown for
    /// the session was dismissed) applies to that session and not to one engaged since.
    struct Engagement: Equatable {
        fileprivate let id: UInt64
    }

    private enum Constants {
        static let relevantModifierFlags: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
        static let escapeKeyCode = CGKeyCode(kVK_Escape)
        static let nKeyCode = CGKeyCode(kVK_ANSI_N)
    }

    weak var delegate: CmdTabKeyInterceptorDelegate?

    private var eventTap: EventTapController?

    /// Guards the session state below: the tap callback works on the tap thread; `isSuspended`,
    /// `endEngagement`, and `stop` run on the main thread. Entry points take the lock; the private
    /// handlers assume it is held.
    private let lock = NSLock()
    /// The binding the current session engaged on; nil while no session is engaged.
    private var engagedShortcut: EngagedShortcut?
    /// The current session, or the most recent one once it has ended.
    private var engagement = Engagement(id: 0)
    private var suspended = false

    /// While true (hotkeys suspended, e.g. while recording a shortcut) every keystroke passes.
    var isSuspended: Bool {
        get { lock.withLock { suspended } }
        set { lock.withLock { suspended = newValue } }
    }

    /// The binding a session engaged on, and the chooser mode it opened.
    struct EngagedShortcut {
        let shortcut: KeyboardShortcut
        let mode: CmdTabMode

        var keyCode: CGKeyCode { CGKeyCode(shortcut.keyCode) }
        var requiredModifiers: CGEventFlags { shortcut.cgEventFlags }
        /// Whether Shift is part of the binding itself, leaving no Shift to add for reverse cycling.
        var shiftIsRequired: Bool { shortcut.modifiers & UInt32(shiftKey) != 0 }
    }

    /// The chords a CmdTab binding claims: the binding, and — unless Shift is already part of it —
    /// the same chord with Shift added, for reverse cycling. The tap engages on exactly these (see
    /// `handleKeyDown`), and Preferences flags a shortcut on either as a conflict
    /// (`ShortcutConflicts`), so the rule lives here once.
    static func claimedShortcuts(for shortcut: KeyboardShortcut) -> [KeyboardShortcut] {
        guard shortcut.modifiers & UInt32(shiftKey) == 0 else { return [shortcut] }
        return [shortcut, KeyboardShortcut(keyCode: shortcut.keyCode, modifiers: shortcut.modifiers | UInt32(shiftKey))]
    }

    /// The CmdTab actions and the chooser mode each opens: all windows, then current app only.
    private static let bindings: [(mode: CmdTabMode, action: KeyboardShortcutPreferences.ShortcutAction)] = [
        (.allWindows, .showCmdTab), (.currentAppOnly, .showCmdTabCurrentApp),
    ]

    /// The configured CmdTab bindings with the mode each opens.
    private static func configuredShortcuts() -> [(mode: CmdTabMode, shortcut: KeyboardShortcut)] {
        let preferences = KeyboardShortcutPreferences.shared
        return bindings.compactMap { binding in
            preferences.shortcut(for: binding.action).map { (mode: binding.mode, shortcut: $0) }
        }
    }

    /// The binding a disengaged key-down engages on, if any: its own chord, or the chord with Shift
    /// added when the binding leaves Shift free for reverse cycling (`claimedShortcuts`). Runs for
    /// every modified key-down in every app, so nothing is built until the key code matches.
    private static func engagingShortcut(keyCode: CGKeyCode, relevantFlags: CGEventFlags) -> EngagedShortcut? {
        let preferences = KeyboardShortcutPreferences.shared
        for binding in bindings {
            guard let shortcut = preferences.shortcut(for: binding.action),
                  keyCode == CGKeyCode(shortcut.keyCode),
                  claimedShortcuts(for: shortcut).contains(where: { $0.cgEventFlags == relevantFlags }) else {
                continue
            }
            return EngagedShortcut(shortcut: shortcut, mode: binding.mode)
        }
        return nil
    }

    func start(delegate: CmdTabKeyInterceptorDelegate) {
        self.delegate = delegate

        guard eventTap == nil else {
            Logger.debug("CmdTabKeyInterceptor already running")
            return
        }

        let tap = EventTapController(
            name: "CmdTab keyboard interceptor",
            events: [.keyDown, .flagsChanged],
            runLoop: EventTapThread.keyboard.runLoop,
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
        lock.withLock { engagedShortcut = nil }
    }

    /// Ends `engagement` if it is still the current session. The delegate calls this once the
    /// chooser shown for the session is gone, however it went; a session engaged since is untouched.
    func endEngagement(_ engagement: Engagement) {
        lock.withLock {
            if self.engagement == engagement {
                engagedShortcut = nil
            }
        }
    }

    /// Hands an action to the delegate on the main queue.
    private func dispatchToMain(_ action: @escaping (CmdTabKeyInterceptor, CmdTabKeyInterceptorDelegate) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let delegate = self.delegate else { return }
            action(self, delegate)
        }
    }

    private func processEvent(_ event: CGEvent, type: CGEventType) -> EventTapDecision {
        lock.withLock {
            guard !suspended else {
                return .pass
            }
            let relevantFlags = event.flags.intersection(Constants.relevantModifierFlags)
            switch type {
            case .flagsChanged:
                return handleFlagsChanged(relevantFlags: relevantFlags)
            case .keyDown:
                return handleKeyDown(event: event, relevantFlags: relevantFlags)
            default:
                return .pass
            }
        }
    }

    private func handleFlagsChanged(relevantFlags: CGEventFlags) -> EventTapDecision {
        guard let engagedShortcut else {
            return .pass
        }

        // The session ends when any required modifier is released, activating the selection.
        if !relevantFlags.contains(engagedShortcut.requiredModifiers) {
            self.engagedShortcut = nil
            dispatchToMain { interceptor, delegate in
                delegate.cmdTabKeyInterceptorActivateSelection(interceptor)
            }
        }
        return .pass
    }

    private func handleKeyDown(event: CGEvent, relevantFlags: CGEventFlags) -> EventTapDecision {
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))

        if let engagedShortcut {
            return handleKeyDownWhileEngaged(keyCode: keyCode, relevantFlags: relevantFlags, engagedShortcut: engagedShortcut)
        }

        // Ordinary typing exits here: a CmdTab binding always carries a modifier (the recorder and
        // the load path both reject one without), so an unmodified key-down can't engage.
        guard !relevantFlags.isEmpty,
              let shortcut = Self.engagingShortcut(keyCode: keyCode, relevantFlags: relevantFlags) else {
            return .pass
        }

        // Engage at once, so repeated presses are swallowed while the show is still queued.
        engagedShortcut = shortcut
        engagement = Engagement(id: engagement.id + 1)
        let engagement = self.engagement
        let direction = Self.direction(for: relevantFlags, engagedShortcut: shortcut)
        dispatchToMain { interceptor, delegate in
            delegate.cmdTabKeyInterceptorShowCmdTab(interceptor, engagement: engagement, initialDirection: direction, mode: shortcut.mode)
        }

        // Swallow to override the system app switcher.
        return .swallow
    }

    private func handleKeyDownWhileEngaged(keyCode: CGKeyCode, relevantFlags: CGEventFlags, engagedShortcut: EngagedShortcut) -> EventTapDecision {
        // Cancel (even while modifiers are held). The session ends here, so a fresh press of the
        // chord opens the next chooser even while this cancel is still queued.
        if keyCode == Constants.escapeKeyCode {
            self.engagedShortcut = nil
            dispatchToMain { interceptor, delegate in
                delegate.cmdTabKeyInterceptorCancel(interceptor)
            }
            return .swallow
        }

        // Forward a "new window" request (Cmd-N) to the current app, then dismiss. The chord's
        // modifier (Command, by default) is still held, so pressing N alone is already Cmd-N. N is
        // swallowed so the keystroke can't leak to the app and double-fire, and like Escape it ends
        // the session here.
        if keyCode == Constants.nKeyCode, keyCode != engagedShortcut.keyCode {
            self.engagedShortcut = nil
            dispatchToMain { interceptor, delegate in
                delegate.cmdTabKeyInterceptorForwardNewWindow(interceptor)
            }
            return .swallow
        }

        // Cycle on repeated presses of the configured key while the required modifiers are held.
        if keyCode == engagedShortcut.keyCode, relevantFlags.contains(engagedShortcut.requiredModifiers) {
            let direction = Self.direction(for: relevantFlags, engagedShortcut: engagedShortcut)
            dispatchToMain { interceptor, delegate in
                delegate.cmdTabKeyInterceptor(interceptor, cycle: direction)
            }
            return .swallow
        }

        // Switch mode when the other CmdTab shortcut key is pressed while engaged.
        for (mode, shortcut) in Self.configuredShortcuts() where mode != engagedShortcut.mode {
            if keyCode == CGKeyCode(shortcut.keyCode), relevantFlags.contains(shortcut.cgEventFlags) {
                self.engagedShortcut = EngagedShortcut(shortcut: shortcut, mode: mode)
                dispatchToMain { interceptor, delegate in
                    delegate.cmdTabKeyInterceptorSwitchMode(interceptor, mode: mode)
                }
                return .swallow
            }
        }

        return .pass
    }

    /// Shift added to a binding that doesn't require it cycles backward.
    private static func direction(for relevantFlags: CGEventFlags, engagedShortcut: EngagedShortcut) -> Direction {
        relevantFlags.contains(.maskShift) && !engagedShortcut.shiftIsRequired ? .previous : .next
    }

    deinit {
        stop()
    }
}
