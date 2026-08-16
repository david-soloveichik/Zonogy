/// Intercepts the configured CmdTab keyboard chord via a global CGEventTap (Input Monitoring)

import ApplicationServices
import Carbon
import Foundation

/// Mode for CmdTab window filtering
enum CmdTabMode {
    case allWindows
    case currentAppOnly
}

protocol CmdTabKeyInterceptorDelegate: AnyObject {
    /// Return true when CmdTab UI is currently visible.
    func cmdTabKeyInterceptorIsCmdTabVisible(_ interceptor: CmdTabKeyInterceptor) -> Bool

    /// Request that CmdTab be shown. Return true if it was shown.
    func cmdTabKeyInterceptorShowCmdTab(_ interceptor: CmdTabKeyInterceptor, initialDirection: CmdTabKeyInterceptor.Direction, mode: CmdTabMode) -> Bool

    /// Cycle CmdTab selection in the given direction (only called while CmdTab is visible).
    func cmdTabKeyInterceptor(_ interceptor: CmdTabKeyInterceptor, cycle direction: CmdTabKeyInterceptor.Direction)

    /// Activate the currently selected CmdTab window (called on modifier release).
    func cmdTabKeyInterceptorActivateSelection(_ interceptor: CmdTabKeyInterceptor)

    /// Switch CmdTab to a different mode while it is already visible (e.g., all-windows ↔ current-app).
    func cmdTabKeyInterceptorSwitchMode(_ interceptor: CmdTabKeyInterceptor, mode: CmdTabMode)

    /// Cancel CmdTab without activation.
    func cmdTabKeyInterceptorCancel(_ interceptor: CmdTabKeyInterceptor)

    /// Forward a "new window" request (Cmd-N) to the current app, then dismiss CmdTab.
    func cmdTabKeyInterceptorForwardNewWindow(_ interceptor: CmdTabKeyInterceptor)

    /// Return false to temporarily disable CmdTab interception (e.g., while recording shortcuts).
    func cmdTabKeyInterceptorShouldHandleEvents(_ interceptor: CmdTabKeyInterceptor) -> Bool
}

final class CmdTabKeyInterceptor {
    enum Direction {
        case next
        case previous
    }

    private enum Constants {
        static let relevantModifierFlags: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
        static let escapeKeyCode = CGKeyCode(kVK_Escape)
        static let nKeyCode = CGKeyCode(kVK_ANSI_N)
    }

    weak var delegate: CmdTabKeyInterceptorDelegate?

    private var eventTap: EventTapController?

    private var isEngaged = false
    private var engagedShortcut: EngagedShortcut?

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

    /// The configured CmdTab bindings with the mode each opens: all windows, then current app only.
    private static func configuredShortcuts() -> [(mode: CmdTabMode, shortcut: KeyboardShortcut)] {
        let preferences = KeyboardShortcutPreferences.shared
        let bindings: [(mode: CmdTabMode, action: KeyboardShortcutPreferences.ShortcutAction)] = [
            (.allWindows, .showCmdTab), (.currentAppOnly, .showCmdTabCurrentApp),
        ]
        return bindings.compactMap { binding in
            preferences.shortcut(for: binding.action).map { (mode: binding.mode, shortcut: $0) }
        }
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
        isEngaged = false
        engagedShortcut = nil
    }

    func resetEngagement() {
        isEngaged = false
        engagedShortcut = nil
    }

    private func processEvent(_ event: CGEvent, type: CGEventType) -> EventTapDecision {
        switch type {
        case .keyDown, .flagsChanged:
            break
        default:
            return .pass
        }

        guard let delegate, delegate.cmdTabKeyInterceptorShouldHandleEvents(self) else {
            return .pass
        }

        let relevantFlags = event.flags.intersection(Constants.relevantModifierFlags)

        if type == .flagsChanged {
            return handleFlagsChanged(event: event, relevantFlags: relevantFlags)
        }

        return handleKeyDown(event: event, relevantFlags: relevantFlags)
    }

    private func handleFlagsChanged(event: CGEvent, relevantFlags: CGEventFlags) -> EventTapDecision {
        guard isEngaged, let engagedShortcut else {
            return .pass
        }

        // Session ends when any required modifier is released.
        guard relevantFlags.contains(engagedShortcut.requiredModifiers) else {
            if delegate?.cmdTabKeyInterceptorIsCmdTabVisible(self) == true {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.delegate?.cmdTabKeyInterceptorActivateSelection(self)
                }
            }

            isEngaged = false
            self.engagedShortcut = nil
            return .pass
        }

        return .pass
    }

    private func handleKeyDown(event: CGEvent, relevantFlags: CGEventFlags) -> EventTapDecision {
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))

        if isEngaged {
            return handleKeyDownWhileEngaged(keyCode: keyCode, relevantFlags: relevantFlags, event: event)
        }

        // Engage on either CmdTab binding — or its Shift variant, when the binding leaves Shift free
        // for reverse cycling (`claimedShortcuts`).
        var matchedShortcut: EngagedShortcut?
        for (mode, shortcut) in Self.configuredShortcuts() {
            if keyCode == CGKeyCode(shortcut.keyCode),
               Self.claimedShortcuts(for: shortcut).contains(where: { $0.cgEventFlags == relevantFlags }) {
                matchedShortcut = EngagedShortcut(shortcut: shortcut, mode: mode)
                break
            }
        }

        guard let shortcut = matchedShortcut else {
            return .pass
        }

        // Begin session immediately so repeated key presses are swallowed even if UI work is async.
        isEngaged = true
        engagedShortcut = shortcut

        let direction = initialDirection(for: relevantFlags, engagedShortcut: shortcut)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            _ = self.delegate?.cmdTabKeyInterceptorShowCmdTab(self, initialDirection: direction, mode: shortcut.mode)
        }

        // Swallow to override the system app switcher.
        return .swallow
    }

    private func handleKeyDownWhileEngaged(keyCode: CGKeyCode, relevantFlags: CGEventFlags, event: CGEvent) -> EventTapDecision {
        guard let engagedShortcut else {
            // Shouldn't happen, but don't get stuck in an engaged state.
            isEngaged = false
            return .pass
        }

        // Cancel (even while modifiers are held).
        if keyCode == Constants.escapeKeyCode, delegate?.cmdTabKeyInterceptorIsCmdTabVisible(self) == true {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.cmdTabKeyInterceptorCancel(self)
            }
            isEngaged = false
            self.engagedShortcut = nil
            return .swallow
        }

        // Forward a "new window" request (Cmd-N) to the current app, then dismiss. The chord's
        // modifier (Command, by default) is still held, so pressing N alone is already Cmd-N.
        // Like the cycle key below, swallow N for the whole engaged session — even in the brief
        // gap before the async show makes the UI visible — so the keystroke can't leak to the app
        // and double-fire. Engagement is reset only once we actually forward (when visible).
        if keyCode == Constants.nKeyCode, keyCode != engagedShortcut.keyCode {
            if delegate?.cmdTabKeyInterceptorIsCmdTabVisible(self) == true {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.delegate?.cmdTabKeyInterceptorForwardNewWindow(self)
                }
                isEngaged = false
                self.engagedShortcut = nil
            }
            return .swallow
        }

        // Cycle on repeated presses of the configured key while the required modifiers are held.
        if keyCode == engagedShortcut.keyCode, relevantFlags.contains(engagedShortcut.requiredModifiers) {
            if delegate?.cmdTabKeyInterceptorIsCmdTabVisible(self) == true {
                let direction = cyclingDirection(for: relevantFlags, engagedShortcut: engagedShortcut)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.delegate?.cmdTabKeyInterceptor(self, cycle: direction)
                }
            }
            return .swallow
        }

        // Switch mode when the other CmdTab shortcut key is pressed while engaged.
        if delegate?.cmdTabKeyInterceptorIsCmdTabVisible(self) == true {
            for (mode, shortcut) in Self.configuredShortcuts() where mode != engagedShortcut.mode {
                if keyCode == CGKeyCode(shortcut.keyCode), relevantFlags.contains(shortcut.cgEventFlags) {
                    self.engagedShortcut = EngagedShortcut(shortcut: shortcut, mode: mode)
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.delegate?.cmdTabKeyInterceptorSwitchMode(self, mode: mode)
                    }
                    return .swallow
                }
            }
        }

        return .pass
    }

    private func initialDirection(for relevantFlags: CGEventFlags, engagedShortcut: EngagedShortcut) -> Direction {
        let shiftPressed = relevantFlags.contains(.maskShift)
        if shiftPressed && !engagedShortcut.shiftIsRequired {
            return .previous
        }
        return .next
    }

    private func cyclingDirection(for relevantFlags: CGEventFlags, engagedShortcut: EngagedShortcut) -> Direction {
        let shiftPressed = relevantFlags.contains(.maskShift)
        if shiftPressed && !engagedShortcut.shiftIsRequired {
            return .previous
        }
        return .next
    }

    deinit {
        stop()
    }
}
