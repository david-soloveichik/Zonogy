/// Delivery of input work to the main thread: the event taps' actions and click decisions, and the
/// global hotkeys' actions. Blocks are scheduled on the main run loop in the common modes rather than
/// on the main dispatch queue: they run in submission order wherever they were submitted from, so a
/// hotkey, a chooser chord, and a click pressed in quick succession act in that order, and a nested
/// run loop entered from a dispatch block (a modal alert, say) still services them, as it serviced
/// the taps when they lived on the main run loop. The order holds as long as no block runs a nested
/// run loop itself: the run loop hands out the blocks it finds in batches, and a block submitted
/// while a batch is still running could run inside a nested loop ahead of that batch's remainder.

import Foundation
import os

enum MainRunLoop {
    /// Runs `block` on the main thread, after every block scheduled before it.
    static func perform(_ block: @escaping () -> Void) {
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue, block)
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }

    /// Runs `body` on the main thread and waits for its result. Never call on the main thread.
    static func performAndWait<T>(_ body: @escaping () -> T) -> T {
        let done = DispatchSemaphore(value: 0)
        let result = OSAllocatedUnfairLock<T?>(uncheckedState: nil)
        perform {
            let value = body()
            result.withLockUnchecked { $0 = value }
            done.signal()
        }
        done.wait()
        return result.withLockUnchecked { $0! }
    }
}
