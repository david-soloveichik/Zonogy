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
        static let eventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        static let escapeKeyCode = CGKeyCode(kVK_Escape)
    }

    weak var delegate: CmdTabKeyInterceptorDelegate?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

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

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(Constants.eventMask),
            callback: CmdTabKeyInterceptor.eventCallback,
            userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        ) else {
            Logger.debug("Failed to install CmdTab keyboard interceptor (missing Input Monitoring permission?)")
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let source = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        Logger.debug("CmdTab keyboard interceptor started")
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }

        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }

        runLoopSource = nil
        eventTap = nil
        isEngaged = false
        engagedShortcut = nil
    }

    func resetEngagement() {
        isEngaged = false
        engagedShortcut = nil
    }

    private func processEvent(_ event: CGEvent, type: CGEventType) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByUserInput, .tapDisabledByTimeout:
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
                Logger.debug("Re-enabled CmdTab keyboard interceptor after timeout")
            }
            return Unmanaged.passUnretained(event)
        case .keyDown, .flagsChanged:
            break
        default:
            return Unmanaged.passUnretained(event)
        }

        guard let delegate, delegate.cmdTabKeyInterceptorShouldHandleEvents(self) else {
            return Unmanaged.passUnretained(event)
        }

        let relevantFlags = event.flags.intersection(Constants.relevantModifierFlags)

        if type == .flagsChanged {
            return handleFlagsChanged(event: event, relevantFlags: relevantFlags)
        }

        return handleKeyDown(event: event, relevantFlags: relevantFlags)
    }

    private func handleFlagsChanged(event: CGEvent, relevantFlags: CGEventFlags) -> Unmanaged<CGEvent>? {
        guard isEngaged, let engagedShortcut else {
            return Unmanaged.passUnretained(event)
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
            return Unmanaged.passUnretained(event)
        }

        return Unmanaged.passUnretained(event)
    }

    private func handleKeyDown(event: CGEvent, relevantFlags: CGEventFlags) -> Unmanaged<CGEvent>? {
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
            return Unmanaged.passUnretained(event)
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
        return nil
    }

    private func handleKeyDownWhileEngaged(keyCode: CGKeyCode, relevantFlags: CGEventFlags, event: CGEvent) -> Unmanaged<CGEvent>? {
        guard let engagedShortcut else {
            // Shouldn't happen, but don't get stuck in an engaged state.
            isEngaged = false
            return Unmanaged.passUnretained(event)
        }

        // Cancel (even while modifiers are held).
        if keyCode == Constants.escapeKeyCode, delegate?.cmdTabKeyInterceptorIsCmdTabVisible(self) == true {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.cmdTabKeyInterceptorCancel(self)
            }
            isEngaged = false
            self.engagedShortcut = nil
            return nil
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
            return nil
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
                    return nil
                }
            }
        }

        return Unmanaged.passUnretained(event)
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

        let requiredModifiers = cgEventFlags(fromCarbonModifiers: shortcut.modifiers)
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

        let requiredModifiers = cgEventFlags(fromCarbonModifiers: shortcut.modifiers)
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

    private func cgEventFlags(fromCarbonModifiers modifiers: UInt32) -> CGEventFlags {
        var flags: CGEventFlags = []
        if modifiers & UInt32(cmdKey) != 0 { flags.insert(.maskCommand) }
        if modifiers & UInt32(controlKey) != 0 { flags.insert(.maskControl) }
        if modifiers & UInt32(optionKey) != 0 { flags.insert(.maskAlternate) }
        if modifiers & UInt32(shiftKey) != 0 { flags.insert(.maskShift) }
        return flags
    }

    private static let eventCallback: CGEventTapCallBack = { proxy, type, cgEvent, userInfo in
        guard let userInfo else {
            return Unmanaged.passUnretained(cgEvent)
        }
        let interceptor = Unmanaged<CmdTabKeyInterceptor>.fromOpaque(userInfo).takeUnretainedValue()
        return interceptor.processEvent(cgEvent, type: type)
    }

    deinit {
        stop()
    }
}
