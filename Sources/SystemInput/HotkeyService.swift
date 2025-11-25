import AppKit
import Carbon

/// Registers and dispatches global and local hotkey shortcuts
final class HotkeyService {
    enum Action: UInt32, CaseIterable {
        case addZone = 1
        case removeZone = 2
        case captureTimeTravelLogs = 3
        case flipKeyWindow = 4
        case clearOrResetZones = 5
        case targetTemporaryZone = 6
        case navigateUp = 7
        case navigateLeft = 8
        case navigateRight = 9
        case clearOrResetZonesAtCursor = 10
        case minimizeActiveWindow = 11
        case minimizeWindowOrRemoveZoneAtCursor = 12

        /// Maps to the corresponding preferences action
        var preferencesAction: KeyboardShortcutPreferences.ShortcutAction {
            switch self {
            case .addZone: return .addZone
            case .removeZone: return .removeZone
            case .captureTimeTravelLogs: return .captureTimeTravelLogs
            case .flipKeyWindow: return .flipKeyWindow
            case .clearOrResetZones: return .clearOrResetZones
            case .targetTemporaryZone: return .targetTemporaryZone
            case .navigateUp: return .navigateUp
            case .navigateLeft: return .navigateLeft
            case .navigateRight: return .navigateRight
            case .clearOrResetZonesAtCursor: return .clearOrResetZonesAtCursor
            case .minimizeActiveWindow: return .minimizeActiveWindow
            case .minimizeWindowOrRemoveZoneAtCursor: return .minimizeWindowOrRemoveZoneAtCursor
            }
        }
    }

    weak var delegate: HotkeyServiceDelegate?
    private let preferences = KeyboardShortcutPreferences.shared

    private let hotKeySignature: OSType = 0x4C415454 // 'LATT'
    private var hotKeyRefs: [EventHotKeyRef] = []
    private var hotKeyEventHandler: EventHandlerRef?
    private var isSuspended = false

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
            guard let shortcut = preferences.shortcut(for: action.preferencesAction) else {
                continue // Skip cleared shortcuts
            }
            if shortcut.keyCode == keyCode && shortcut.modifiers == carbonModifiers {
                delegate?.hotkeyService(self, didTrigger: action)
                return true
            }
        }

        return false
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

        if let action = Action(rawValue: hotKeyID.id) {
            delegate?.hotkeyService(self, didTrigger: action)
        }

        return noErr
    }

    private func installHotKeyEventHandler() {
        guard hotKeyEventHandler == nil else { return }

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            HotkeyServiceEventHandler,
            1,
            &eventType,
            UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            &hotKeyEventHandler
        )

        if status != noErr {
            Logger.debug("Failed to install hotkey handler with status \(status)")
        }
    }

    private func registerHotKeys() {
        for action in Action.allCases {
            if let shortcut = preferences.shortcut(for: action.preferencesAction) {
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
