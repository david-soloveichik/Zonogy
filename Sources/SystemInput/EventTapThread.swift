/// The thread whose run loop services the keyboard event taps. The system waits on an active tap's
/// callback before an event moves on, so a tap serviced by the main run loop couples every app's
/// keyboard latency to Zonogy's main thread and its Accessibility stalls. This thread runs nothing
/// but tap callbacks, which decide what a keystroke means and hand any real work to the main queue.

import Foundation
import os

enum EventTapThread {
    /// Started on first use; the thread and its run loop live for the rest of the process.
    static let runLoop: CFRunLoop = {
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
        thread.name = "Zonogy event taps"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        return runLoopBox.withLockUnchecked { $0! }
    }()
}
