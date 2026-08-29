import AppKit
import Carbon

/// Registers and dispatches global and local hotkey shortcuts
final class HotkeyService {
    enum Action: UInt32, CaseIterable {
        case addZone = 1
        case removeZone = 2
        case collapseToOneZone = 17
        case captureTimeTravelLogs = 3
        case clearOrResetZones = 5
        case clearOrResetZonesAtCursor = 10
        case minimizeActiveWindow = 11
        case minimizeWindowOrRemoveZoneAtCursor = 12
        case saveWinShotSnapshot = 13
        case showWinShotChooser = 14
        case showLauncher = 15
        case toggleTargetZoneWithFocusedWindow = 18
        case moveFocusedWindowToTargetZone = 19

        /// Maps to the corresponding preferences action
        var preferencesAction: KeyboardShortcutPreferences.ShortcutAction? {
            switch self {
            case .addZone: return .addZone
            case .removeZone: return .removeZone
            case .collapseToOneZone: return .collapseToOneZone
            case .captureTimeTravelLogs: return .captureTimeTravelLogs
            case .clearOrResetZones: return .clearOrResetZones
            case .toggleTargetZoneWithFocusedWindow: return .toggleTargetZoneWithFocusedWindow
            case .moveFocusedWindowToTargetZone: return .moveFocusedWindowToTargetZone
            case .clearOrResetZonesAtCursor: return .clearOrResetZonesAtCursor
            case .minimizeActiveWindow: return .minimizeActiveWindow
            case .minimizeWindowOrRemoveZoneAtCursor: return .minimizeWindowOrRemoveZoneAtCursor
            case .saveWinShotSnapshot: return .saveWinShotSnapshot
            case .showWinShotChooser: return .showWinShotChooser
            case .showLauncher: return .showLauncher
            }
        }

        /// Returns the fixed shortcut for actions without configurable preferences
        var fixedShortcut: KeyboardShortcut? {
            // All shortcuts are now configurable via preferences
            return nil
        }

        /// Actions whose press pairs with a hold follow-up (see `ShortcutHoldPolicy`): the press's
        /// first action fires immediately and keeping the chord held performs the paired second
        /// action, so key-autorepeat re-triggers are suppressed while the chord stays down.
        var supportsHoldFollowUp: Bool {
            switch self {
            case .clearOrResetZones, .clearOrResetZonesAtCursor,
                 .minimizeActiveWindow, .minimizeWindowOrRemoveZoneAtCursor:
                return true
            default:
                return false
            }
        }
    }

    weak var delegate: HotkeyServiceDelegate?
    private let preferences = KeyboardShortcutPreferences.shared

    private let hotKeySignature: OSType = 0x4C415454 // 'LATT'
    private var hotKeyRefs: [EventHotKeyRef] = []
    private var hotKeyEventHandler: EventHandlerRef?
    private(set) var isSuspended = false

    /// Hold-follow-up actions whose chord is currently down (pressed seen, released not yet).
    /// Used to swallow the key-autorepeat pressed events Carbon re-delivers while a hotkey stays
    /// held, so a hold reads as one press. Cleared whenever registrations are torn down, since a
    /// released event never arrives for an unregistered hotkey.
    private var heldHoldFollowUpActions: Set<Action> = []

    /// When each hold-follow-up action last delivered a pressed event, for the stale-mark
    /// self-heal below: autorepeats arrive at the key-repeat rate, so a pressed event this long
    /// after the previous one cannot be a repeat — the release must have been missed.
    private var holdFollowUpPressedAt: [Action: Date] = [:]
    private static let staleHeldMarkInterval: TimeInterval = 3.0

    func start(delegate: HotkeyServiceDelegate) {
        self.delegate = delegate
        installHotKeyEventHandler()
        registerHotKeys()

        // Listen for preference changes to re-register hotkeys
        preferences.onShortcutsChanged = { [weak self] in
            self?.reregisterHotKeys()
        }
    }

    func stop() {
        for hotKeyRef in hotKeyRefs {
            UnregisterEventHotKey(hotKeyRef)
        }
        hotKeyRefs.removeAll()
        resetHoldInputState()

        if let handler = hotKeyEventHandler {
            RemoveEventHandler(handler)
            hotKeyEventHandler = nil
        }
    }

    /// Temporarily suspends all hotkeys (e.g., while recording a new shortcut)
    func suspend() {
        guard !isSuspended else { return }
        isSuspended = true

        for hotKeyRef in hotKeyRefs {
            UnregisterEventHotKey(hotKeyRef)
        }
        hotKeyRefs.removeAll()
        resetHoldInputState()
        Logger.debug("Hotkeys suspended")
    }

    /// Resumes hotkeys after suspension
    func resume() {
        guard isSuspended else { return }
        isSuspended = false

        registerHotKeys()
        Logger.debug("Hotkeys resumed")
    }

    func handleLocalShortcut(event: NSEvent) -> Bool {
        // Don't handle shortcuts while suspended (e.g., during shortcut recording)
        guard !isSuspended else { return false }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let keyCode = UInt32(event.keyCode)

        // Convert Cocoa modifiers to Carbon modifiers for comparison
        var carbonModifiers: UInt32 = 0
        if flags.contains(.command) { carbonModifiers |= UInt32(cmdKey) }
        if flags.contains(.control) { carbonModifiers |= UInt32(controlKey) }
        if flags.contains(.option) { carbonModifiers |= UInt32(optionKey) }
        if flags.contains(.shift) { carbonModifiers |= UInt32(shiftKey) }

        // Check each action's shortcut
        for action in Action.allCases {
            guard let shortcut = boundShortcut(for: action) else { continue }

            if shortcut.keyCode == keyCode && shortcut.modifiers == carbonModifiers {
                if action.supportsHoldFollowUp && event.isARepeat {
                    // A held hold-follow-up chord reads as one press; swallow its autorepeats.
                    return true
                }
                delegate?.hotkeyService(self, didTrigger: action)
                return true
            }
        }

        return false
    }

    /// Chord-break detection for locally triggered shortcuts (the fallback when Carbon
    /// registration failed and Zonogy is frontmost), which have no `kEventHotKeyReleased`
    /// event: a key-up of a hold-follow-up shortcut's key, or a modifier change that no longer
    /// covers its modifiers, reports the release so a pending hold follow-up is cancelled
    /// promptly instead of relying solely on the fire-time physical-chord re-check.
    func handleLocalChordBreak(event: NSEvent) {
        guard !isSuspended else { return }

        for action in Action.allCases where action.supportsHoldFollowUp {
            guard let shortcut = boundShortcut(for: action) else { continue }

            let chordBroke: Bool
            switch event.type {
            case .keyUp:
                chordBroke = UInt32(event.keyCode) == shortcut.keyCode
            case .flagsChanged:
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                chordBroke = !flags.contains(shortcut.nsEventModifierFlags)
            default:
                chordBroke = false
            }

            if chordBroke {
                // Also repair the Carbon-held mark: if Carbon's released event was missed, a
                // stale entry here would swallow every later press of this hotkey.
                heldHoldFollowUpActions.remove(action)
                delegate?.hotkeyService(self, didRelease: action)
            }
        }
    }

    fileprivate func handleHotKeyEvent(_ event: EventRef) -> OSStatus {
        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )

        guard status == noErr, hotKeyID.signature == hotKeySignature else {
            return status
        }

        guard let action = Action(rawValue: hotKeyID.id) else {
            return noErr
        }

        switch GetEventKind(event) {
        case UInt32(kEventHotKeyPressed):
            if action.supportsHoldFollowUp {
                let now = Date()
                let previousPressedAt = holdFollowUpPressedAt[action]
                holdFollowUpPressedAt[action] = now
                if !heldHoldFollowUpActions.insert(action).inserted {
                    // A held hold-follow-up chord reads as one press; swallow its autorepeats.
                    // But a pressed event long after the previous one cannot be a repeat: the
                    // release was missed, so treat this as a fresh press instead of letting a
                    // stale held mark swallow the hotkey forever.
                    if let previousPressedAt,
                       now.timeIntervalSince(previousPressedAt) < Self.staleHeldMarkInterval {
                        return noErr
                    }
                    Logger.debug("Hotkey \(action): pressed with a stale held mark (no release seen); treating as a fresh press")
                }
            }
            delegate?.hotkeyService(self, didTrigger: action)
        case UInt32(kEventHotKeyReleased):
            heldHoldFollowUpActions.remove(action)
            delegate?.hotkeyService(self, didRelease: action)
        default:
            break
        }

        return noErr
    }

    /// Whether the shortcut bound to `action` is still physically held: its key is down and every
    /// modifier it requires is still pressed. Consulted when a hold follow-up fires so a release
    /// the event path missed can never let the second action run after the chord was let go.
    func isShortcutChordPhysicallyDown(for action: Action) -> Bool {
        guard let shortcut = boundShortcut(for: action) else { return false }

        guard CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(shortcut.keyCode)) else {
            return false
        }
        return CGEventSource.flagsState(.combinedSessionState).contains(shortcut.cgEventFlags)
    }

    /// Drops the chord-held bookkeeping when releases can no longer be trusted to arrive
    /// (sleep, session lock, registration teardown). A stale held mark would swallow every
    /// later press of that hotkey.
    func resetHoldInputState() {
        heldHoldFollowUpActions.removeAll()
        holdFollowUpPressedAt.removeAll()
    }

    /// Drops a single action's chord-held mark once the chord is known to be physically up
    /// (the hold-follow-up fire path's re-check) even though no release event was seen.
    func clearHeldMark(for action: Action) {
        heldHoldFollowUpActions.remove(action)
    }

    /// The shortcut currently bound to `action`, whether fixed or from preferences.
    private func boundShortcut(for action: Action) -> KeyboardShortcut? {
        if let fixedShortcut = action.fixedShortcut {
            return fixedShortcut
        }
        if let preferencesAction = action.preferencesAction {
            return preferences.shortcut(for: preferencesAction)
        }
        return nil
    }

    private func installHotKeyEventHandler() {
        guard hotKeyEventHandler == nil else { return }

        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            HotkeyServiceEventHandler,
            eventTypes.count,
            &eventTypes,
            UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            &hotKeyEventHandler
        )

        if status != noErr {
            Logger.debug("Failed to install hotkey handler with status \(status)")
        }
    }

    private func registerHotKeys() {
        for action in Action.allCases {
            if let shortcut = boundShortcut(for: action) {
                registerHotKey(shortcut: shortcut, action: action)
            } else {
                Logger.debug("Skipping cleared hotkey for action \(action)")
            }
        }
    }

    private func reregisterHotKeys() {
        // Unregister all existing hotkeys
        for hotKeyRef in hotKeyRefs {
            UnregisterEventHotKey(hotKeyRef)
        }
        hotKeyRefs.removeAll()
        resetHoldInputState()

        // Re-register with updated shortcuts
        registerHotKeys()
        Logger.debug("Re-registered hotkeys after preference change")
    }

    private func registerHotKey(shortcut: KeyboardShortcut, action: Action) {
        var hotKeyRef: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: hotKeySignature, id: action.rawValue)
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            OptionBits(kEventHotKeyExclusive),
            &hotKeyRef
        )

        if status == noErr, let hotKeyRef {
            hotKeyRefs.append(hotKeyRef)
            Logger.debug("Registered hotkey action \(action) shortcut \(shortcut.displayString)")
        } else if status != noErr {
            Logger.debug("Failed to register hotkey \(action) with status \(status)")
        }
    }

    deinit {
        stop()
    }
}

protocol HotkeyServiceDelegate: AnyObject {
    func hotkeyService(_ service: HotkeyService, didTrigger action: HotkeyService.Action)
    /// The chord for `action` was released or broken: Carbon delivers `kEventHotKeyReleased` for
    /// registered hotkeys, and `handleLocalChordBreak` reports key-ups/modifier changes for the
    /// local-monitor fallback. May be delivered redundantly or for chords that never armed
    /// anything; the hold-follow-up fire path additionally re-verifies the physical chord, so a
    /// missed release stays harmless.
    func hotkeyService(_ service: HotkeyService, didRelease action: HotkeyService.Action)
}

private func HotkeyServiceEventHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else { return noErr }
    let service = Unmanaged<HotkeyService>.fromOpaque(userData).takeUnretainedValue()
    return service.handleHotKeyEvent(event)
}
