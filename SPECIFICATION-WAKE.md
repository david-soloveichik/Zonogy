# Sleep / Wake Behavior

Our big picture goal is to protect window identity while the Accessibility API is unreliable during screen sleep and while the login screen is active. After physical sleep, we also minimize windows on screens that were possibly disconnected and readjust screen and zone topology.

IMPORTANT: This specification does not mention logging. It is expected that the implementation will decide on which information needs to be logged and when.

IMPORTANT TERMINOLOGY: When we say "window" this refers to managed windows of other applications. To refer to placeholder windows, we explicitly say "placeholder [window]". When we say "zone" without a qualifier, we mean either a tiling zone or a floating zone. An empty zone contains a placeholder window.

Based on testing, it is safe to assume that `CGWindowID` is preserved between sleep/wake cycles. We do all our matching based on this.

We track sleep/wake protection with `sleepWakeProtectionActive` (bool). It becomes true when either `screensDidSleepNotification` arrives or `loginwindow` becomes frontmost, and remains true until the wake pipeline completes. A separate `loginWindowIsActive` flag remembers whether the login screen initiated or overlaps the protected interval.

When `sleepWakeProtectionActive = true`, we ignore all external events (workspace notifications, display changes, window lifecycle events, and AX observer notifications such as focus changes). AX observer notifications can continue for several hundred milliseconds after the sleep notification; processing them could start validation or other AX-dependent work while AX is unreliable. Every delegate method that handles AX events must check `sleepWakeProtectionActive` and return early if true.

As long as `sleepWakeProtectionActive = true` we also "dim" the menu bar item for better user feedback (I know it's ironic since you might think that the screens would be asleep and the user won't see it, but screensDidWakeNotification might fire while the API is not completely ready as described below.)

## Context

Every non-empty zone saves the `CGWindowID` of the window it contains, and the corresponding process `pid`.

## Going to sleep

Triggered by either:

- `NSWorkspace.screensDidSleepNotification`.
- `loginwindow` (`com.apple.loginwindow`) becoming frontmost. Because workspace notifications can arrive out of order, check the current frontmost application before processing regular-application activation, deactivation, or hide events, and enter protection immediately when it is `loginwindow`.

Set `sleepWakeProtectionActive = true` and cancel all pending timers/work items that perform AX operations or window management:

- Validation retries (destroyed-window detection)
- Wake readiness timer
- Accessibility frame retries
- Window capture retries
- Screen-change recapture timers
- Screen-change debounce timer

This prevents timers scheduled just before sleep from firing during sleep when AX APIs are unavailable.

## Waking up

Triggered by either `NSWorkspace.screensDidWakeNotification` or `loginwindow` ceasing to be active. The returning regular application's activation can arrive before the `loginwindow` deactivation notification; either event starts the same readiness polling.

When we receive these notifications, the screen may still be unready and calls such as `_AXUIElementGetWindow` may fail. Wait for the following checks to pass:
    - Is the Display Asleep? (CGDisplayIsAsleep) => must not be
    - Is the Screen Locked? (CGSSessionScreenIsLocked) => must not be
    - Does `NSWorkspace.shared.frontmostApplication` return a non-`loginwindow` application? => must be yes (uses NSWorkspace instead of AX because AX can hang indefinitely with some apps during wake recovery)
We poll at 0.5 increments until this passes. At this point we assume that AX API is ready.

Set `sleepWakeProtectionActive = false` and undim the menu bar icon.

Finally do the same thing that happens during "screen-change recapture" (re-use same code). Window liveness and recovery follow the general rules in SPECIFICATION-IMPLEMENTATION.md § Deferred Pruning. Tracked-but-unzoned windows are placed only when the recapture pass revalidates them as live; stale tracked records remain unplaced.
