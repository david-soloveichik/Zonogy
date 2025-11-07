import Foundation
import CoreGraphics
import ApplicationServices

/// Listens for low-level CGDisplay reconfiguration callbacks and forwards them to a delegate.
final class DisplayReconfigurationMonitor {
    struct Event {
        let displayId: CGDirectDisplayID
        let flags: CGDisplayChangeSummaryFlags

        var isAdd: Bool { flags.contains(.addFlag) }
        var isRemove: Bool { flags.contains(.removeFlag) }
        var isMove: Bool { flags.contains(.movedFlag) }
        var isEnabled: Bool { flags.contains(.enabledFlag) }
        var isDisabled: Bool { flags.contains(.disabledFlag) }
        var isConfigurationChange: Bool {
            flags.contains(.setMainFlag) || flags.contains(.setModeFlag) || flags.contains(.desktopShapeChangedFlag)
        }
    }

    weak var delegate: DisplayReconfigurationMonitorDelegate?

    private var callbackContext: UnsafeMutableRawPointer?
    private var isStarted = false

    func start(delegate: DisplayReconfigurationMonitorDelegate) {
        self.delegate = delegate
        guard !isStarted else { return }

        let context = Unmanaged.passUnretained(self).toOpaque()
        CGDisplayRegisterReconfigurationCallback(DisplayReconfigurationMonitorCallback, context)
        callbackContext = context
        isStarted = true
    }

    func stop() {
        guard isStarted else { return }
        CGDisplayRemoveReconfigurationCallback(DisplayReconfigurationMonitorCallback, callbackContext)
        callbackContext = nil
        isStarted = false
    }

    deinit {
        stop()
    }

    fileprivate func handle(displayId: CGDirectDisplayID, flags: CGDisplayChangeSummaryFlags) {
        guard let delegate else { return }
        let event = Event(displayId: displayId, flags: flags)
        delegate.displayMonitor(self, didObserve: event)
    }
}

protocol DisplayReconfigurationMonitorDelegate: AnyObject {
    func displayMonitor(_ monitor: DisplayReconfigurationMonitor, didObserve event: DisplayReconfigurationMonitor.Event)
}

private func DisplayReconfigurationMonitorCallback(
    _ displayId: CGDirectDisplayID,
    _ flags: CGDisplayChangeSummaryFlags,
    _ userInfo: UnsafeMutableRawPointer?
) {
    guard let userInfo else { return }
    let monitor = Unmanaged<DisplayReconfigurationMonitor>.fromOpaque(userInfo).takeUnretainedValue()
    monitor.handle(displayId: displayId, flags: flags)
}

private extension CGDisplayChangeSummaryFlags {
    static func flag(bit: UInt32) -> CGDisplayChangeSummaryFlags {
        CGDisplayChangeSummaryFlags(rawValue: UInt32(1) << bit)
    }

    static let addFlag = flag(bit: 4)
    static let removeFlag = flag(bit: 5)
    static let movedFlag = flag(bit: 1)
    static let enabledFlag = flag(bit: 6)
    static let disabledFlag = flag(bit: 7)
    static let setMainFlag = flag(bit: 2)
    static let setModeFlag = flag(bit: 3)
    static let desktopShapeChangedFlag = flag(bit: 10)
}
