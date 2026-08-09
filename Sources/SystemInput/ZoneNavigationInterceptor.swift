/// Intercepts the Control-Command + arrow-key zone-navigation chord via a global CGEventTap.
///
/// Mirrors `CmdTabKeyInterceptor`: it engages on the chord, swallows the arrow keys while held so
/// they don't leak to the focused app, lets each arrow press move the selection, and — because the
/// commit action triggers on modifier release — commits when the shared modifier is released. The
/// four direction shortcuts (and the move key) therefore share one modifier combination (enforced
/// in `KeyboardShortcutPreferences`); a per-direction modifier could never be detected on release.
/// While engaged, the configurable move key (default Return) asks the delegate to move the focused
/// window into the marked zone, and the Show Launcher shortcut's key (Space by default) asks it to
/// target the marked zone and open the Launcher there — each ending the gesture when the delegate
/// performs it.

import ApplicationServices
import Carbon
import Foundation

protocol ZoneNavigationInterceptorDelegate: AnyObject {
    /// Return false to ignore events entirely (e.g., while recording a shortcut or sleep/wake protection is active).
    func zoneNavigationShouldHandleEvents(_ interceptor: ZoneNavigationInterceptor) -> Bool

    /// Return false to decline starting a gesture (e.g., a chooser is open); the chord then passes through.
    func zoneNavigationShouldBegin(_ interceptor: ZoneNavigationInterceptor) -> Bool

    /// Begin a gesture from the given direction (resolve the initial selection, show the circle).
    func zoneNavigation(_ interceptor: ZoneNavigationInterceptor, didBegin direction: ZoneNavigationDirection)

    /// Move the selection one step in the given direction.
    func zoneNavigation(_ interceptor: ZoneNavigationInterceptor, didMove direction: ZoneNavigationDirection)

    /// Move key pressed while engaged. The delegate moves the focused window into the marked zone
    /// and returns true — ending the gesture — or returns false to leave it engaged (nothing to
    /// move). Runs synchronously in the event-tap callback, so the decision must stay cheap.
    func zoneNavigationDidPressMoveKey(_ interceptor: ZoneNavigationInterceptor) -> Bool

    /// Show Launcher key pressed while engaged. The delegate targets the marked zone and opens the
    /// Launcher there, returning true — ending the gesture — or returns false to leave it engaged
    /// (nothing marked). Runs synchronously in the event-tap callback, so the decision must stay
    /// cheap.
    func zoneNavigationDidPressShowLauncherKey(_ interceptor: ZoneNavigationInterceptor) -> Bool

    /// Required modifiers released — commit the currently marked zone.
    func zoneNavigationDidCommit(_ interceptor: ZoneNavigationInterceptor)

    /// Cancelled (Escape, or events became unavailable) — drop the gesture without committing.
    func zoneNavigationDidCancel(_ interceptor: ZoneNavigationInterceptor)
}

final class ZoneNavigationInterceptor {
    /// The four configurable direction actions, paired with the direction each represents.
    private static let directionActions: [(action: KeyboardShortcutPreferences.ShortcutAction, direction: ZoneNavigationDirection)] = [
        (.selectZoneUp, .up),
        (.selectZoneDown, .down),
        (.selectZoneLeft, .left),
        (.selectZoneRight, .right),
    ]
    private static let escapeKeyCode = CGKeyCode(kVK_Escape)
    private static let relevantModifierFlags: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]

    weak var delegate: ZoneNavigationInterceptorDelegate?

    private var eventTap: EventTapController?
    private var isEngaged = false
    private var requiredModifiers: CGEventFlags = []
    /// The direction- and move-key bindings captured at engage time, so mid-gesture rebinds can't
    /// confuse it.
    private var engagedDirectionKeys: [CGKeyCode: ZoneNavigationDirection] = [:]
    private var engagedMoveKey: CGKeyCode?
    private var engagedLauncherKey: CGKeyCode?
    /// After an action key (move or Launcher) ends the gesture, its auto-repeats are swallowed
    /// until the chord's modifiers are released — otherwise a slightly-long press leaks repeats
    /// into the focused app, or re-fires the global Show Launcher hotkey right after it opened.
    private var drainingKey: (keyCode: CGKeyCode, modifiers: CGEventFlags)?

    func start(delegate: ZoneNavigationInterceptorDelegate) {
        self.delegate = delegate

        guard eventTap == nil else {
            Logger.debug("ZoneNavigationInterceptor already running")
            return
        }

        let tap = EventTapController(
            name: "Zone navigation interceptor",
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
        drainingKey = nil
    }

    func resetEngagement() {
        isEngaged = false
        requiredModifiers = []
        engagedDirectionKeys = [:]
        engagedMoveKey = nil
        engagedLauncherKey = nil
    }

    /// Drop an in-flight gesture and tell the delegate to tear down its overlay. Also drops any
    /// post-action drain: the tap may deliver no further events (disable, suspension), so a kept
    /// drain could go stale and swallow a future chord.
    private func cancelEngagement() {
        drainingKey = nil
        guard isEngaged else { return }
        resetEngagement()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.zoneNavigationDidCancel(self)
        }
    }

    private func processEvent(_ event: CGEvent, type: CGEventType) -> EventTapDecision {
        let relevantFlags = event.flags.intersection(Self.relevantModifierFlags)

        // Drain hygiene runs before everything else — including the handler-availability guard and
        // independent of engagement — so the drain ends exactly when its chord's modifiers do, and
        // a stale drain can't survive an engaged commit, a partial release, or suspension to
        // swallow a future chord.
        if type == .flagsChanged, let draining = drainingKey, !relevantFlags.contains(draining.modifiers) {
            drainingKey = nil
        }

        guard let delegate, delegate.zoneNavigationShouldHandleEvents(self) else {
            cancelEngagement()
            return .pass
        }

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

        // The gesture ends — and the marked zone is committed — when any required modifier is released.
        if !relevantFlags.contains(requiredModifiers) {
            resetEngagement()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.zoneNavigationDidCommit(self)
            }
        }
        return .pass
    }

    private func handleKeyDown(event: CGEvent, relevantFlags: CGEventFlags) -> EventTapDecision {
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))

        if isEngaged {
            // Cancel without committing.
            if keyCode == Self.escapeKeyCode {
                resetEngagement()
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.delegate?.zoneNavigationDidCancel(self)
                }
                return .swallow
            }

            guard relevantFlags.contains(requiredModifiers) else {
                // Any other key passes through; the gesture still ends on modifier release.
                return .pass
            }

            // Move the selection on a direction key (while the required modifiers are still held).
            if let direction = engagedDirectionKeys[keyCode] {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.delegate?.zoneNavigation(self, didMove: direction)
                }
                return .swallow
            }

            // Move the focused window into the marked zone. The delegate decides synchronously
            // whether there is a move to perform; if so, the gesture is over.
            if keyCode == engagedMoveKey {
                if delegate?.zoneNavigationDidPressMoveKey(self) == true {
                    drainingKey = (keyCode, requiredModifiers)
                    resetEngagement()
                }
                return .swallow
            }

            // Target the marked zone and open the Launcher there. Swallowing also keeps the chord
            // from doubling as the global Show Launcher hotkey.
            if keyCode == engagedLauncherKey {
                if delegate?.zoneNavigationDidPressShowLauncherKey(self) == true {
                    drainingKey = (keyCode, requiredModifiers)
                    resetEngagement()
                }
                return .swallow
            }

            return .pass
        }

        // Swallow auto-repeats of the action key that just ended a gesture (until the modifiers
        // are released; see `drainingKey`).
        if let draining = drainingKey, keyCode == draining.keyCode, relevantFlags.contains(draining.modifiers) {
            return .swallow
        }

        // Fast path for ordinary typing: every chord requires a modifier, so a modifier-free key
        // can't start a gesture and needn't consult preferences.
        guard !relevantFlags.isEmpty else {
            return .pass
        }

        guard let match = matchingChord(keyCode: keyCode, relevantFlags: relevantFlags),
              delegate?.zoneNavigationShouldBegin(self) == true else {
            return .pass
        }

        // Engage immediately so repeated presses are swallowed even though the UI work is async.
        isEngaged = true
        requiredModifiers = match.modifiers
        engagedDirectionKeys = match.directionKeys
        engagedMoveKey = match.moveKey
        engagedLauncherKey = match.launcherKey

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.zoneNavigation(self, didBegin: match.direction)
        }
        return .swallow
    }

    private struct ChordMatch {
        let direction: ZoneNavigationDirection
        let modifiers: CGEventFlags
        let directionKeys: [CGKeyCode: ZoneNavigationDirection]
        let moveKey: CGKeyCode?
        let launcherKey: CGKeyCode?
    }

    /// Resolve the current direction bindings and, if `keyCode`+`relevantFlags` exactly matches one,
    /// return the match (along with every direction's key, the move key, and the Show Launcher key,
    /// captured for the engaged session).
    private func matchingChord(keyCode: CGKeyCode, relevantFlags: CGEventFlags) -> ChordMatch? {
        let preferences = KeyboardShortcutPreferences.shared
        var directionKeys: [CGKeyCode: ZoneNavigationDirection] = [:]
        var matched: (direction: ZoneNavigationDirection, modifiers: CGEventFlags)?

        for (action, direction) in Self.directionActions {
            guard let shortcut = preferences.shortcut(for: action) else { continue }
            let modifiers = shortcut.cgEventFlags
            // A modifier is required: without one we could never detect "release to commit".
            guard !modifiers.isEmpty else { continue }

            let code = CGKeyCode(shortcut.keyCode)
            directionKeys[code] = direction
            if code == keyCode, relevantFlags == modifiers {
                matched = (direction, modifiers)
            }
        }

        guard let matched else { return nil }
        // The move key shares the gesture's modifier group, and the Launcher key is borrowed from
        // the Show Launcher shortcut — in both cases only the key code matters here, since the
        // gesture's modifiers are already held.
        let moveKey = preferences.shortcut(for: .moveWindowToSelectedZone).map { CGKeyCode($0.keyCode) }
        let launcherKey = preferences.shortcut(for: .showLauncher).map { CGKeyCode($0.keyCode) }
        return ChordMatch(
            direction: matched.direction,
            modifiers: matched.modifiers,
            directionKeys: directionKeys,
            moveKey: moveKey,
            launcherKey: launcherKey
        )
    }

    deinit {
        stop()
    }
}
