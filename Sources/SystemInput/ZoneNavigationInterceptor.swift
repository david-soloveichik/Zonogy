/// Intercepts the zone-navigation chord (held modifiers + a selection key) via a global CGEventTap.
///
/// Mirrors `CmdTabKeyInterceptor`: it engages on the chord, swallows the selection keys while held
/// so they don't leak to the focused app, lets each press move the selection, and — because the
/// commit action triggers on modifier release — commits when the modifiers are released. The
/// selection keys are the arrows plus the chosen letter preset (`ZoneNavigationKeysetPreferences`),
/// Return always moves the focused window, and the modifier combination is configurable
/// (`ModifierCombinationPreferences.zoneNavigation`). While engaged, Return asks the delegate to
/// move the focused window into the selected zone, and the Show Launcher shortcut's key (Space by
/// default) asks it to target the selected zone and open the Launcher there — each ending the
/// gesture when the delegate performs it. The Add Zone and Remove Zone shortcuts' keys (= and -
/// by default) ask the delegate to add a zone for the selected zone or remove the selected zone;
/// those keep the gesture engaged so it continues around the new topology.

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

    /// Move key pressed while engaged. The delegate moves the focused window into the selected zone
    /// and returns true — ending the gesture — or returns false to leave it engaged (nothing to
    /// move). Runs synchronously in the event-tap callback, so the decision must stay cheap.
    func zoneNavigationDidPressMoveKey(_ interceptor: ZoneNavigationInterceptor) -> Bool

    /// Show Launcher key pressed while engaged. The delegate targets the selected zone and opens the
    /// Launcher there, returning true — ending the gesture — or returns false to leave it engaged
    /// (nothing selected). Runs synchronously in the event-tap callback, so the decision must stay
    /// cheap.
    func zoneNavigationDidPressShowLauncherKey(_ interceptor: ZoneNavigationInterceptor) -> Bool

    /// Add Zone key pressed while engaged. The delegate adds a zone for the selected zone and
    /// rebuilds the gesture around the new topology; the gesture stays engaged either way.
    func zoneNavigationDidPressAddZoneKey(_ interceptor: ZoneNavigationInterceptor)

    /// Remove Zone key pressed while engaged. The delegate removes the selected tiling zone when
    /// it is removable and rebuilds the gesture around the new topology; the gesture stays
    /// engaged either way.
    func zoneNavigationDidPressRemoveZoneKey(_ interceptor: ZoneNavigationInterceptor)

    /// Required modifiers released — commit the currently selected zone.
    func zoneNavigationDidCommit(_ interceptor: ZoneNavigationInterceptor)

    /// Cancelled (Escape, or events became unavailable) — drop the gesture without committing.
    func zoneNavigationDidCancel(_ interceptor: ZoneNavigationInterceptor)
}

final class ZoneNavigationInterceptor {
    /// The gesture's move key: Return moves the focused window into the selected zone.
    static let moveKeyCode = CGKeyCode(kVK_Return)

    /// The chords the gesture claims under a given modifier combination and keyset (the selection
    /// keys and Return, plus those modifiers). The shortcut editors keep table shortcuts off these,
    /// since the gesture's event tap would swallow them before any hotkey fires.
    static func reservedShortcuts(
        for modifiers: ModifierCombination,
        keyset: ZoneNavigationKeyset
    ) -> [KeyboardShortcut] {
        (Array(keyset.directionKeys.keys) + [moveKeyCode]).map {
            KeyboardShortcut(keyCode: UInt32($0), modifiers: modifiers.carbonModifiers)
        }
    }

    /// Whether `keyCode` is unreachable as a borrowed key under the given keyset: the gesture's
    /// own keys (selection, move, and cancel) act first, as does any key borrowed earlier in the
    /// claim order — Show Launcher, then Add Zone, then Remove Zone. A shortcut whose key is
    /// shadowed can't perform its step mid-gesture — the editor sheet shows it as unavailable.
    static func shadowsBorrowedKey(
        _ keyCode: CGKeyCode,
        keyset: ZoneNavigationKeyset,
        earlierBorrowedKeys: [CGKeyCode] = []
    ) -> Bool {
        keyset.directionKeys[keyCode] != nil || keyCode == moveKeyCode || keyCode == escapeKeyCode
            || earlierBorrowedKeys.contains(keyCode)
    }

    private static let escapeKeyCode = CGKeyCode(kVK_Escape)
    private static let relevantModifierFlags: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]

    weak var delegate: ZoneNavigationInterceptorDelegate?

    private var eventTap: EventTapController?
    private var isEngaged = false
    /// Bumped by external `resetEngagement` (topology cancels, `stop`) so the queued begin
    /// callback of an invalidated engagement recognizes itself as stale: such a cancel can land
    /// on the main queue between the tap thread engaging and the queued begin running, and an
    /// unvalidated begin would then recreate gesture state with no engaged interceptor left to
    /// end it. Normal gesture endings (modifier release, Escape, action keys) deliberately do
    /// not bump: their queued begin must still run so a fast tap-and-release begins and then
    /// commits in FIFO order. Only the begin needs validation — the other queued callbacks are
    /// no-ops against cleared state.
    private var engagementGeneration: UInt64 = 0
    /// The modifiers, selection keys, and Show Launcher key binding captured at engage time, so
    /// mid-gesture edits can't confuse the session.
    private var requiredModifiers: CGEventFlags = []
    private var engagedDirectionKeys: [CGKeyCode: ZoneNavigationDirection] = [:]
    private var engagedLauncherKey: CGKeyCode?
    private var engagedAddZoneKey: CGKeyCode?
    private var engagedRemoveZoneKey: CGKeyCode?
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

    /// External invalidation (topology change, `stop`): disengage and invalidate any queued
    /// begin — the gesture it would start belongs to a snapshot that no longer exists.
    func resetEngagement() {
        engagementGeneration &+= 1
        endEngagement()
    }

    /// Gesture endings on the tap thread (modifier release, Escape, action keys, tap disable):
    /// disengage without invalidating a queued begin, so its state is created and the queued
    /// commit or cancel that follows finds it.
    private func endEngagement() {
        isEngaged = false
        requiredModifiers = []
        engagedDirectionKeys = [:]
        engagedLauncherKey = nil
        engagedAddZoneKey = nil
        engagedRemoveZoneKey = nil
    }

    /// Drop an in-flight gesture and tell the delegate to tear down its overlay. Also drops any
    /// post-action drain: the tap may deliver no further events (disable, suspension), so a kept
    /// drain could go stale and swallow a future chord.
    private func cancelEngagement() {
        drainingKey = nil
        guard isEngaged else { return }
        endEngagement()
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

        // The gesture ends — and the selected zone is committed — when any required modifier is released.
        if !relevantFlags.contains(requiredModifiers) {
            endEngagement()
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
                endEngagement()
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

            // Move the focused window into the selected zone. The delegate decides synchronously
            // whether there is a move to perform; if so, the gesture is over.
            if keyCode == Self.moveKeyCode {
                if delegate?.zoneNavigationDidPressMoveKey(self) == true {
                    drainingKey = (keyCode, requiredModifiers)
                    endEngagement()
                }
                return .swallow
            }

            // Target the selected zone and open the Launcher there. Swallowing also keeps the chord
            // from doubling as the global Show Launcher hotkey.
            if keyCode == engagedLauncherKey {
                if delegate?.zoneNavigationDidPressShowLauncherKey(self) == true {
                    drainingKey = (keyCode, requiredModifiers)
                    endEngagement()
                }
                return .swallow
            }

            // Add or remove a zone for the selected zone; the gesture stays engaged and continues
            // around the new topology. Auto-repeats are swallowed but ignored so a held key cannot
            // cascade topology changes. Swallowing also keeps the chord from doubling as the
            // global Add/Remove Zone hotkey.
            if keyCode == engagedAddZoneKey || keyCode == engagedRemoveZoneKey {
                if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                    let isAdd = keyCode == engagedAddZoneKey
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        if isAdd {
                            self.delegate?.zoneNavigationDidPressAddZoneKey(self)
                        } else {
                            self.delegate?.zoneNavigationDidPressRemoveZoneKey(self)
                        }
                    }
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

        // Fast paths for ordinary typing, checked cheapest-first: the chord requires modifiers
        // (the store guarantees a valid combination), and they must match exactly, before the
        // selection keys are even consulted.
        guard !relevantFlags.isEmpty,
              relevantFlags == ModifierCombinationPreferences.zoneNavigation.modifiers.cgEventFlags else {
            return .pass
        }

        let directionKeys = ZoneNavigationKeysetPreferences.shared.keyset.directionKeys
        guard let direction = directionKeys[keyCode],
              delegate?.zoneNavigationShouldBegin(self) == true else {
            return .pass
        }

        // Engage immediately so repeated presses are swallowed even though the UI work is async.
        // The Launcher, Add Zone, and Remove Zone keys are borrowed from those shortcuts — only
        // their key codes matter, since the gesture's modifiers are already held.
        isEngaged = true
        requiredModifiers = relevantFlags
        engagedDirectionKeys = directionKeys
        let shortcutPreferences = KeyboardShortcutPreferences.shared
        engagedLauncherKey = shortcutPreferences.shortcut(for: .showLauncher)
            .map { CGKeyCode($0.keyCode) }
        engagedAddZoneKey = shortcutPreferences.shortcut(for: .addZone)
            .map { CGKeyCode($0.keyCode) }
        engagedRemoveZoneKey = shortcutPreferences.shortcut(for: .removeZone)
            .map { CGKeyCode($0.keyCode) }

        let generation = engagementGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, self.engagementGeneration == generation else { return }
            self.delegate?.zoneNavigation(self, didBegin: direction)
        }
        return .swallow
    }

    deinit {
        stop()
    }
}
