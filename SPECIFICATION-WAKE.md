# Sleep / Wake Behavior

Our big picture goal is to minimize the windows on screens that were possibly disconnected during sleep. We also need to readjust screen/zones topology.

IMPORTANT: This specification does not mention logging. It is expected that the implementation will decide on which information needs to be logged and when.

IMPORTANT TERMINOLOGY: When we say "window" this refers to managed windows of other applications. To refer to placeholder windows, we explicitly say "placeholder [window]". When we say "zone" without a qualifier, we mean either a normal (tiling) zone, or a temporary zone. An empty zone contains a placeholder window.

Based on testing, it is safe to assume that `CGWindowID` is preserved between sleep/wake cycles. We do all our matching based on this.

We track sleep/wake state with a single flag: `screensAsleep` (bool): true between `screensDidSleepNotification` and completion of the wake pipeline. When `screensAsleep = true`, we ignore all external events (workspace notifications, display changes, window lifecycle events). This prevents AX errors during the wake => sleep transition from incorrectly pruning window references.

As long as `screensAsleep = true` we also "dim" the menu bar item for better user feedback (I know it's ironic since you might think that the screens would be asleep and the user won't see it, but screensDidWakeNotification might fire while the API is not completely ready as described below.)

## Context

Every non-empty zone saves the `CGWindowID` of the window it contains, and the corresponding process `pid`.

## Going to sleep

Triggered by: `NSWorkspace.screensDidSleepNotification`.

Set `screensAsleep = true` and *cancel all pending validation retries* elsewhere in the code. We also cancel any timers described below related to wake functionality to avoid potential issues for very short wake=>sleep cycles.

## Waking up

Triggered by: `NSWorkspace.screensDidWakeNotification`.

When we receive this notifications, it's still possible that the screen is not ready and things like `_AXUIElementGetWindow` will err. We will wait for the following checks to pass:
    - Is the Display Asleep? (CGDisplayIsAsleep) => must not be
    - Is the Screen Locked? (CGSSessionScreenIsLocked) => must not be
    - Is there an active application returned by AX API? => must be yes
We poll at 0.5 increments until this passes.

We then recompute the current screen topology (e.g., via `NSScreen.screens` / `screenContextStore` rebuild). A screen is considered a *remaining* screen if it still exists. If there is no intersection between pre-sleep and post-wake screens, then all eligible windows will be minimized.

At this point we still don't quite trust AX API to be fully ready and `_AXUIElementGetWindow` to work. If we prematurely call `syncWindowsToZones()`, it will consider these windows not managed and we'll lose track of them. So we confirm that none of the managed windows in remaining screens give `_AXUIElementGetWindow` error as described in A:

A.
Collect all `CGWindowID` and pid of all managed windows in all zones in all *remaining* screens.
For each pid in this list:
    - For every eligible window (using normal rules):
        - If `_AXUIElementGetWindow` returns the `CGWindowID` of one of the collected windows, mark that window as "restored".
If there are still un-restored windows in the list, repeat A in 0.5 increments for a max of 5 seconds. (We give up after 5s.)

At this point, we assume the AX API is ready and we minimize the windows we don't want and call `syncWindowsToZones()` as described in B and C:

B.
For eligible applications (using normal rules):  // Fresh enumeration
    - For every eligible window W (using normal rules):
        - If W *isn't* in a zone of one of the *remaining* screens: // Can use collection from part A
            - If W isn't minimized, minimize it (this is intentionally aggressive to keep the screen clean, even for newly-created windows)

C.
syncWindowsToZones()
set screensAsleep = false and undim the menubar icon
