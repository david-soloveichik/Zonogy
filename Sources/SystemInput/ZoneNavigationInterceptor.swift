/// Intercepts the zone-navigation chord (held modifiers + a selection key) via a global CGEventTap.
///
/// Mirrors `CmdTabKeyInterceptor`: it engages on the chord, swallows the selection keys while held
/// so they don't leak to the focused app, lets each press step or jump the selection, and —
/// because the commit action triggers on modifier release — commits when the modifiers are
/// released. The selection keys and which groups are on come from `ZoneNavigationKeyPreferences`
/// (the arrows step, the jump keys jump; a group turned off has no selection meaning, even
/// mid-gesture), and the modifier combination is configurable
/// (`ModifierCombinationPreferences.zoneNavigation`). The in-gesture action keys are borrowed
/// from shortcuts: while engaged, the Move Focused Window to Destination shortcut's key (Return by
/// default) asks the delegate to move the focused window into the selected zone, and the Show
/// Launcher shortcut's key (Space by default) asks it to target the selected zone and open the
/// Launcher there — each ending the gesture. The Add Zone and Remove
/// Zone shortcuts' keys (= and - by default) ask the delegate to add a zone for the selected zone
/// or remove the selected zone, and the Minimize Focused Window shortcut's key (M by default) asks
/// it to minimize the selected zone's window (or remove an empty tiling zone); those keep the
/// gesture engaged so it continues around the result.
///
/// The tap is serviced by `EventTapThread`, so its callback answers while the main thread is busy
/// and never holds up keystrokes bound for other apps. The callback decides only what a keystroke
/// means for the gesture and hands every action to the main queue, in keystroke order. The
/// main-thread facts it consults are pushed in (`isSuspended`, `canBegin`), and because the
/// delegate also ends or drops gestures from the main thread (`endEngagement`,
/// `resetEngagement`), the gesture state is guarded by a lock.

import ApplicationServices
import Carbon
import Foundation

/// Every call arrives on the main queue in keystroke order; a call for a gesture that is already
/// gone is a no-op there.
protocol ZoneNavigationInterceptorDelegate: AnyObject {
    /// Begin a gesture from the given selection key (resolve the initial selection, show the
    /// circle). `engagement` names the gesture to `endEngagement`.
    func zoneNavigation(_ interceptor: ZoneNavigationInterceptor, didBegin key: ZoneNavigationKey, engagement: ZoneNavigationInterceptor.Engagement)

    /// A further selection key while engaged: step or jump the selection.
    func zoneNavigation(_ interceptor: ZoneNavigationInterceptor, didPress key: ZoneNavigationKey)

    /// Move key pressed while engaged; the gesture has ended. The delegate moves the focused window
    /// into the selected zone when there is one to move.
    func zoneNavigationDidPressMoveKey(_ interceptor: ZoneNavigationInterceptor)

    /// Show Launcher key pressed while engaged; the gesture has ended. The delegate targets the
    /// selected zone and opens the Launcher there.
    func zoneNavigationDidPressShowLauncherKey(_ interceptor: ZoneNavigationInterceptor)

    /// Add Zone key pressed while engaged. The delegate adds a zone for the selected zone and
    /// rebuilds the gesture around the new topology; the gesture stays engaged either way.
    func zoneNavigationDidPressAddZoneKey(_ interceptor: ZoneNavigationInterceptor)

    /// Remove Zone key pressed while engaged. The delegate removes the selected tiling zone when
    /// it is removable and rebuilds the gesture around the new topology; the gesture stays
    /// engaged either way.
    func zoneNavigationDidPressRemoveZoneKey(_ interceptor: ZoneNavigationInterceptor)

    /// Minimize key pressed while engaged. The delegate minimizes the selected zone's window —
    /// or, when the zone is an empty tiling zone, removes it (the Remove Zone behavior) — and
    /// the gesture stays engaged either way.
    func zoneNavigationDidPressMinimizeKey(_ interceptor: ZoneNavigationInterceptor)

    /// Required modifiers released — commit the currently selected zone.
    func zoneNavigationDidCommit(_ interceptor: ZoneNavigationInterceptor)

    /// Cancelled (Escape, or events became unavailable) — drop the gesture without committing.
    func zoneNavigationDidCancel(_ interceptor: ZoneNavigationInterceptor)
}

final class ZoneNavigationInterceptor {
    /// Names one engaged gesture, so an ending decided on the main thread (its begin was refused or
    /// resolved nothing, its own topology change left nothing to select) applies to that gesture
    /// and not to one engaged since.
    struct Engagement: Equatable {
        fileprivate let id: UInt64
    }

    /// The chords the gesture claims under a given modifier combination and keys (the enabled
    /// selection keys under those modifiers; nothing when no group is enabled, since the gesture
    /// then never engages). A table shortcut on one of these is shown as a conflict in Preferences
    /// (see `ShortcutConflicts`): the event tap swallows a selection chord whenever the gesture can
    /// engage, before any hotkey fires. The borrowed action keys are not claimed: they are those
    /// shortcuts' own chords, swallowed only once the gesture is engaged.
    static func claimedShortcuts(
        for modifiers: ModifierCombination,
        keys: ZoneNavigationKeys
    ) -> [KeyboardShortcut] {
        keys.selectionKeys.keys.map {
            KeyboardShortcut(keyCode: UInt32($0), modifiers: modifiers.carbonModifiers)
        }
    }

    /// Whether `keyCode` is unreachable as a borrowed key under the given keys: the gesture's own
    /// keys (selection and cancel) act first, as does any key borrowed earlier in the claim order —
    /// Move Focused Window to Destination, then Show Launcher, then Add Zone, then Remove Zone,
    /// then Minimize Focused Window. A shortcut whose key is shadowed can't perform its step
    /// mid-gesture — the editor sheet shows it as unavailable.
    static func shadowsBorrowedKey(
        _ keyCode: CGKeyCode,
        keys: ZoneNavigationKeys,
        earlierBorrowedKeys: [CGKeyCode] = []
    ) -> Bool {
        keys.selectionKeys[keyCode] != nil || keyCode == escapeKeyCode || earlierBorrowedKeys.contains(keyCode)
    }

    private static let escapeKeyCode = CGKeyCode(kVK_Escape)
    private static let relevantModifierFlags: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]

    weak var delegate: ZoneNavigationInterceptorDelegate?

    private var eventTap: EventTapController?

    /// Guards the gesture state below: the tap callback works on the tap thread; the gates, the
    /// resets, `endEngagement`, and `stop` run on the main thread. Entry points take the lock; the
    /// private handlers assume it is held.
    private let lock = NSLock()
    private var suspended = false
    private var canBeginGesture = false
    private var isEngaged = false
    /// The current gesture, or the most recent one once it has ended.
    private var engagement = Engagement(id: 0)
    /// Bumped by external `resetEngagement` (topology cancels, `stop`) so the queued begin
    /// callback of an invalidated engagement recognizes itself as stale: such a cancel can land
    /// on the main queue between the tap thread engaging and the queued begin running, and an
    /// unvalidated begin would then recreate gesture state with no engaged interceptor left to
    /// end it. Normal gesture endings (modifier release, Escape, action keys) deliberately do
    /// not bump: their queued begin must still run so a fast tap-and-release begins and then
    /// commits in FIFO order. Only the begin needs validation — the other queued callbacks are
    /// no-ops against cleared state.
    private var engagementGeneration: UInt64 = 0
    /// The modifiers, selection keys, and borrowed key bindings captured at engage time, so
    /// mid-gesture edits can't confuse the session.
    private var requiredModifiers: CGEventFlags = []
    private var engagedSelectionKeys: [CGKeyCode: ZoneNavigationKey] = [:]
    private var engagedMoveKey: CGKeyCode?
    private var engagedLauncherKey: CGKeyCode?
    private var engagedAddZoneKey: CGKeyCode?
    private var engagedRemoveZoneKey: CGKeyCode?
    private var engagedMinimizeKey: CGKeyCode?
    /// The keys whose press the tap swallowed and that are still held down (see `HeldKeys`).
    private var heldKeys = HeldKeys()

    /// While true (hotkeys suspended, or sleep/wake protection active) every keystroke passes, and
    /// an in-flight gesture is dropped: its releases may never be seen.
    var isSuspended: Bool {
        get { lock.withLock { suspended } }
        set {
            lock.withLock {
                suspended = newValue
                if newValue {
                    cancelEngagement()
                }
            }
        }
    }

    /// Whether a chord may start a gesture: false while a chooser that owns the arrow keys is open,
    /// or no screen is navigable. The chord then passes through.
    var canBegin: Bool {
        get { lock.withLock { canBeginGesture } }
        set { lock.withLock { canBeginGesture = newValue } }
    }

    func start(delegate: ZoneNavigationInterceptorDelegate) {
        self.delegate = delegate

        guard eventTap == nil else {
            Logger.debug("ZoneNavigationInterceptor already running")
            return
        }

        let tap = EventTapController(
            name: "Zone navigation interceptor",
            events: [.keyDown, .keyUp, .flagsChanged],
            runLoop: EventTapThread.keyboard.runLoop,
            onDisabled: { [weak self] _ in
                guard let self else { return }
                self.lock.withLock { self.cancelEngagement() }
            },
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
        resetInputState()
    }

    /// External invalidation (topology change): disengage and invalidate any queued begin — the
    /// gesture it would start belongs to a snapshot that no longer exists. The keys are still
    /// held, so what the tap has taken of them it keeps until their release.
    func resetEngagement() {
        lock.withLock {
            engagementGeneration &+= 1
            disengage()
        }
    }

    /// Everything the tap remembers about held keys is dropped — the engagement, any queued begin,
    /// and the held-key marks — for when the releases may never arrive (sleep or lock, `stop`).
    func resetInputState() {
        lock.withLock {
            engagementGeneration &+= 1
            disengage()
            heldKeys.removeAll()
        }
    }

    /// Ends `engagement` if it is still the current gesture: the delegate's ending for a gesture it
    /// was handed (the begin was refused or resolved nothing, the gesture's own topology change left
    /// nothing to select). A gesture engaged since is untouched, and a queued begin is not
    /// invalidated — it can only belong to that newer gesture.
    func endEngagement(_ engagement: Engagement) {
        lock.withLock {
            if self.engagement == engagement {
                disengage()
            }
        }
    }

    /// Gesture endings that leave any queued begin valid (modifier release, Escape, `endEngagement`,
    /// tap disable): the begin's state is still created, and the queued commit or cancel that
    /// follows finds it.
    private func disengage() {
        isEngaged = false
        requiredModifiers = []
        engagedSelectionKeys = [:]
        engagedMoveKey = nil
        engagedLauncherKey = nil
        engagedAddZoneKey = nil
        engagedRemoveZoneKey = nil
        engagedMinimizeKey = nil
    }

    /// Drop an in-flight gesture and tell the delegate to tear down its overlay. Also drops the
    /// held-key marks: the tap may deliver no further events (disable, suspension), so the
    /// releases that would clear them may never be seen.
    private func cancelEngagement() {
        heldKeys.removeAll()
        guard isEngaged else { return }
        disengage()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.zoneNavigationDidCancel(self)
        }
    }

    private func processEvent(_ event: CGEvent, type: CGEventType) -> EventTapDecision {
        lock.withLock {
            guard !suspended else {
                return .pass
            }
            let relevantFlags = event.flags.intersection(Self.relevantModifierFlags)
            switch type {
            case .flagsChanged:
                return handleFlagsChanged(relevantFlags: relevantFlags)
            case .keyDown:
                return handleKeyDown(event: event, relevantFlags: relevantFlags)
            case .keyUp:
                // The release of a held key is swallowed like the presses before it: the app saw
                // none of them.
                let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
                return heldKeys.released(keyCode) ? .swallow : .pass
            default:
                return .pass
            }
        }
    }

    private func handleFlagsChanged(relevantFlags: CGEventFlags) -> EventTapDecision {
        guard isEngaged else {
            return .pass
        }

        // The gesture ends — and the selected zone is committed — when any required modifier is released.
        if !relevantFlags.contains(requiredModifiers) {
            disengage()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.zoneNavigationDidCommit(self)
            }
        }
        return .pass
    }

    private func handleKeyDown(event: CGEvent, relevantFlags: CGEventFlags) -> EventTapDecision {
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0

        // A key whose press the tap took stays taken until it is released: its auto-repeats are
        // swallowed whether or not the gesture is still engaged, and only a held arrow still acts
        // (it keeps stepping). Nothing else acts again without a fresh press.
        if heldKeys.isRepeatOfSwallowedPress(keyCode, isRepeat: isRepeat) {
            if isEngaged, relevantFlags.contains(requiredModifiers),
               let key = engagedSelectionKeys[keyCode], !key.isJump {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.delegate?.zoneNavigation(self, didPress: key)
                }
            }
            return .swallow
        }

        let decision = isEngaged
            ? handleEngagedKeyDown(keyCode: keyCode, isRepeat: isRepeat, relevantFlags: relevantFlags)
            : handleDisengagedKeyDown(keyCode: keyCode, relevantFlags: relevantFlags)
        if decision == .swallow {
            heldKeys.swallowedPress(keyCode, isRepeat: isRepeat)
        }
        return decision
    }

    private func handleEngagedKeyDown(
        keyCode: CGKeyCode,
        isRepeat: Bool,
        relevantFlags: CGEventFlags
    ) -> EventTapDecision {
        // Cancel without committing.
        if keyCode == Self.escapeKeyCode {
            disengage()
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

        // Step or jump the selection on a selection key (while the required modifiers are still
        // held). A held arrow keeps stepping; a jump key's auto-repeats are swallowed but ignored
        // — a jump is idempotent, and a held cell key would otherwise keep adding zones (its
        // first press can add a column, its second stack that column).
        if let key = engagedSelectionKeys[keyCode] {
            if !key.isJump || !isRepeat {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.delegate?.zoneNavigation(self, didPress: key)
                }
            }
            return .swallow
        }

        // The borrowed action keys, in claim order. Swallowing keeps the chord from doubling as
        // the shortcut's own global hotkey (the same chord by default). Only a fresh press acts: a
        // repeat here is of a key held since before the gesture, and a held key must not cascade
        // changes (a held Minimize would otherwise minimize and then remove the emptied zone).
        guard keyCode == engagedMoveKey || keyCode == engagedLauncherKey || keyCode == engagedAddZoneKey
                || keyCode == engagedRemoveZoneKey || keyCode == engagedMinimizeKey else {
            return .pass
        }
        guard !isRepeat else { return .swallow }

        // Move the focused window into the selected zone, or target it and open the Launcher there.
        // Either key ends the gesture here, whether or not the delegate then finds something to
        // move, so a fresh selection key starts the next gesture at once.
        let isMove = keyCode == engagedMoveKey
        disengage()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if isMove {
                self.delegate?.zoneNavigationDidPressMoveKey(self)
            } else {
                self.delegate?.zoneNavigationDidPressShowLauncherKey(self)
            }
        }
        return .swallow

        // Add or remove a zone for the selected zone, or minimize its window; the gesture stays
        // engaged and continues around the result. Resolved here on the tap thread: the engaged
        // keys are cleared once the gesture ends, so the queued callback can't re-derive them.
        let isAdd = keyCode == engagedAddZoneKey
        let isRemove = !isAdd && keyCode == engagedRemoveZoneKey
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if isAdd {
                self.delegate?.zoneNavigationDidPressAddZoneKey(self)
            } else if isRemove {
                self.delegate?.zoneNavigationDidPressRemoveZoneKey(self)
            } else {
                self.delegate?.zoneNavigationDidPressMinimizeKey(self)
            }
        }
        return .swallow
    }

    /// Engages on the chord: the gesture's modifiers, exactly, plus an enabled selection key.
    private func handleDisengagedKeyDown(keyCode: CGKeyCode, relevantFlags: CGEventFlags) -> EventTapDecision {
        // Fast paths for ordinary typing, checked cheapest-first: the chord requires modifiers
        // (the store guarantees a valid combination), and they must match exactly, before the
        // selection keys are even consulted.
        guard !relevantFlags.isEmpty,
              relevantFlags == ModifierCombinationPreferences.zoneNavigation.modifiers.cgEventFlags else {
            return .pass
        }

        let selectionKeys = ZoneNavigationKeyPreferences.shared.selectionKeys
        guard let key = selectionKeys[keyCode], canBeginGesture else {
            return .pass
        }

        // Engage immediately so repeated presses are swallowed even though the UI work is async.
        // The Move, Launcher, Add Zone, Remove Zone, and Minimize keys are borrowed from those
        // shortcuts — only their key codes matter, since the gesture's modifiers are already held.
        isEngaged = true
        engagement = Engagement(id: engagement.id + 1)
        requiredModifiers = relevantFlags
        engagedSelectionKeys = selectionKeys
        let shortcutPreferences = KeyboardShortcutPreferences.shared
        engagedMoveKey = shortcutPreferences.shortcut(for: .moveFocusedWindowToTargetZone)
            .map { CGKeyCode($0.keyCode) }
        engagedLauncherKey = shortcutPreferences.shortcut(for: .showLauncher)
            .map { CGKeyCode($0.keyCode) }
        engagedAddZoneKey = shortcutPreferences.shortcut(for: .addZone)
            .map { CGKeyCode($0.keyCode) }
        engagedRemoveZoneKey = shortcutPreferences.shortcut(for: .removeZone)
            .map { CGKeyCode($0.keyCode) }
        engagedMinimizeKey = shortcutPreferences.shortcut(for: .minimizeActiveWindow)
            .map { CGKeyCode($0.keyCode) }

        let generation = engagementGeneration
        let engagement = self.engagement
        DispatchQueue.main.async { [weak self] in
            guard let self, self.lock.withLock({ self.engagementGeneration == generation }) else { return }
            self.delegate?.zoneNavigation(self, didBegin: key, engagement: engagement)
        }
        return .swallow
    }

    deinit {
        stop()
    }
}

extension ZoneNavigationInterceptor {
    /// The keys whose press the tap swallowed and that are still held down. What the tap took the
    /// press of, it keeps until the release: the auto-repeats — which would otherwise leak into
    /// the focused app, or fire the global hotkey behind an action key once the gesture has ended
    /// — and the release itself, so the app sees neither. Tracked by key-up rather than by
    /// modifier state, since the shortcut behind an action key may hold under fewer modifiers
    /// than the gesture. A fresh press of a key still marked held means its release went unseen:
    /// the mark is dropped and the press handled like any other, so a stale mark never costs a
    /// keystroke.
    struct HeldKeys {
        private var keyCodes: Set<CGKeyCode> = []

        /// A key-down: true when it is a repeat of a swallowed press (swallow it; only a held arrow
        /// still acts). A fresh press of a marked key drops the stale mark and reports false.
        mutating func isRepeatOfSwallowedPress(_ keyCode: CGKeyCode, isRepeat: Bool) -> Bool {
            guard keyCodes.contains(keyCode) else { return false }
            if isRepeat { return true }
            keyCodes.remove(keyCode)
            return false
        }

        /// The tap swallowed this key-down; a fresh press marks the key held. A swallowed repeat
        /// is of a key pressed before the tap cared — its release belongs to whoever saw the press.
        mutating func swallowedPress(_ keyCode: CGKeyCode, isRepeat: Bool) {
            if !isRepeat { keyCodes.insert(keyCode) }
        }

        /// A key-up: true when the key was marked held (swallow it too), clearing the mark.
        mutating func released(_ keyCode: CGKeyCode) -> Bool {
            keyCodes.remove(keyCode) != nil
        }

        mutating func removeAll() {
            keyCodes.removeAll()
        }
    }
}
