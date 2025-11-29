# Sleep / Wake Behavior

IMPORTANT: This specification does not mention logging. It is expected that the implementation will decide on which information needs to be logged and when.

IMPORTANT TERMINOLOGY: When we say "window" this refers to managed windows of other applications. To refer to placeholder windows, we explicitly say "placeholder [window]". When we say "zone" without a qualifier, we mean either a normal (tiling) zone, or a temporary zone.

Based on testing, it is safe to assume that CGWindowID is preserved between sleep/wake cycles. We do all our matching based on this.

We track sleep/wake cycles with a single flag:
- `sleepWakeCycle` (bool): true between `willSleep` and completion of the wake pipeline. When true, we aggressively ignore all non-sleep/wake notifications.

Note: `sleepWakeCycle` starts out as false.

## Going to sleep

Triggered by: `NSWorkspace.willSleepNotification`.

If `sleepWakeCycle` is already true, ignore this notification as a spurious extra `willSleep`.

Otherwise:
- Set `sleepWakeCycle = true`
- Cancel any existing sleep/wake timers

When `sleepWakeCycle = true`, we do not process any notifications (at any level) other than `NSWorkspace.willSleepNotification` and `NSWorkspace.didWakeNotification`. Basically, at this point all the app is doing is waiting for `NSWorkspace.didWakeNotification`. The idea behind this is that during going to sleep there are notifications that would mislead us to stop managing the window. This aggressive behavior is intentional. [workaround #1]

## Waking up

Triggered by: `NSWorkspace.didWakeNotification`.

If `sleepWakeCycle` is false, ignore this notification as spurious (there is no active cycle).

Otherwise:
- Start a 0.5s `sleepWakeCycleTimer`

We have to be careful because during the process of going to sleep there seem to be some spurious didWakeNotification and willSleepNotification notifications, and we want to ignore these. So we wait 0.5s (`sleepWakeCycleTimer`) before doing anything—hopefully this avoids the spurious sleep/wake cycles. [workaround #2]

When `sleepWakeCycleTimer` fires, it must first check that `sleepWakeCycle` is still true. If not, it exits without doing anything (the cycle was superseded or already completed).

Our big picture goal is to minimize the windows on screen that were possibly disconnected during sleep. Right after the 0.5s timer fires and passes the check above (and before we start inspecting applications/windows), we recompute the current screen topology (e.g., via `NSScreen.screens` / `screenContextStore` rebuild). A screen is considered a *remaining* screen if it still exists. If there is no intersection between pre-sleep and post-wake screens, then all eligible windows will be minimized.

For eligible applications (using normal rules):  // Fresh enumeration
    - For every eligible window A (using normal rules):
        - If A _isn't_ in a zone of one of the _remaining_ screens:
            - If A isn't minimized, minimize it (this is intentionally aggressive to keep the screen clean, even for newly-created windows)
        - Else: // if A _is_ in a zone of one of the remaining screens
            - Mark A as "restored"

The issue with the above loop is that right after wake, applications might not be ready for Accessibility (AX) API. So during the above traversal of applications and windows, if at any time we encounter an error in the AX API, we ignore it (logging it of course) and continue. We repeat the whole above loop "For eligible applications" a number of times, *serially*: after one full enumeration finishes, we wait a fixed delta (e.g., 0.5s, 0.5s, 1s) before starting the next attempt. [workaround #3]

During the above application/window enumeration loops, as soon as we detect that all windows in all zones on all _remaining_ screens have been marked as "restored" 
OR if the loop repeats finish:
    syncWindowsToZones()
    set sleepWakeCycle = false

Note that we always complete all the loops repetitions in order to minimize the windows we don't want. The goal of the early `syncWindowsToZones()` is to get the UI to look good as soon as possible.

Note: if we complete all of the above loops (for all repeats), and there are still some windows in some zones in remaining screens that have not been marked as "restored", they will be purged from our internal representation when `syncWindowsToZones()` runs. This is intentional; we do not perform a later reconciliation pass.

