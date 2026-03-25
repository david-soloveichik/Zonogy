# Sleep / Wake Behavior

Our big picture goal is to minimize the windows on screens that were possibly disconnected during sleep. We also need to readjust screen/zones topology.

IMPORTANT: This specification does not mention logging. It is expected that the implementation will decide on which information needs to be logged and when.

IMPORTANT TERMINOLOGY: When we say "window" this refers to managed windows of other applications. To refer to placeholder windows, we explicitly say "placeholder [window]". When we say "zone" without a qualifier, we mean either a tiling zone or a floating zone. An empty zone contains a placeholder window.

Based on testing, it is safe to assume that `CGWindowID` is preserved between sleep/wake cycles. We do all our matching based on this.

We track sleep/wake state with a single flag: `screensAsleep` (bool): true between `screensDidSleepNotification` and completion of the wake pipeline. 

When `screensAsleep = true`, we ignore all external events (workspace notifications, display changes, window lifecycle events, and AX observer notifications such as focus changes). This prevents AX errors during the sleep transition from incorrectly pruning window references. Also AX observer notifications (e.g., `AXFocusedWindowChanged`, `AXMainWindowChanged`) can fire for several hundred milliseconds after the sleep notification. If processed, these trigger window validation which queries AX APIs that return transient errors during sleep, causing windows to be incorrectly pruned as "destroyed". Every delegate method that handles AX events must check `screensAsleep` and return early if true.

As long as `screensAsleep = true` we also "dim" the menu bar item for better user feedback (I know it's ironic since you might think that the screens would be asleep and the user won't see it, but screensDidWakeNotification might fire while the API is not completely ready as described below.)

## Context

Every non-empty zone saves the `CGWindowID` of the window it contains, and the corresponding process `pid`.

## Going to sleep

Triggered by: `NSWorkspace.screensDidSleepNotification`.

Set `screensAsleep = true` and cancel all pending timers/work items that perform AX operations or window management:

- Validation retries (destroyed-window detection)
- Wake readiness timer
- Accessibility frame retries
- Window capture retries
- Screen-change recapture timers
- Screen-change debounce timer

This prevents timers scheduled just before sleep from firing during sleep when AX APIs are unavailable.

## Waking up

Triggered by: `NSWorkspace.screensDidWakeNotification`.

When we receive this notifications, it's still possible that the screen is not ready and things like `_AXUIElementGetWindow` will err. We will wait for the following checks to pass:
    - Is the Display Asleep? (CGDisplayIsAsleep) => must not be
    - Is the Screen Locked? (CGSSessionScreenIsLocked) => must not be
    - Does `NSWorkspace.shared.frontmostApplication` return non-nil? => must be yes (uses NSWorkspace instead of AX because AX can hang indefinitely with some apps during wake recovery)
We poll at 0.5 increments until this passes. At this point we assume that AX API is ready.

set screensAsleep = false and undim the menubar icon

Finally do the same thing that happens during "screen‑change recapture" (re-use same code). Any windows that were falsely pruned during the sleep transition (due to transient AX unavailability or spurious `AXUIElementDestroyed` notifications) are recovered via the deferred-prune mechanism (see SPECIFICATION-IMPLEMENTATION.md § Deferred Pruning).
