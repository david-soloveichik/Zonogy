# Implementation Details

## Destroyed Window Detection

Beyond the self-evident path of app termination (which removes all windows for that PID immediately), Zonogy uses several mechanisms to detect individual window destruction. Not all applications emit `didTerminateApplication` or AX destroy notifications (e.g., Find My) so we need to cast a wider net. The sync-based mechanisms detect a window as destroyed when its `(pid, CGWindowID)` is missing from `CGWindowListCopyWindowInfo`, or its `AXUIElement` returns `.invalidUIElement`/`.cannotComplete`/`.illegalArgument` when probed.

- **Per-PID validation with retry (`ValidationRetryManager`):** After window focus changes within an app, app switches (validates the previous app), and app deactivation/hide, runs a PID-scoped check. If no destroyed windows are found but the PID still has managed windows (i.e., AX may be temporarily stale), retries with exponential backoff (≈0.2–3.2 s). This tries to catch window closed as soon as possible so that its zone is emptied and UI updates.

- **Zone sync pruning:** Every full `syncWindowsToZones()` checks all managed windows. Full syncs run frequently — after zone add/remove, window placement, miniaturize/deminiaturize, drag-drop, screen-topology changes, WinShot/Launcher operations, and other layout-affecting events.

### Deferred Pruning

All window removal paths **except app termination** use deferred pruning: instead of immediately discarding the window's identity and recency info, the window is staged in a pending-prune store keyed by `(pid, CGWindowID)`. The zone is vacated immediately (placeholder appears), but the bookkeeping is retained. This guards against false positives from transient AX unavailability (e.g., sleep/wake, screen topology changes, or spurious `AXUIElementDestroyed` notifications macOS can emit near sleep).

- **Recovery:** If the same `(pid, CGWindowID)` reappears during a subsequent capture pass, the window is restored with its original `windowId` and recency timestamp, and placed back into its original zone (if that zone is still empty) or through the normal placement pipeline otherwise.
- **Clearing:** Pending-prune entries for a PID are discarded when (1) the app terminates, or (2) a *new* managed window (different `CGWindowID`) is discovered for that PID, which signals that the old windows are truly gone.

## Floating Zone Protection Windows

When a window is placed in the floating zone, it receives a 0.5-second protection window during which focus/front-most changes will not trigger occlusion-based floating-zone minimization. If a spurious focus event occurs during this window (e.g., macOS activating a sibling window after the displaced occupant is minimized), the floating-zone occupant is reactivated/raised so it remains visible and interactive. This prevents a newly placed window from being immediately dismissed.

The same protection mechanism applies when restoring layouts from sleep/wake recovery or WinShot snapshots, so that internal restore operations do not fight normal layout behavior.

For ActiveFit candidate zones during restore, we temporarily suppress ActiveFit during the restore layout pass and then evaluate it once for the active window after the restore settles.

## Occlusion-Based Floating Zone Minimization

When a managed window assigned to a tiling zone becomes front-most on a screen, Zonogy checks whether that screen’s floating-zone occupant is occluded by that occupied tiling zone. If it is occluded, minimize the floating window; otherwise leave it unminimized. If a placeholder becomes front-most and its tiling zone's frame overlaps the floating-zone occupant, promote the floating window into that placeholder’s tiling zone instead of minimizing it.

Implementation notes:

- Determine which windows are “in front” via `CGWindowListCopyWindowInfo` ordering (on-screen windows), using `CGWindowID` for stable identity.
- Trigger the occlusion check after the deferred-minimization debounce (~150ms) so window z-order has time to settle after activation/focus changes.
- Define occlusion as: at least one in-front occupied tiling zone's frame intersects the floating window’s bounds by more than a tiny threshold; ignore small overlaps (e.g., window shadows) to avoid false positives. Do not use the tiling window’s current bounds for this test, so ActiveFit reveal mode or other temporary drift outside the zone frame does not change the occlusion region.

## Debounced Floating Zone Minimization

When a window is replaced in the floating zone, the displaced window is queued for deferred minimization rather than minimized immediately. The queue flushes after a 150ms pause with no new additions. This batches rapid replacements together (e.g., when launching an app that opens multiple windows in quick succession), leading to faster behavior and fixing some apparent bugs. If a queued window is reassigned to any zone before the timer fires, it is removed from the queue.

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

### Follows-focus activation settlement

In follows-focus mode, treat `NSWorkspace.didActivateApplication` as provisional. If the app's currently focused managed window is in a different destination than the current target, preserve the current target for a short settlement window instead of retargeting immediately.

If a new managed window for that app is captured during that settlement window, place it into the preserved target. If no new managed window appears and the target has not changed for some other reason, retarget to the app's settled focused window when the settlement window ends.

### Empty-zone retarget protection

In follows-focus mode, minimizing or closing a tiled window can immediately cause the app to focus a sibling window. Treat that sibling focus as provisional when it is just the fallback from the same emptying action: preserve the emptied zone's target rather than letting that fallback focus steal it.

This protection is narrower than the app-activation settlement above. It is tied to the specific fallback sibling window expected to receive the automatic focus after the removed window disappears, and it exists only long enough for the normal recency-based follows-focus rule to take over. If focus later moves to a different window, normal follows-focus retargeting resumes. Manual targeting actions still override immediately.

### Retry Mechanisms Tied to Accessibility

Zonogy uses five narrowly scoped retry/verification mechanisms to cope with AX timing and consistency issues: three are PID/application-scoped and two are per window. All of them are tied to concrete events (no global polling loops) and are explicitly cancelled when they are no longer needed or when the system goes to sleep.

- **(Per-application) destroyed-window validation retries (PID-scoped):** After AX-relevant lifecycle events (window focus changes, application activation/deactivation/hide), we schedule a short series of PID-scoped validation passes (≈0.2–3.2s backoff) when AX-based destroyed-window detection is inconclusive (see "Destroyed Window Detection" above). These retries are cancelled when the process exits, when all windows are pruned, or when screens go to sleep (`handleScreensDidSleep` calls `cancelAllValidationRetries()`).
- **(Per-application) AX window-capture retries (PID-scoped):** When `AXWindowCreated` notifications fail to yield a manageable window (e.g., transient AX errors), `WindowCapturePipeline` schedules a small number of delayed recapture attempts per PID using `cancelAllRetries()` to tear them down when captures succeed, the app exits, or the system goes to sleep.
- **(Per-window) AX frame application retries:** When Zonogy tries to move/resize a window to its zone frame and the AX call fails or the window’s origin doesn’t match the target, `WindowController` retries with backoff (≈0.25–3.0s). Retries stop once the window’s position (origin) matches the target, regardless of size differences or screen overflow (e.g., a min-width window that can’t shrink to the zone width is fine as long as it’s positioned correctly). Retry chains are cancelled when zone geometry changes, screens go to sleep, or a new `moveWindow` call supersedes the old target. **ActiveFit interaction:** When the retry chain settles, `WindowController` notifies `AppController` via `frameRetryDidSettle`, which evaluates whether ActiveFit reveal mode is needed for zone 2/3 windows.
- **(Per-application) unmanaged-focus resolution retries (PID-scoped):** This pipeline is used only for UI suppression decisions on the focused screen (zone resize bars and Launcher auto-show/dismiss), so Zonogy does not draw interactive chrome over an unrelated focused window. The classifier is tri-state: `managed`, `confirmed unmanaged`, or `unresolved`. We only suppress UI when focus is `confirmed unmanaged` by non-`CGWindowID` management criteria (or bundle-ignore policy). If focus is unresolved (including transient `_AXUIElementGetWindow` failures), we treat it as managed for suppression purposes and retry with PID-scoped exponential backoff (≈0.2–3.2s). Retries are cancelled when focus resolves, the frontmost PID changes, or screens sleep.
- **(Per-window) programmatic minimize verification (window-scoped):** For bulk programmatic minimize flows (especially WinShot restore and clear/reset-zones actions), Zonogy should not assume an AX minimize request "stuck" just because the AX call returned success. Some apps (eg Word) may change focus/activate sibling windows during a minimize burst, causing one requested minimize to be undone or ignored. After issuing each programmatic minimize, perform a short delayed AX-state verification (and one retry on failure) before finalizing cleanup/zone state for that window.

### AXWindowCreated for already-tracked windows (element rebinding)

Some applications can emit `AXWindowCreated` for a window Zonogy already tracks (same PID + `CGWindowID`) (eg Word). In these cases the notification may carry a fresh `AXUIElement` for the same underlying window. Zonogy must treat this as an element-rebind event (update the stored AX element, lookup mapping, and window notification registrations atomically), not as a new-window capture and not as a capture failure.

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

### Floating zone activation workaround

When placing a window into the floating zone, the window may fail to receive focus and appear behind tiled windows. Since the floating zone floats above tiled zones, this is the only placement where another window can obscure the placed window. The workaround (in `activateFloatingZoneWindow`) is to call `NSApp.activate(ignoringOtherApps: true)` to activate Zonogy first, then yield to the run loop via `DispatchQueue.main.async` before calling `app.activate()` and `kAXRaiseAction`.

### Full-screen window detection

Zonogy detects native macOS full-screen windows using the (undocumented)`AXFullScreen` accessibility attribute. This is the same basic approach used by yabai and alt-tab-macos (although they have some additional workarounds).

We listen to `kAXResizedNotification` which fires when windows enter/exit full-screen mode, and query the `AXFullScreen` attribute via `AXUIElementCopyAttributeValue`. We use 250ms debounce. (Of course, we also handle window closure and app termination.)

At startup (after window capture) and after display reconfiguration, we also iterate all managed windows and check their `AXFullScreen` attribute.

We also re-scan full-screen state after active Space changes, since some apps (e.g., Safari video) don't emit resize events for their full-screen windows. This rescan is debounced (250ms) and uses the same `AXFullScreen` query pipeline.

In addition, `AXFullScreen` can remain true for full-screen windows on inactive Spaces. To avoid a stale per-screen "full-screen pause", after space/focus updates we verify the currently focused window: if its display is paused but that focused window does not claim full-screen, we clear the tracked full-screen state for that display.

As fallback when `AXFullScreen` is absent or unreliable: for managed apps with exception `treatAXUnknownFullWidthAsFullScreen`: for windows whose AX subrole is `AXUnknown` (some presentation-style windows like Keynote full-screen), we treat them as full-screen if their accessibility frame width matches the screen width exactly.

---

## Timers

For a complete inventory of all timers and delay mechanisms (AX retries, debounce, protection windows, etc.), see [SPECIFICATION-TIMERS.md](SPECIFICATION-TIMERS.md).
