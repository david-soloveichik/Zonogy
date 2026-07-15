/// Intercepts the Control-Command + arrow-key window-focus chord via a global CGEventTap.
///
/// Mirrors `CmdTabKeyInterceptor`: it engages on the chord, swallows the arrow keys while held so
/// they don't leak to the focused app, lets each arrow press move the selection, and — because the
/// focus action triggers on modifier release — commits when the shared modifier is released. The
/// four direction shortcuts therefore share one modifier combination (enforced in
/// `KeyboardShortcutPreferences`); a per-direction modifier could never be detected on release.

import ApplicationServices
import Carbon
import Foundation

protocol WindowFocusNavigationInterceptorDelegate: AnyObject {
    /// Return false to ignore events entirely (e.g., while recording a shortcut or sleep/wake protection is active).
    func windowFocusNavigationShouldHandleEvents(_ interceptor: WindowFocusNavigationInterceptor) -> Bool

    /// Return false to decline starting a gesture (e.g., a chooser is open); the chord then passes through.
    func windowFocusNavigationShouldBegin(_ interceptor: WindowFocusNavigationInterceptor) -> Bool

    /// Begin a gesture from the given direction (resolve the initial selection, show the dot).
    func windowFocusNavigation(_ interceptor: WindowFocusNavigationInterceptor, didBegin direction: ZoneNavigationDirection)

    /// Move the selection one step in the given direction.
    func windowFocusNavigation(_ interceptor: WindowFocusNavigationInterceptor, didMove direction: ZoneNavigationDirection)

    /// Required modifiers released — focus the currently marked window.
    func windowFocusNavigationDidCommit(_ interceptor: WindowFocusNavigationInterceptor)

    /// Cancelled (Escape, or events became unavailable) — drop the gesture without focusing.
    func windowFocusNavigationDidCancel(_ interceptor: WindowFocusNavigationInterceptor)
}

final class WindowFocusNavigationInterceptor {
    /// The four configurable direction actions, paired with the direction each represents.
    private static let directionActions: [(action: KeyboardShortcutPreferences.ShortcutAction, direction: ZoneNavigationDirection)] = [
        (.focusWindowUp, .up),
        (.focusWindowDown, .down),
        (.focusWindowLeft, .left),
        (.focusWindowRight, .right),
    ]
    private static let escapeKeyCode = CGKeyCode(kVK_Escape)
    private static let relevantModifierFlags: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]

    weak var delegate: WindowFocusNavigationInterceptorDelegate?

    private var eventTap: EventTapController?
    private var isEngaged = false
    private var requiredModifiers: CGEventFlags = []
    /// The direction-key bindings captured at engage time, so mid-gesture rebinds can't confuse it.
    private var engagedDirectionKeys: [CGKeyCode: ZoneNavigationDirection] = [:]

    func start(delegate: WindowFocusNavigationInterceptorDelegate) {
        self.delegate = delegate

        guard eventTap == nil else {
            Logger.debug("WindowFocusNavigationInterceptor already running")
            return
        }

        let tap = EventTapController(
            name: "Window-focus navigation interceptor",
            events: [.keyDown, .flagsChanged],
            onDisabled: { [weak self] _ in self?.cancelEngagement() },
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
        resetEngagement()
    }

    func resetEngagement() {
        isEngaged = false
        requiredModifiers = []
        engagedDirectionKeys = [:]
    }

    /// Drop an in-flight gesture and tell the delegate to tear down its overlay.
    private func cancelEngagement() {
        guard isEngaged else { return }
        resetEngagement()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.windowFocusNavigationDidCancel(self)
        }
    }

    private func processEvent(_ event: CGEvent, type: CGEventType) -> EventTapDecision {
        guard let delegate, delegate.windowFocusNavigationShouldHandleEvents(self) else {
            cancelEngagement()
            return .pass
        }

        let relevantFlags = event.flags.intersection(Self.relevantModifierFlags)

        switch type {
        case .flagsChanged:
            return handleFlagsChanged(relevantFlags: relevantFlags)
        case .keyDown:
            return handleKeyDown(event: event, relevantFlags: relevantFlags)
        default:
            return .pass
        }
    }

    private func handleFlagsChanged(relevantFlags: CGEventFlags) -> EventTapDecision {
        guard isEngaged else {
            return .pass
        }

        // The gesture ends — and the marked window is focused — when any required modifier is released.
        if !relevantFlags.contains(requiredModifiers) {
            resetEngagement()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.windowFocusNavigationDidCommit(self)
            }
        }
        return .pass
    }

    private func handleKeyDown(event: CGEvent, relevantFlags: CGEventFlags) -> EventTapDecision {
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))

        if isEngaged {
            // Cancel without focusing.
            if keyCode == Self.escapeKeyCode {
                resetEngagement()
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.delegate?.windowFocusNavigationDidCancel(self)
                }
                return .swallow
            }

            // Move the selection on a direction key (while the required modifiers are still held).
            if let direction = engagedDirectionKeys[keyCode], relevantFlags.contains(requiredModifiers) {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.delegate?.windowFocusNavigation(self, didMove: direction)
                }
                return .swallow
            }

            // Any other key passes through; the gesture still ends on modifier release.
            return .pass
        }

        // Fast path for ordinary typing: every chord requires a modifier, so a modifier-free key
        // can't start a gesture and needn't consult preferences.
        guard !relevantFlags.isEmpty else {
            return .pass
        }

        guard let match = matchingChord(keyCode: keyCode, relevantFlags: relevantFlags),
              delegate?.windowFocusNavigationShouldBegin(self) == true else {
            return .pass
        }

        // Engage immediately so repeated presses are swallowed even though the UI work is async.
        isEngaged = true
        requiredModifiers = match.modifiers
        engagedDirectionKeys = match.directionKeys

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.windowFocusNavigation(self, didBegin: match.direction)
        }
        return .swallow
    }

    private struct ChordMatch {
        let direction: ZoneNavigationDirection
        let modifiers: CGEventFlags
        let directionKeys: [CGKeyCode: ZoneNavigationDirection]
    }

    /// Resolve the current direction bindings and, if `keyCode`+`relevantFlags` exactly matches one,
    /// return the match (along with every direction's key, captured for the engaged session).
    private func matchingChord(keyCode: CGKeyCode, relevantFlags: CGEventFlags) -> ChordMatch? {
        let preferences = KeyboardShortcutPreferences.shared
        var directionKeys: [CGKeyCode: ZoneNavigationDirection] = [:]
        var matched: (direction: ZoneNavigationDirection, modifiers: CGEventFlags)?

        for (action, direction) in Self.directionActions {
            guard let shortcut = preferences.shortcut(for: action) else { continue }
            let modifiers = shortcut.cgEventFlags
            // A modifier is required: without one we could never detect "release to focus".
            guard !modifiers.isEmpty else { continue }

            let code = CGKeyCode(shortcut.keyCode)
            directionKeys[code] = direction
            if code == keyCode, relevantFlags == modifiers {
                matched = (direction, modifiers)
            }
        }

        guard let matched else { return nil }
        return ChordMatch(direction: matched.direction, modifiers: matched.modifiers, directionKeys: directionKeys)
    }

    deinit {
        stop()
    }
}
