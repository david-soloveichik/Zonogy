# Zonogy Regression Notes

Use this file as a pre-change checklist for tricky behaviors that have previously regressed.
Each entry is a brief bug report plus something an LLM should be sure to think about to avoid regressing when editing related code.
Keep entries short and concrete as the LLM should be able to figure the rest out when guided in this way.

- Bug report: Sometimes if window A is in a tiling zone and window B is in temporary zone, then minimizing A also minimizes B.
  - Think about: Focus/activation and sync can race.

- Bug report: If a managed tiled window is manually resized larger, zone resize bars can remain drawn over the active window.
  - Think about: Refresh resize-handle descriptors on non-programmatic resize notifications, and keep overlap clipping/hiding rules in one pure policy helper that covers all tiling zones.

- Bug report: After sleep/wake or screen-change recapture, a pruned window can be re-placed from stale recapture state, leaving a tiling zone falsely occupied and routing subsequent windows into the temporary zone.
  - Think about: Recapture placement must revalidate candidate IDs against the live registry, and sync must clear any zone occupant IDs with no managed window.

- Bug report: Restoring a WinShot snapshot with an empty tiling zone can leave that zone without its placeholder because restore sync ran before removing windows that should be absent.
  - Think about: WinShot restore must remove/minimize non-snapshot windows before its sync pass so placeholder reconciliation sees the final occupancy state.

- Bug report: Launcher auto-show can close almost immediately because focus-based dismissal races the panel open.
  - Think about: Preserve a real post-open grace window and/or require unmanaged-focus state to stabilize (short debounce or repeated confirmation) before dismissing.

- Bug report: Sleep/wake can leave delayed retries or timers running into AX-not-ready periods, causing false window pruning or other incorrect lifecycle actions.
  - Think about: Route sleep-sensitive timer/work-item cancellation through `cancelSleepSensitiveAsyncWork(reason:)` (in `AppController+SleepWake.swift`), and only resume AX-dependent work after wake readiness gates are satisfied.

- Bug report: Launcher app-list cache can refresh in the background while the Launcher is open, but the visible list stays stale until close/reopen.
  - Think about: Before reloading launcher cache, either dismiss an active Launcher or explicitly refresh live Launcher state; keep one consistent approach across manual and automatic reload paths.
