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

When a window is placed in the floating zone, it receives a 0.5-second protection window during which focus/front-most changes will not trigger occlusion-based floating-zone minimization. If a spurious focus event occurs during this window (e.g., macOS activating a sibling window after the displaced occupant is minimized), the floating-zone occupant is reactivated/raised so it remains visible and interactive. This prevents a newly placed window from being immediately dismissed. Exception: if the floating window is currently minimized (per the Accessibility API), the protection-driven re-raise is skipped, so a user who quickly minimizes a just-placed floating window is not fought by a spurious unminimize.

The same protection mechanism applies when restoring layouts from sleep/wake recovery or WinShot snapshots, so that internal restore operations do not fight normal layout behavior.

For ActiveFit candidate zones during restore, we temporarily suppress ActiveFit during the restore layout pass and then evaluate it once for the active window after the restore settles.

## Occlusion-Based Floating Zone Minimization

When a managed window assigned to a tiling zone becomes front-most on a screen, Zonogy checks whether that screen’s floating-zone occupant is occluded by that occupied tiling zone. If it is occluded, minimize the floating window; otherwise leave it unminimized. If a placeholder becomes front-most and its tiling zone's frame overlaps the floating-zone occupant, promote the floating window into that placeholder’s tiling zone instead of minimizing it.

Implementation notes:

- Determine which windows are “in front” via `CGWindowListCopyWindowInfo` ordering (on-screen windows), using `CGWindowID` for stable identity.
- Trigger the occlusion check after the deferred-minimization debounce (~150ms) so window z-order has time to settle after activation/focus changes.
- Define occlusion as: at least one in-front occupied tiling zone's frame intersects the floating window’s bounds by more than a tiny threshold; ignore small overlaps (e.g., window shadows) to avoid false positives. Do not use the tiling window’s current bounds for this test, so ActiveFit reveal mode or other temporary drift outside the zone frame does not change the occlusion region.

## Displacement Minimization Strategy

When a placement displaces an existing zone occupant, Zonogy picks one of two ways to minimize the displaced window:

- **Synchronous** (`DisplacementStrategy.synchronous`): minimize before the incoming window is positioned/raised. Setting `kAXMinimized = true` on a non-frontmost window can produce a brief visual flash of that window before its minimize animation; the exact mechanism isn't certain, but a "brief flash to key window" is a useful mental model. Running the minimize first means the flash happens while the incoming window is still hidden, so the user never sees it. Used by Zonogy-initiated single-window swaps where the source window already exists and no app launch is in flight (Launcher, drag-drop, moves between zones, full-screen exit deferred placements, etc.).
- **Deferred** (`DisplacementStrategy.deferred`): queue the minimize through `DeferredMinimizationCoordinator` (150ms debounce). Used by `placeNewWindow`, the entry point for any "a window arrived" placement (external unminimize/capture, plus internal callers: manual capture, recapture, startup, drag tear-out reassignment). When a launching app is processing its own queue of windows to unminimize, a synchronous minimize would land at the back of that queue and be re-unminimized — an infinite ping-pong. The debounce keeps resetting as arrivals come in, so displaced windows minimize only after the burst settles, by which point they're no longer in the app's queue. Trade-off: the flash artifact can appear over the new occupant, but external-arrival visuals are already imperfect (Zonogy doesn't control the unminimize timing); internal callers accept the same brief glitch to share one loop-safe entry point.

`DeferredMinimizationCoordinator` is also used by occlusion- and focus-driven floating-zone minimization and the floating-zone explicit `minimizeOccupant` path. Queued minimizations are cancelled if the window is reassigned to any zone before the timer fires.

### Loop guard safety net

`MinimizeLoopGuard` catches the rare case where a synchronous-path minimize is rapidly re-unminimized by an app outside any launch burst. When two non-suppressed deminiaturize events arrive within 2 seconds for windows Zonogy programmatically minimized in the previous 0.5 seconds, the guard activates for 3 seconds; while active, `minimizeWindowProgrammatically` routes through the deferred queue regardless of the placement's requested strategy.

## Additional Notes

- `window_id`s should be monotonically increasing so logs stay unique; do not recycle identifiers after a window closes.
- When `NSWorkspace` reports that an application terminated, immediately drop every managed window for that pid and resync so placeholders reappear in vacated zones.
- We add a simple logging utility (e.g., `Logger.debug(_:)`) used by controllers so we can trace zone transitions and window lifecycle without attaching Xcode.
- Debug toggles (file logging + debug rectangles) live in Preferences → Debug, default off, and apply immediately; time-travel capture remains shortcut-driven and independent of those toggles.
**Log monitoring tip:** To watch the live log output, run:
`swift run 2>&1 | grep --line-buffered "keyword"`.
- **Notification suppression:** When Zonogy programmatically minimizes specific windows (e.g., bulk clear/reset, displacement, startup pruning), it suppresses only the *next* `AXWindowMiniaturized` notification for those window IDs (one-shot) with a safety timeout (~3s). When restoring WinShot snapshots, it also suppresses only the *next* `AXWindowDeminiaturized` notification for the restored external windows that are being unminimized and pre-positioned as part of the snapshot. Other windows remain unaffected and user-triggered actions still get through.
(`grep --line-buffered` streams matching lines without delay.)

## Slow AX Call Logging

Every synchronous Accessibility API call (e.g., `AXUIElementCopyAttributeValue`, `AXUIElementSetAttributeValue`, `AXUIElementPerformAction`, `AXObserverCreate`, `AXObserverAddNotification`) is wrapped in a timing helper. Calls exceeding 0.1s emit a single `[SLOW-AX]` line with the function name, attribute/action, duration (`took Nms`), AX status, target pid + bundle, and a `thread=main`/`thread=bg` tag; calls under the threshold are silent so normal operation adds no log noise. The `thread=` tag distinguishes main-thread blocks (which surface as freezes) from background-queue blocks (which show up as stalled UI updates).

To inspect slow calls in `/tmp/zonogy-debug.log`:

- All slow calls: `grep '\[SLOW-AX\]' /tmp/zonogy-debug.log`
- Only calls of 1 second or longer: `grep -E '\[SLOW-AX\].*took [0-9]{4,}ms' /tmp/zonogy-debug.log` (the `{4,}` matches 4+ digit millisecond counts, i.e. ≥ 1000ms)

## Reducing Accessibility API Cost

Each synchronous Accessibility API call is an inter-process request: the target application must be scheduled, read its own state, and reply. When Zonogy issues many such calls per second across many tracked windows, this drains battery both directly (Zonogy's own CPU work) and indirectly (waking applications that macOS's App Nap would otherwise leave idle). The mechanisms below keep that volume low without changing user-visible behavior.

### Liveness-check cache for prune

The destroyed-window prune pass runs on every full sync. For each tracked window it first checks `CGWindowListCopyWindowInfo` (cheap, no per-app accessibility IPC); if the window is still listed, it falls back to an accessibility safety-net read for the rare "still listed but accessibility element invalid" case.

The safety-net is throttled by a per-window timestamp cache with a 5-second time-to-live. The cache is also refreshed at notification dispatch time: any incoming AX move, resize, miniaturize, deminiaturize, focus-change, or main-window-change notification for a tracked window is itself proof the element is alive, so the corresponding cache entry is refreshed without an additional read.

### Skipping the safety-net for minimized windows

Even with the cache, the safety-net still fires for windows that haven't received recent AX notifications. When such a window is minimized, the read is wasted work: Zonogy isn't acting on its accessibility state, and the target application is more likely to be in App Nap, so the read forces a wake-up to confirm something the user can't observe. The safety-net is skipped entirely for minimized windows. `CGWindowListCopyWindowInfo` still runs unconditionally, so the primary destruction signal is unchanged.

### Single-pass window placement when the first pass settles

When applying a target frame, the placement code first chooses a position-vs-size order so the in-progress frame stays inside the visible screen, applies it, and reads back the resulting frame to verify. If the first pass produced the target frame, the move is done. Otherwise, it follows up with the opposite order as a recovery step, falling through to the existing retry chain if needed.

### Reusing the current frame read

The move pipeline reads the window's current frame once at entry. The same value serves both the skip-if-at-target check and the placement step's apply-order decision.

## Accessibility API Workarounds

### Retry Mechanisms Tied to Accessibility

Zonogy uses five narrowly scoped retry/verification mechanisms to cope with AX timing and consistency issues: three are PID/application-scoped and two are per window. All of them are tied to concrete events (no global polling loops) and are explicitly cancelled when they are no longer needed or when the system goes to sleep.

- **(Per-application) destroyed-window validation retries (PID-scoped):** After AX-relevant lifecycle events (window focus changes, application activation/deactivation/hide), we schedule a short series of PID-scoped validation passes (≈0.2–3.2s backoff) when AX-based destroyed-window detection is inconclusive (see "Destroyed Window Detection" above). These retries are cancelled when the process exits, when all windows are pruned, or when screens go to sleep (`handleScreensDidSleep` calls `cancelAllValidationRetries()`).
- **(Per-application) AX window-capture retries (PID-scoped):** When `AXWindowCreated` notifications fail to yield a manageable window (e.g., transient AX errors), `WindowCapturePipeline` schedules a small number of delayed recapture attempts per PID using `cancelAllRetries()` to tear them down when captures succeed, the app exits, or the system goes to sleep.
- **(Per-window) AX frame application retries:** When Zonogy moves/resizes a window to its zone frame, `WindowController` retries with backoff (≈0.25–3.0s, a few attempts) until the origin is at the target and the app accepted the size write — i.e. `AXUIElementSetAttributeValue(…, kAXSizeAttribute, …)` returned `.success`. The return status tells a transient failure from a permanent one: a non-`.success` means the app refused the resize (e.g. a just-created window not yet ready) — keep retrying; a `.success` that still doesn't reach the requested size is a real size constraint (e.g. a min-width window) — settle immediately and let ActiveFit handle any overflow. Retry chains are cancelled when zone geometry changes, screens go to sleep, or a new `moveWindow` call supersedes the old target. **ActiveFit interaction:** When the retry chain settles, `WindowController` notifies `AppController` via `frameRetryDidSettle`, which evaluates whether ActiveFit reveal mode is needed for zone 2/3 windows.
- **(Per-application) unmanaged-focus resolution retries (PID-scoped):** This pipeline is used only for UI suppression decisions on the focused screen (zone resize bars and Launcher auto-show/dismiss), so Zonogy does not draw interactive chrome over an unrelated focused window. The classifier is tri-state: `managed`, `confirmed unmanaged`, or `unresolved`. We only suppress UI when focus is `confirmed unmanaged` by non-`CGWindowID` management criteria (or bundle-ignore policy). If focus is unresolved (including transient `_AXUIElementGetWindow` failures), we treat it as managed for suppression purposes and retry with PID-scoped exponential backoff (≈0.2–3.2s). Retries are cancelled when focus resolves, the frontmost PID changes, or screens sleep.
- **(Per-window) programmatic minimize verification (window-scoped):** For bulk programmatic minimize flows (especially WinShot restore and clear/reset-zones actions), Zonogy should not assume an AX minimize request "stuck" just because the AX call returned success. Some apps (eg Word) may change focus/activate sibling windows during a minimize burst, causing one requested minimize to be undone or ignored. After issuing each programmatic minimize, perform a short delayed AX-state verification (and one retry on failure) before finalizing cleanup/zone state for that window.

### AXWindowCreated for already-tracked windows (element rebinding)

Some applications can emit `AXWindowCreated` for a window Zonogy already tracks (same PID + `CGWindowID`) (eg Word). In these cases the notification may carry a fresh `AXUIElement` for the same underlying window. Zonogy must treat this as an element-rebind event (update the stored AX element, lookup mapping, and window notification registrations atomically), not as a new-window capture and not as a capture failure.

The same kind of false signal can also surface as an `AXUIElementDestroyed` notification: some applications (e.g. Finder) emit it while the window stays open — sometimes the original element keeps working, sometimes the app recycles in a fresh element. So before acting on `AXUIElementDestroyed` for a tracked window, Zonogy consults the WindowServer (`CGWindowListCopyWindowInfo`) — the ground truth for whether the window still exists. If the window is gone, it proceeds with deferred pruning. If the window is still present, Zonogy keeps it in its zone and makes sure it holds a live AX element: it keeps the element it already has when that element still resolves to the window, and otherwise rebinds to a fresh element the application recycled in. Only when the window appears present but no live element can be bound at all does it fall back to deferred pruning (which still recovers the window if its element reappears on a later capture pass).

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

### Full-screen pause

Zonogy detects native macOS full-screen windows using the (undocumented)`AXFullScreen` accessibility attribute for native-full screen mode (ie green-button kind), and with additional detection for non-native-full screen. The big picture intent is to "pause" Zonogy (no UI, no targeting) on a screen in full-screen mode, and target another screen instead.

#### Native full-screen

We listen to `kAXResizedNotification` which fires when windows enter/exit full-screen mode, and query the `AXFullScreen` attribute via `AXUIElementCopyAttributeValue`. We use 250ms debounce. (Of course, we also handle window closure and app termination.)

At startup (after window capture) and after display reconfiguration, we also iterate all managed windows and check their `AXFullScreen` attribute. We also re-scan full-screen state after active Space changes, since some apps (e.g., Safari video) don't emit resize events for their full-screen windows. This rescan is debounced (250ms) and uses the same `AXFullScreen` query pipeline.

When a screen has a native full-screen window, MacOS creates a new Space for it on that screen. Although Zonogy's pipelines try to target another screen, we can't completely stop windows opening in the screen that's in full-screen mode. If a window opens on that screen, MacOS switches Spaces. This is undesired--instead we want to place any managed window opened in that way into a zone in another (non-full-screen) screen and go back to the full-screen Space so we are not interrupted. (For example, we are watching a movie in full-screen, and doing other things at the same time on another screen.) To get this behavior, we monitor Spaces through another private API (see "CGS Spaces membership query" below).

#### Non-native (heuristic) full screen

For managed apps with exception `treatAXUnknownFullWidthAsFullScreen`: for windows whose AX subrole is `AXUnknown` (some presentation-style windows like Keynote full-screen), we treat them as full-screen if their accessibility frame width matches the screen width exactly.

### CGS Spaces membership query (native full-screen only)

Going back to the full-screen Space (per the previous section) depends on knowing whether that Space still exists while another Space is showing on the same screen. `AXFullScreen` tells us a window claims to be full-screen, but it doesn't say whether its full-screen Space is the active one. The standard on-screen window list (`CGWindowListCopyWindowInfo`) doesn't help either — it only includes windows in the currently active Space, so a window on an inactive full-screen Space looks the same as one that has exited full-screen.

CGS Spaces (`CGSCopySpacesForWindows` + `CGSSpaceGetType == kCGSSpaceFullscreen`) answers the question directly: it reports which Spaces a window currently belongs to. We rely on it in places where we would otherwise mistakenly drop Zonogy's full-screen pause.

---

## Timers

For a complete inventory of all timers and delay mechanisms (AX retries, debounce, protection windows, etc.), see [SPECIFICATION-TIMERS.md](SPECIFICATION-TIMERS.md).
