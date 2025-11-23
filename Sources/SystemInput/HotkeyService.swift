import AppKit
import Carbon

/// Registers and dispatches global and local hotkey shortcuts
final class HotkeyService {
    enum Action: UInt32 {
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
    }

    weak var delegate: HotkeyServiceDelegate?

    private let hotKeySignature: OSType = 0x4C415454 // 'LATT'
    private var hotKeyRefs: [EventHotKeyRef] = []
    private var hotKeyEventHandler: EventHandlerRef?
    private let baseHotKeyModifiers: UInt32 = UInt32(cmdKey | controlKey)

    func start(delegate: HotkeyServiceDelegate) {
        self.delegate = delegate
        installHotKeyEventHandler()
        registerHotKeys()
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

    func handleLocalShortcut(event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Check for Cmd-M (only Command key, no Control)
        if flags.contains(.command) && !flags.contains(.control) && !flags.contains(.option) && !flags.contains(.shift) {
            if Int(event.keyCode) == kVK_ANSI_M {
                delegate?.hotkeyService(self, didTrigger: .minimizeActiveWindow)
                return true
            }
        }

        guard flags.contains(.command),
              flags.contains(.control) else {
            return false
        }

        let usesCursorScreen = flags.contains(.option) && flags.contains(.shift)

        switch Int(event.keyCode) {
        case kVK_ANSI_Equal:
            delegate?.hotkeyService(self, didTrigger: .addZone)
            return true
        case kVK_ANSI_Minus:
            delegate?.hotkeyService(self, didTrigger: .removeZone)
            return true
        case kVK_ANSI_Z:
            delegate?.hotkeyService(self, didTrigger: .captureTimeTravelLogs)
            return true
        case kVK_ANSI_M:
            if flags.contains(.option) && flags.contains(.shift) {
                delegate?.hotkeyService(self, didTrigger: .minimizeWindowOrRemoveZoneAtCursor)
                return true
            }
            return false
        case kVK_Return:
            delegate?.hotkeyService(self, didTrigger: .flipKeyWindow)
            return true
        case kVK_Space:
            let action: Action = usesCursorScreen ? .clearOrResetZonesAtCursor : .clearOrResetZones
            delegate?.hotkeyService(self, didTrigger: action)
            return true
        case kVK_DownArrow:
            delegate?.hotkeyService(self, didTrigger: .targetTemporaryZone)
            return true
        case kVK_UpArrow:
            delegate?.hotkeyService(self, didTrigger: .navigateUp)
            return true
        case kVK_LeftArrow:
            delegate?.hotkeyService(self, didTrigger: .navigateLeft)
            return true
        case kVK_RightArrow:
            delegate?.hotkeyService(self, didTrigger: .navigateRight)
            return true
        default:
            return false
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
        registerHotKey(keyCode: UInt32(kVK_ANSI_Equal), action: .addZone)
        registerHotKey(keyCode: UInt32(kVK_ANSI_Minus), action: .removeZone)
        registerHotKey(keyCode: UInt32(kVK_ANSI_Z), action: .captureTimeTravelLogs)
        registerHotKey(keyCode: UInt32(kVK_Return), action: .flipKeyWindow)
        registerHotKey(keyCode: UInt32(kVK_Space), action: .clearOrResetZones)
        registerHotKey(
            keyCode: UInt32(kVK_Space),
            action: .clearOrResetZonesAtCursor,
            modifierFlags: baseHotKeyModifiers | UInt32(shiftKey | optionKey)
        )
        registerHotKey(keyCode: UInt32(kVK_DownArrow), action: .targetTemporaryZone)
        registerHotKey(keyCode: UInt32(kVK_UpArrow), action: .navigateUp)
        registerHotKey(keyCode: UInt32(kVK_LeftArrow), action: .navigateLeft)
        registerHotKey(keyCode: UInt32(kVK_RightArrow), action: .navigateRight)
        // Register Cmd-M with only Command key modifier (no Control)
        registerHotKey(keyCode: UInt32(kVK_ANSI_M), action: .minimizeActiveWindow, modifierFlags: UInt32(cmdKey))
        // Register Shift-Option-Control-Cmd-M for cursor-based minimize/remove behavior
        registerHotKey(
            keyCode: UInt32(kVK_ANSI_M),
            action: .minimizeWindowOrRemoveZoneAtCursor,
            modifierFlags: baseHotKeyModifiers | UInt32(shiftKey | optionKey)
        )
    }

    private func registerHotKey(
        keyCode: UInt32,
        action: Action,
        modifierFlags: UInt32? = nil
    ) {
        var hotKeyRef: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: hotKeySignature, id: action.rawValue)
        let status = RegisterEventHotKey(
            keyCode,
            modifierFlags ?? baseHotKeyModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            OptionBits(kEventHotKeyExclusive),
            &hotKeyRef
        )

        if status == noErr, let hotKeyRef {
            hotKeyRefs.append(hotKeyRef)
            Logger.debug("Registered hotkey action \(action) keyCode \(keyCode)")
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
