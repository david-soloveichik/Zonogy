/// Threads whose run loops service event taps off the main thread. The system waits on an active
/// tap's callback before an event moves on, so a tap serviced by the main run loop couples every
/// app's input latency to Zonogy's main thread and its Accessibility stalls. A tap thread runs
/// nothing but tap callbacks; one exists per kind of waiting a callback may do.

import Foundation
import os

final class EventTapThread {
    /// Services the keyboard taps, whose callbacks never wait on anything.
    static let keyboard = EventTapThread(name: "Zonogy keyboard taps")

    /// Services the mouse taps (the zone click tap, the Dock press tap), whose callbacks wait on the
    /// main thread for the rare click that may be Zonogy's. That wait must never hold up keystrokes,
    /// hence a thread of their own.
    static let mouse = EventTapThread(name: "Zonogy mouse taps")

    /// The thread's run loop; the thread lives for the rest of the process.
    let runLoop: CFRunLoop

    private init(name: String) {
        let ready = DispatchSemaphore(value: 0)
        let runLoopBox = OSAllocatedUnfairLock<CFRunLoop?>(uncheckedState: nil)
        let thread = Thread {
            runLoopBox.withLockUnchecked { $0 = CFRunLoopGetCurrent() }
            // A source that never fires keeps the run loop alive between tap installs.
            var context = CFRunLoopSourceContext()
            context.perform = { _ in }
            let keepAlive = CFRunLoopSourceCreate(kCFAllocatorDefault, 0, &context)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), keepAlive, .commonModes)
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = name
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        runLoop = runLoopBox.withLockUnchecked { $0! }
    }
}
