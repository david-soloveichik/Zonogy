import AppKit
import Foundation

/// Activates another application with a specific window as its key window, through the window
/// server's private process-activation calls, as the Dock does. See "Focusing a specific window
/// of another application" in SPECIFICATION-IMPLEMENTATION.md for why the public calls can't.
/// The symbols are looked up by name: if a macOS release drops them, `activate` returns false and
/// callers fall back to the public sequence.
enum WindowServerFocus {
    private typealias SetFrontProcess = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UInt32, UInt32) -> Int32
    private typealias PostEventRecord = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> Int32
    private typealias GetProcessForPID = @convention(c) (pid_t, UnsafeMutablePointer<ProcessSerialNumber>) -> Int32

    private struct Symbols {
        let setFrontProcess: SetFrontProcess
        let postEventRecord: PostEventRecord
        let getProcessForPID: GetProcessForPID
    }

    /// kCPSUserGenerated: activate as if the user had chosen the window.
    private static let userGeneratedActivation: UInt32 = 0x200

    private static let symbols: Symbols? = {
        let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT
        guard let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let setFrontProcess = dlsym(skyLight, "_SLPSSetFrontProcessWithOptions"),
              let postEventRecord = dlsym(skyLight, "SLPSPostEventRecordTo"),
              let getProcessForPID = dlsym(defaultHandle, "GetProcessForPID") else {
            Logger.error("Window-specific activation unavailable; focusing falls back to make-main, raise, activate")
            return nil
        }
        return Symbols(
            setFrontProcess: unsafeBitCast(setFrontProcess, to: SetFrontProcess.self),
            postEventRecord: unsafeBitCast(postEventRecord, to: PostEventRecord.self),
            getProcessForPID: unsafeBitCast(getProcessForPID, to: GetProcessForPID.self)
        )
    }()

    /// Makes `pid` the frontmost application with window `windowId` as its key window, without
    /// reordering any window. Returns false when the calls are unavailable or fail.
    static func activate(pid: pid_t, windowId: CGWindowID) -> Bool {
        guard let symbols else {
            return false
        }
        var psn = ProcessSerialNumber()
        guard symbols.getProcessForPID(pid, &psn) == noErr,
              symbols.setFrontProcess(&psn, windowId, userGeneratedActivation) == 0 else {
            return false
        }
        // Two event records (phase 1, then 2) ask the application to make the window key; without
        // them it can end up frontmost with no key window.
        var record = [UInt8](repeating: 0, count: 0xf8)
        record[0x04] = 0xf8
        record[0x3a] = 0x10
        record.replaceSubrange(0x20..<0x30, with: repeatElement(0xff, count: 0x10))
        withUnsafeBytes(of: windowId.littleEndian) { record.replaceSubrange(0x3c..<0x40, with: $0) }
        return [UInt8(0x01), 0x02].allSatisfy { phase in
            record[0x08] = phase
            return record.withUnsafeMutableBufferPointer { symbols.postEventRecord(&psn, $0.baseAddress!) } == 0
        }
    }
}
