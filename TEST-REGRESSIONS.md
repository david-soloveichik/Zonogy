# Zonogy Regression Notes

Use this file as a pre-change checklist for tricky behaviors that have previously regressed.
Each entry is a brief bug report plus something an LLM should be sure to think about to avoid regressing when editing related code.
Keep entries short and concrete as the LLM should be able to figure the rest out when guided in this way.

- Bug report: Sometimes if window A is in a tiling zone and window B is in floating zone, then minimizing A also minimizes B.
  - Think about: Focus/activation and sync can race.

- Bug report: If a managed tiled window is manually resized larger, zone resize bars can remain drawn over the active window.
  - Think about: Refresh resize-handle descriptors on non-programmatic resize notifications, and keep overlap clipping/hiding rules in one pure policy helper that covers all tiling zones.

- Bug report: After zone resizing, the Codex window can "jump" toward an older zone position a moment later.
  - Think about: Delayed AX frame retries can outlive newer retargeted moves; cancel/invalidate stale retry chains on retarget and guard retry work items so replaced chains cannot execute.

- Bug report: A newly created window (eg Chrome) routed into zone 2/3 can enter ActiveFit reveal mode before it resizes to the zone size, leaving it not filling the zone.
  - Think about: Entering reveal mode calls moveWindow which cancels the pending frame retry chain. ActiveFit must skip reveal evaluation when a frame retry is pending and re-evaluate when the retry settles.

- Bug report: After sleep/wake or screen-change recapture, a pruned window can be re-placed from stale recapture state, leaving a tiling zone falsely occupied and routing subsequent windows into the floating zone.
  - Think about: Recapture placement must revalidate candidate IDs against the live registry, and sync must clear any zone occupant IDs with no managed window.

- Bug report: Restoring a WinShot snapshot with an empty tiling zone can leave that zone without its placeholder because restore sync ran before removing windows that should be absent.
  - Think about: WinShot restore must remove/minimize non-snapshot windows before its sync pass so placeholder reconciliation sees the final occupancy state.

- Bug report: Launcher auto-show can close almost immediately because focus-based dismissal races the panel open.
  - Think about: Preserve a real post-open grace window and/or require unmanaged-focus state to stabilize (short debounce or repeated confirmation) before dismissing.

- Bug report: Holding Control-Command after an external drag stops moving can show the intercepted zone overlay, but releasing without another mouse move drops nothing.
  - Think about: `flagsChanged` alone must not arm the intercepted overlay. Only a subsequent drag move should promote to Control-Command interception; otherwise keep the stationary UI truthful (including leaving empty-zone placeholder behavior unchanged).

- Bug report: Sleep/wake can leave delayed retries or timers running into AX-not-ready periods, causing false window pruning or other incorrect lifecycle actions.
  - Think about: Route sleep-sensitive timer/work-item cancellation through `cancelSleepSensitiveAsyncWork(reason:)` (in `AppController+SleepWake.swift`), only resume AX-dependent work after wake readiness gates are satisfied, and keep sync-pruned windows in deferred-prune bookkeeping long enough to restore the same `windowId` if the same pid/CGWindowID reappears.

- Bug report: Launcher app-list cache can refresh in the background while the Launcher is open, but the visible list stays stale until close/reopen.
  - Think about: Keep reload behavior consistent across manual and automatic paths, and refresh live Launcher app-list state in place (without dismissing) when cache reload completes.

- Bug report: Placing a window into zone 2/3 can visibly flicker (rest-position move(s) before reveal).
  - Think about: Avoid immediate duplicate geometry writes for a just-placed window before ActiveFit reveal applies.

- Bug report: WinShot restore can leave the active window behind other restored windows.
  - Think about: Async unminimize animations complete after the active window's AXRaise; re-raise the active window when each suppressed deminiaturize notification arrives.

- Bug report: When a Sticky Resize window is activated in a right-column zone, one focus-related notification can restore its remembered size at the zone origin and ActiveFit can then shift it into reveal mode, but a second focus/main-window notification can move it back to the rest-position origin while ActiveFit still thinks the window is already revealed. The result is that the window stays at the rest position and hangs off-screen even though ActiveFit state says reveal mode is active.
  - Fixed by: Reusing cached ActiveFit reveal state only when the window's actual current frame still matches the stored reveal frame; otherwise ActiveFit reapplies the reveal move instead of returning early.

- Bug report: Activating another app can focus a managed window without delivering an AXFocusedWindowChanged event for the arriving app.
  - Think about: Mirror the Sticky Resize restore path from NSWorkspace activation when a tracked focused managed window is already known.
  
