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

    struct EngagedShortcut {
        let keyCode: CGKeyCode
        let requiredModifiers: CGEventFlags
        let shiftIsRequired: Bool
        let mode: CmdTabMode
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

        // Try both CmdTab shortcuts (all windows and current app only)
        let shortcuts: [(CmdTabMode, ShortcutInfo?)] = [
            (.allWindows, currentCmdTabShortcut()),
            (.currentAppOnly, currentCmdTabCurrentAppShortcut())
        ]

        var matchedShortcut: EngagedShortcut?
        for (mode, shortcut) in shortcuts {
            guard let shortcut else { continue }
            if keyCode == shortcut.keyCode && shortcutMatches(relevantFlags: relevantFlags, shortcut: shortcut) {
                matchedShortcut = EngagedShortcut(
                    keyCode: shortcut.keyCode,
                    requiredModifiers: shortcut.requiredModifiers,
                    shiftIsRequired: shortcut.shiftIsRequired,
                    mode: mode
                )
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
            let otherShortcuts: [(CmdTabMode, ShortcutInfo?)] = [
                (.allWindows, currentCmdTabShortcut()),
                (.currentAppOnly, currentCmdTabCurrentAppShortcut())
            ]

            for (mode, shortcut) in otherShortcuts {
                guard let shortcut, mode != engagedShortcut.mode else { continue }
                if keyCode == shortcut.keyCode, relevantFlags.contains(shortcut.requiredModifiers) {
                    self.engagedShortcut = EngagedShortcut(
                        keyCode: shortcut.keyCode,
                        requiredModifiers: shortcut.requiredModifiers,
                        shiftIsRequired: shortcut.shiftIsRequired,
                        mode: mode
                    )
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

    private struct ShortcutInfo {
        let keyCode: CGKeyCode
        let requiredModifiers: CGEventFlags
        let shiftIsRequired: Bool
    }

    private func currentCmdTabShortcut() -> ShortcutInfo? {
        guard let shortcut = KeyboardShortcutPreferences.shared.shortcut(for: .showCmdTab) else {
            return nil
        }

        let requiredModifiers = shortcut.cgEventFlags
        let shiftIsRequired = requiredModifiers.contains(.maskShift)

        return ShortcutInfo(
            keyCode: CGKeyCode(shortcut.keyCode),
            requiredModifiers: requiredModifiers,
            shiftIsRequired: shiftIsRequired
        )
    }

    private func currentCmdTabCurrentAppShortcut() -> ShortcutInfo? {
        guard let shortcut = KeyboardShortcutPreferences.shared.shortcut(for: .showCmdTabCurrentApp) else {
            return nil
        }

        let requiredModifiers = shortcut.cgEventFlags
        let shiftIsRequired = requiredModifiers.contains(.maskShift)

        return ShortcutInfo(
            keyCode: CGKeyCode(shortcut.keyCode),
            requiredModifiers: requiredModifiers,
            shiftIsRequired: shiftIsRequired
        )
    }

    private func shortcutMatches(relevantFlags: CGEventFlags, shortcut: ShortcutInfo) -> Bool {
        guard relevantFlags.contains(shortcut.requiredModifiers) else {
            return false
        }

        // Allow Shift as an extra modifier for reverse cycling when Shift is not part of the configured shortcut.
        let allowedExtras: CGEventFlags = shortcut.shiftIsRequired ? [] : [.maskShift]
        let allowedFlags = shortcut.requiredModifiers.union(allowedExtras)
        let disallowed = relevantFlags.subtracting(allowedFlags)
        return disallowed.isEmpty
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
