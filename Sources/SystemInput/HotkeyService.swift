import AppKit
import Carbon

/// Registers and dispatches global and local hotkey shortcuts
final class HotkeyService {
    enum Action: UInt32 {
        case addZone = 1
        case removeZone = 2
        case captureTimeTravelLogs = 3
        case flipKeyWindow = 4
    }

    weak var delegate: HotkeyServiceDelegate?

    private let hotKeySignature: OSType = 0x4C415454 // 'LATT'
    private var hotKeyRefs: [EventHotKeyRef] = []
    private var hotKeyEventHandler: EventHandlerRef?

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
        guard event.modifierFlags.contains(.command),
              event.modifierFlags.contains(.control) else {
            return false
        }

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
        case kVK_Return:
            delegate?.hotkeyService(self, didTrigger: .flipKeyWindow)
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
    }

    private func registerHotKey(keyCode: UInt32, action: Action) {
        var hotKeyRef: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: hotKeySignature, id: action.rawValue)
        let modifierFlags = UInt32(cmdKey | controlKey)
        let status = RegisterEventHotKey(
            keyCode,
            modifierFlags,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
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
