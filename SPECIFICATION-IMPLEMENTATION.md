# Implementation Details

## Destroyed Window Detection

Not all applications emit didTerminateApplication notification upon closing (eg Find My). So we need to also monitor other notifications. Specifically, we do the following:

After events such as application termination, workspace focus changes, or accessibility notifications, `AppController` validates every affected PID. An external window is removed immediately when either the window server stops reporting its `CGWindowNumber` or the accessibility element returns an invalid-element error. If the initial pass finds no destroyed windows but the PID still owns managed windows, the controller schedules a short series of PID-scoped revalidations with exponential backoff (≈0.2 s → 3.2 s). Retries cancel as soon as every window disappears or the process exits; no global polling timer runs.

## Temporary Zone Protection Windows

When a window is placed in the temporary zone, it receives a 0.7-second protection window during which focus-shift events will not minimize it. If a spurious focus event occurs during this window (e.g., macOS activating a sibling window after the displaced occupant is minimized), the temporary zone occupant is reactivated to maintain the invariant that it remains the active window. This prevents a newly placed window from being immediately dismissed.

The same protection mechanism applies when restoring layouts from sleep/wake recovery or WinShot snapshots, so that internal restore operations do not fight normal layout behavior.

For ActiveFit candidate zones during restore, we temporarily suppress ActiveFit during the restore layout pass and then evaluate it once for the active window after the restore settles.

## Debounced Temporary Zone Minimization

When a window is replaced in the temporary zone, the displaced window is queued for deferred minimization rather than minimized immediately. The queue flushes after a 150ms pause with no new additions. This batches rapid replacements together (e.g., when launching an app that opens multiple windows in quick succession), leading to faster behavior and fixing some apparent bugs. If a queued window is reassigned to any zone before the timer fires, it is removed from the queue.

## Additional Notes

- `window_id`s should be monotonically increasing so logs stay unique; do not recycle identifiers after a window closes.
- When `NSWorkspace` reports that an application terminated, immediately drop every managed window for that pid and resync so placeholders reappear in vacated zones.
- We add a simple logging utility (e.g., `Logger.debug(_:)`) used by controllers so we can trace zone transitions and window lifecycle without attaching Xcode.
- Debug toggles (file logging + debug rectangles) live in Preferences → Debug, default off, and apply immediately; time-travel capture remains shortcut-driven and independent of those toggles.
**Log monitoring tip:** To watch the live log output, run:
`swift run 2>&1 | grep --line-buffered "keyword"`.
- **Notification suppression:** When Zonogy programmatically minimizes specific windows (e.g., bulk clear/reset, displacement, startup pruning), it suppresses only the *next* `AXWindowMiniaturized` notification for those window IDs (one-shot) with a safety timeout (~3s). When restoring WinShot snapshots, it also suppresses only the *next* `AXWindowDeminiaturized` notification for the restored external windows that are being unminimized and pre-positioned as part of the snapshot. Other windows remain unaffected and user-triggered actions still get through.
(`grep --line-buffered` streams matching lines without delay.)

## Accessibility API Workarounds

### Retry Mechanisms Tied to Accessibility

Zonogy uses four narrowly scoped retry mechanisms to cope with AX timing and consistency issues: three are PID/application-scoped and one is per window. All of them are tied to concrete events (no global polling loops) and are explicitly cancelled when they are no longer needed or when the system goes to sleep.

- **(Per-application) destroyed-window validation retries (PID-scoped):** After AX-relevant lifecycle events (window focus changes, application activation/deactivation/hide, screen-topology changes), `ValidationRetryManager` schedules a short series of PID-scoped validation passes (≈0.2–3.2s backoff) when AX-based destroyed-window detection is inconclusive. These retries are cancelled when the process exits, when all windows are pruned, or when screens go to sleep (`handleScreensDidSleep` calls `cancelAllValidationRetries()`). See also "Destroyed Window Detection" above for a fuller description of this pipeline.
- **(Per-application) AX window-capture retries (PID-scoped):** When `AXWindowCreated` notifications fail to yield a manageable window (e.g., transient AX errors), `WindowCapturePipeline` schedules a small number of delayed recapture attempts per PID using `cancelAllRetries()` to tear them down when captures succeed, the app exits, or the system goes to sleep.
- **(Per-window) AX frame application retries:** When zone-frame application via AX fails (`Failed to set frame for window`) or the post-apply result remains off-screen/far from the requested geometry, `WindowController` schedules a series of delayed frame retries per window with progressive backoff (≈0.25–3.0s). Each attempt re-reads the current frame and stops early if it already matches the target. These retries only address transient AX failures; permanent size mismatches (e.g., minimum-width windows) are handled by ActiveFit instead. The `onlyWhenOffscreen` policy prevents retries from firing when the window is already within visible bounds, which is what keeps this mechanism from interfering with ActiveFit's reveal-mode positioning. These per-window retries are cancelled whenever zone topology/geometry changes, when screens go to sleep, or when a window becomes managed by ActiveFit, so no stale frame targets are applied later.
- **(Per-application) unmanaged-focus resolution retries (PID-scoped):** This pipeline is used only for UI suppression decisions on the focused screen (zone resize bars and Launcher auto-show/dismiss), so Zonogy does not draw interactive chrome over an unrelated focused window. The classifier is tri-state: `managed`, `confirmed unmanaged`, or `unresolved`. We only suppress UI when focus is `confirmed unmanaged` by non-`CGWindowID` management criteria (or bundle-ignore policy). If focus is unresolved (including transient `_AXUIElementGetWindow` failures), we treat it as managed for suppression purposes and retry with PID-scoped exponential backoff (≈0.2–3.2s). Retries are cancelled when focus resolves, the frontmost PID changes, or screens sleep.

### User vs programmatic move/resize attribution

AX move/resize notifications (`kAXMovedNotification`, `kAXResizedNotification`) do not indicate whether the change was triggered by:

- the user (dragging the window or its resize handles),
- the application itself (internal panels, layout updates), or
- Zonogy (zone alignment, restores, pre-positioning).

Zonogy handles this with two complementary mechanisms:

- **Programmatic-update suppression:** When Zonogy resizes a window, `WindowController` tags that window as "programmatic" for a short time and ignores the resulting AX moved/resized notifications. This prevents feedback loops where reacting to our own move/resize would cause additional move/resize attempts.
- **Gesture heuristics for non-programmatic AX events:**
  - **Moves / drags:** An AXMoved burst is treated as a user drag only if the left mouse button is down and the pointer moves beyond a small activation threshold. Drag end is detected via mouse-up monitoring. This avoids treating incidental or app-driven moves as a drag-and-drop gesture.
  - **Resizes:** For most apps, any non-programmatic AXResized is treated as a completed manual resize and the window is marked "detached" until focus loss or the next layout sync. For apps that opt into `snapToZoneOnSelfResize`, Zonogy attempts to recognize user edge-drag resizes (cursor near the window border plus left-mouse down or a very recent mouse-up grace window).

This attribution work is used by:

- the drag-and-drop pipeline for moving windows between zones (showing overlays, choosing drop targets, finalizing on mouse-up),
- deferring placement during tab tear-out flows while the user is mid-drag,
- manual resize detachment + snapback on focus loss/layout sync, and
- app-specific self-resize snap-to-zone behavior (e.g., Zoom panels) without fighting deliberate user resizes.

### Window subrole for minimized windows

Some applications report the subrole for their minimized windows as AXDialogSubrole even if it later becomes kAXStandardWindowSubrole upon un-minimization. So for enumeration of windows to manage, we don't check subrole for minimized windows.

### Async unminimize after pre-positioning ("pre-move" feature)

When unminimizing a window that needs to appear at a specific position (e.g., restoring a WinShot snapshot or selecting a minimized window from Launcher), we first set the window's position and size while the window is still minimized. However, if we unminimize synchronously right after setting position/size, the window sometimes visually appears at its old location before snapping to the correct position. To address this, we default to async mode for unminimization.

### Temporary zone activation workaround

When placing a window into the temporary zone, the window may fail to receive focus and appear behind tiled windows. Since the temporary zone floats above tiled zones, this is the only placement where another window can obscure the placed window. The workaround (in `activateTemporaryZoneWindow`) is to call `NSApp.activate(ignoringOtherApps: true)` to activate Zonogy first, then yield to the run loop via `DispatchQueue.main.async` before calling `app.activate()` and `kAXRaiseAction`.

### Full-screen window detection

Zonogy detects native macOS full-screen windows using the (undocumented)`AXFullScreen` accessibility attribute. This is the same basic approach used by yabai and alt-tab-macos (although they have some additional workarounds).

We listen to `kAXResizedNotification` which fires when windows enter/exit full-screen mode, and query the `AXFullScreen` attribute via `AXUIElementCopyAttributeValue`. We use 250ms debounce. (Of course, we also handle window closure and app termination.)

At startup (after window capture) and after display reconfiguration, we also iterate all managed windows and check their `AXFullScreen` attribute.

We also re-scan full-screen state after active Space changes, since some apps (e.g., Safari video) don't emit resize events for their full-screen windows. This rescan is debounced (250ms) and uses the same `AXFullScreen` query pipeline.

As fallback when `AXFullScreen` is absent or unreliable: for managed apps with exception `treatAXUnknownFullWidthAsFullScreen`: for windows whose AX subrole is `AXUnknown` (some presentation-style windows like Keynote full-screen), we treat them as full-screen if their accessibility frame width matches the screen width exactly.
