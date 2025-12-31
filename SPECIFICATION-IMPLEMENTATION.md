# Implementation Details

## Destroyed Window Detection

Not all applications emit didTerminateApplication notification upon closing (eg Find My). So we need to also monitor other notifications. Specifically, we do the following:

After events such as application termination, workspace focus changes, or accessibility notifications, `AppController` validates every affected PID. An external window is removed immediately when either the window server stops reporting its `CGWindowNumber` or the accessibility element returns an invalid-element error. If the initial pass finds no destroyed windows but the PID still owns managed windows, the controller schedules a short series of PID-scoped revalidations with exponential backoff (≈0.2 s → 3.2 s). Retries cancel as soon as every window disappears or the process exits; no global polling timer runs.

## Restore Protection Windows (WinShot + Sleep/Wake)

When restoring layouts from either sleep/wake recovery or WinShot snapshots, we apply a short protection window so that internal restore operations do not fight normal layout behavior:

- The floating temporary-zone occupant is temporarily protected from auto-minimization triggered by focus shifts or new tiled placements on the same screen, so it is not immediately cleared while other windows are being recaptured.
- For ActiveFit candidate zones, we temporarily suppress ActiveFit during the restore layout pass and then evaluate it once for the active window after the restore settles. The active window is first restored to its zone-aligned frame; if it no longer fits there, a later ActiveFit pass may snap it into a reveal position.

## Additional Notes

- `window_id`s should be monotonically increasing so logs stay unique; do not recycle identifiers after a window closes.
- When `NSWorkspace` reports that an application terminated, immediately drop every managed window for that pid and resync so placeholders reappear in vacated zones.
- We add a simple logging utility (e.g., `Logger.debug(_:)`) used by controllers and REPL commands so we can trace zone transitions and window lifecycle without attaching Xcode.
**Log monitoring tip:** To watch the live log output, run:
`stdbuf -oL -eL swift run 2>&1 | grep --line-buffered "keyword"`.
- **Notification suppression:** When Zonogy programmatically minimizes specific windows (e.g., bulk clear/reset, displacement, startup pruning), it suppresses only the *next* `AXWindowMiniaturized` notification for those window IDs (one-shot) with a safety timeout (~3s). When restoring WinShot snapshots, it also suppresses only the *next* `AXWindowDeminiaturized` notification for the restored external windows that are being unminimized and pre-positioned as part of the snapshot. Other windows remain unaffected and user-triggered actions still get through.
(`stdbuf` makes `swift run` flush each line immediately, and `grep --line-buffered` streams matching lines without delay.)
- The REPL keeps running until the process is terminated so we can script scenarios by piping command sequences (`printf "add-zone\nlist\n" | ./Zonogy`). Retain this interface in later stages for regression testing even once real-window integration is added.

## Accessibility API Workarounds

### Retry Mechanisms Tied to Accessibility

Zonogy uses three narrowly scoped retry mechanisms to cope with AX timing and consistency issues: two are PID/application-scoped and one is per window. All of them are tied to concrete events (no global polling loops) and are explicitly cancelled when they are no longer needed or when the system goes to sleep.

- **(Per-application) destroyed-window validation retries (PID-scoped):** After AX-relevant lifecycle events (window focus changes, application activation/deactivation/hide, screen-topology changes, REPL/socket "validate" commands), `ValidationRetryManager` schedules a short series of PID-scoped validation passes (≈0.2–3.2s backoff) when AX-based destroyed-window detection is inconclusive. These retries are cancelled when the process exits, when all windows are pruned, or when screens go to sleep (`handleScreensDidSleep` calls `cancelAllValidationRetries()`). See also "Destroyed Window Detection" above for a fuller description of this pipeline.
- **(Per-application) AX window-capture retries (PID-scoped):** When `AXWindowCreated` notifications fail to yield a manageable window (e.g., transient AX errors), `WindowCapturePipeline` schedules a small number of delayed recapture attempts per PID using `cancelAllRetries()` to tear them down when captures succeed, the app exits, or the system goes to sleep.
- **(Per-window) AX frame application retries:** When applying a zone-aligned frame via AX leaves a window off-screen or far from the requested geometry, `WindowController` schedules a one-shot delayed frame retry for that window. These per-window timers are cancelled whenever zone topology/geometry changes or when screens go to sleep so no stale frame targets are applied later.

### Window subrole for minimized windows

Some applications report the subrole for their minimized windows as AXDialogSubrole even if it later becomes kAXStandardWindowSubrole upon un-minimization. So for enumeration of windows to manage, we don't check subrole for minimized windows.

### Async unminimize after pre-positioning ("pre-move" feature)

When unminimizing a window that needs to appear at a specific position (e.g., restoring a WinShot snapshot or selecting a minimized window from Launcher), we first set the window's position and size while the window is still minimized. However, if we unminimize synchronously right after setting position/size, the window sometimes visually appears at its old location before snapping to the correct position. To address this, we default to async mode for unminimization.
