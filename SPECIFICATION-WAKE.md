# Sleep / Wake Behavior

IMPORTANT: This specification does not mention logging. It is expected that the implementation will decide on which information needs to be logged and when.

IMPORTANT TERMINOLOGY: When we say "window" this refers to managed windows of other applications. To refer to placeholder windows, we explicitly say "placeholder [window]". When we say "zone" without a qualifier, we mean either a normal (tiling) zone, or a temporary zone.

Based on testing, it is safe to assume that CGWindowID is preserved between sleep/wake cycles. We do all our matching based on this.

We track sleep/wake state with a single flag:
- `screensAsleep` (bool): true between `screensDidSleepNotification` and completion of the wake pipeline.

When `screensAsleep = true`, we ignore all external events (workspace notifications, display changes, window lifecycle events). This prevents AX errors during the wake => sleep transition from incorrectly pruning window references. [workaround #1]

## Going to sleep

Triggered by: `NSWorkspace.screensDidSleepNotification`.

Set `screensAsleep = true` and *cancel all pending validation retries* elsewhere in the code. (We also cancel any timers related to wake functionality to avoid potential issues.)

## Waking up

Triggered by: `NSWorkspace.screensDidWakeNotification`.

When we receive this notifications, it's still possible that the screen is not ready and things like _AXUIElementGetWindow will err. We will wait for the following check to pass:
    - Is the Display Asleep? (CGDisplayIsAsleep) => must not be
    - Is the Screen Locked? (CGSSessionScreenIsLocked) => must not be
We poll at 0.5 increments until this passes. [workaround #2]

Now our big picture goal is to minimize the windows on screen that were possibly disconnected during sleep. We recompute the current screen topology (e.g., via `NSScreen.screens` / `screenContextStore` rebuild). A screen is considered a *remaining* screen if it still exists. If there is no intersection between pre-sleep and post-wake screens, then all eligible windows will be minimized.

For eligible applications (using normal rules):  // Fresh enumeration
    - For every eligible window A (using normal rules):
        - If A *isn't* in a zone of one of the *remaining* screens:
            - If A isn't minimized, minimize it (this is intentionally aggressive to keep the screen clean, even for newly-created windows)
        - Else: // if A *is* in a zone of one of the remaining screens
            - Mark A as "restored"

During the above application/window enumeration loop, as soon as we detect that all windows in all zones on all *remaining* screens have been marked as "restored"
OR if the loop finishes:
    syncWindowsToZones()
    set screensAsleep = false

Note that we always complete the loop in order to minimize the windows we don't want. The goal of the early `syncWindowsToZones()` is to get the UI to look good as soon as possible.

Note: if we complete the above loop, and there are still some windows in some zones in remaining screens that have not been marked as "restored", they will be purged from our internal representation when `syncWindowsToZones()` runs. This is intentional; we do not perform a later reconciliation pass.
