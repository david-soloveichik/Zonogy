# Timers Used by Zonogy

Most timers in Zonogy exist to work around limitations and timing quirks of the macOS Accessibility (AX) API. Others debounce rapid events or provide UX polish. This document catalogs operational timers and delay mechanisms — AX retries, debounce, protection windows, polling, and interaction timing. Purely cosmetic animations (fade durations, scroll animations, etc.) are not included.

---

## Regular Operation

These timers fire during normal window management — the core of Zonogy's runtime.

### AX Retry Mechanisms (Exponential Backoff)

AX operations can fail transiently — windows may not be queryable yet, frames may not apply on the first attempt, or destruction signals may be unreliable.

| Timer | Duration | Mechanism | File | Purpose |
|-------|----------|-----------|------|---------|
| **AX frame application retries** | 0.25, 0.5, 1.0, 3.0s | `asyncAfter` (backoff) | `WindowController+FrameManagement.swift` | AX move/resize can transiently fail. Retries until the window is positioned AND the app accepted the write: a size the app accepts but clamps (e.g. a min-width window that can't shrink to the zone) settles immediately, while a size write the app rejects outright keeps retrying until it's accepted or the attempts are exhausted. On settle, triggers ActiveFit reveal mode evaluation for zone 2/3 windows. |
| **Destroyed-window validation retries** | 0.2, 0.4, 0.8, 1.6, 3.2s | `asyncAfter` (backoff) | `ValidationRetryManager.swift` | AX destruction detection is unreliable (some apps never emit destroy notifications). After lifecycle events, retries PID-scoped validation to catch closed windows. |
| **Window capture retries** | 0.25, 0.5, 1.0, 2.0, 4.0s | `asyncAfter` (backoff) | `WindowCapturePipeline.swift` | `AXWindowCreated` sometimes fires before the window is queryable. With native macOS tab handling enabled, `_AXUIElementGetWindow` can also expose a fresh `CGWindowID` before `CGWindowListCopyWindowInfo` returns its live frame. Retries capture with exponential backoff until a manageable window is found. The first retry is short because the live frame usually settles within tens of milliseconds; a fresh trigger (e.g. another tab switch) resets the backoff so rapid triggers don't escalate the delay before the new tab is adopted. |
| **Unmanaged-focus resolution retries** | 0.2, 0.4, 0.8, 1.6, 3.2s | `asyncAfter` (backoff) | `AppController+SystemEvents.swift` | `_AXUIElementGetWindow` can transiently fail, making it unclear if a focused window is managed. Retries to resolve managed/unmanaged classification for UI suppression decisions (resize bars, Launcher auto-show). |

### AX Verification & Protection

These compensate for AX operations that report success but may not actually take effect, or for macOS firing spurious events in response to Zonogy's own actions.

| Timer | Duration | Mechanism | File | Purpose |
|-------|----------|-----------|------|---------|
| **Programmatic minimize verification** | 0.12s first, 0.2s retry | `asyncAfter` | `AppController+ZoneLifecycle.swift` | AX minimize requests can silently fail (e.g., Word activates a sibling window during a minimize burst, undoing the minimize). Verifies the window actually minimized and retries once if not. |
| **Notification suppression timeout** | 3.0s | deadline-based (lazily checked) | `AppController+ZoneLifecycle.swift` | When Zonogy programmatically minimizes/unminimizes windows, it suppresses the next AX notification for that window to avoid reacting to its own actions. The 3s deadline is a safety net so suppression doesn't persist indefinitely if the notification never arrives. Not a scheduled timer — checked lazily when events arrive. |
| **Programmatic-update suppression** | 0.5s | `asyncAfter` | `WindowController+FrameManagement.swift` | After Zonogy moves/resizes a window via AX, tags it as "programmatic" for 0.5s. AX move/resize notifications arriving during this window are ignored, preventing feedback loops where Zonogy reacts to its own operations. |
| **Floating zone protection** | 0.5s | `asyncAfter` + deadline | `AppController+FloatingZoneIdentity.swift` | After placing a window in the floating zone, macOS may fire spurious focus events (e.g., activating a sibling window after the displaced occupant is minimized). During the protection window, occlusion-based minimization is suppressed and the floating window is reactivated if focus drifts. |
| **Activity recording suppression** | 0.5s | deadline-based | `AppController+FloatingZoneIdentity.swift` | Suppresses CmdTab/Launcher recency recording during floating zone placement and WinShot restore. Prevents transient focus events from these operations from polluting the recency order. |
| **Manual move suppression** | 1.5s | deadline-based | `AppController+SystemEvents.swift` | After Zonogy programmatically moves windows (e.g., screen topology change), AX move notifications arrive but are not user-initiated. Suppresses manual-move/drag handling for 1.5s so Zonogy doesn't misinterpret its own moves as user drags. |
| **ActiveFit restore suppression** | 1.0s | `asyncAfter` | `AppController+ActiveFit.swift` | During WinShot snapshot restore, internal operations rapidly move windows around. ActiveFit reveal mode evaluation is suppressed for 1s so decisions are made only after the layout settles. |

### Debounce

These batch rapid events to avoid redundant work or UI flicker.

| Timer | Duration | Mechanism | File | Purpose |
|-------|----------|-----------|------|---------|
| **Deferred minimization debounce** | 0.15s | `DispatchSourceTimer` | `DeferredMinimizationCoordinator.swift` | Shared minimization queue. Used by occlusion/focus-driven floating minimization, the floating-zone explicit-minimize path, and placements that flow through `placeNewWindow` (any "a window arrived" event). The latter queue the displaced occupant rather than minimizing synchronously: a launching app processing its own unminimize queue would otherwise re-unminimize our just-minimized window, creating an infinite ping-pong. Debouncing lets the app drain its queue first. Zonogy-initiated single-window swaps that don't go through `placeNewWindow` (Launcher, drag-drop, moves, full-screen exit deferred placements) still minimize synchronously so any brief visual flash from the AX minimize lands while the incoming window is still hidden. See `SPECIFICATION-IMPLEMENTATION.md` for the flash mental model. |
| **Minimize loop guard active window** | 3.0s | deadline-based | `MinimizeLoopGuard.swift` | Safety net for the rare case where a synchronous-path minimize is rapidly re-unminimized by an external app. After two such rapid re-unminimizes within 2 seconds, future programmatic minimizes route through the deferred queue for 3 seconds. |
| **Screen topology change debounce** | 0.25s | `asyncAfter` | `AppController+SystemEvents.swift` | macOS fires multiple rapid display-change notifications when monitors are connected/disconnected. Waits 250ms for them to settle before recapturing topology. |
| **Dock observer re-establish (coalesce + retry)** | 0.5s, up to 8 attempts | `asyncAfter` | `DockAXNotificationMonitor.swift` | Rebinds the Dock hover observer when the Dock rebuilds its accessibility hierarchy in place (firing `AXUIElementDestroyed` in bursts) or when the Dock process crashes / is relaunched (`killall Dock`). The 0.5s delay coalesces bursts; if the Dock is not yet observable (no usable `AXList` — e.g. a relaunched Dock still building its tree), it retries every 0.5s up to 8 times before giving up. |
| **Full-screen check debounce (resize)** | 0.25s | `asyncAfter` | `AppController+FullScreen.swift` | Windows emit resize notifications in bursts during full-screen transitions. Waits 250ms after the last resize before querying `AXFullScreen`. |
| **Full-screen check debounce (Space change)** | 0.25s | `asyncAfter` | `AppController+FullScreen.swift` | Some apps don't emit resize events for full-screen windows on Space change. Debounces the rescan to 250ms after the Space change. |
| **Self-resize snap debounce** | 0.25s | stateful timestamp cache | `WindowSelfResizeSnapSupport.swift` | For apps with `snapToZoneOnSelfResize`, prevents repeated snap-to-zone attempts for the same window and target frame within 250ms. Avoids infinite loops when an app's internal resize triggers a snap which triggers another resize notification. |
| **Window liveness AX-check cache** | 5.0s | per-window timestamp cache | `WindowController.swift` | The CGWindowList snapshot is the primary destruction signal in `pruneDestroyedExternalWindows` and runs on every sync. The fallback per-window AX liveness check (`AXRole` + `AXPosition` reads) covers the rare "still in window list but AX-element invalid" case. Recently-confirmed-alive windows skip that AX check for 5s, eliminating the bulk of redundant AX reads during burst syncs. The TTL is sized from empirical traces showing the AX fallback essentially never finds stale windows that CGWindowList missed. Negative results are not cached (so re-aliveness is detected immediately on the next sync). The cache is invalidated whenever a window is removed via `removeManagedWindowFromLiveTracking` or its AX element is rebound via `rebindElement`. |
| **Launcher install-watch debounce** | 2.0s | `asyncAfter` | `LauncherInstallWatchService.swift` | App installations/removals trigger many filesystem events. Waits 2s after the last event before reloading the Launcher's app cache. |
| **Launcher install-watch stream latency** | 3.0s | `FSEventStream` | `LauncherInstallWatchService.swift` | FSEvents stream coalescing latency — the OS may batch filesystem events for up to 3s before delivering them. The stream does not use `kFSEventStreamCreateFlagNoDefer`, so macOS can defer delivery to reduce wakeups. |
| **Launcher usage persistence debounce** | 0.5s | `Task.sleep` | `LaunchItemUsageStore.swift` | Batches rapid Launcher item usage updates before persisting to disk. |
| **WinShot occupancy settle delay** | configurable, default 3.0s | `asyncAfter` (per-screen `DispatchWorkItem`) | `WinShotOccupancyAutoSaveScheduler.swift` | When WinShot auto-save mode is "on every zone occupancy change", each screen's settle timer (re)starts whenever that screen's zone occupancy changes; if the arrangement survives the delay unchanged, a snapshot is captured. Because the capture happens a short while after the arrangement settles (while it is still on screen), it doubles as the correct pre-change record for the next change — including externally-initiated ones Zonogy learns of too late to capture directly. Arrangements that don't survive the delay are not saved. (A snapshot that settles while the WinShot chooser is open is saved silently, without refreshing the open chooser.) |
| **WinShot thumbnail capture retry** | 0.2s, up to 4 attempts | `asyncAfter` (on the capture queue) | `WinShotThumbnailComposer.swift` | A snapshot thumbnail captures each window individually via `CGSHWCaptureWindowList`. A window caught mid-minimize (e.g. the outgoing floating occupant minimized during a chooser switch) returns no image while the genie animation is in flight, which would otherwise leave a permanent gray tile. Each attempt re-captures only the still-missing windows; attempts land at roughly 0.0/0.2/0.4/0.6s, so the later retries fall past the genie (~0.25s) once the window has settled into its (capturable) minimized state. After 4 attempts any still-missing window is rendered as a placeholder tile and logged. |

### UX / Interaction

These provide smooth user experience during interactions.

| Timer | Duration | Mechanism | File | Purpose |
|-------|----------|-----------|------|---------|
| **Zone resize drag throttle** | 0.025s (40 Hz) | `Timer` + `RunLoop.main` | `ZoneResizeHandleManager.swift` | Mouse drag events can arrive faster than layout can update. Batches drag deltas and dispatches resize at ~40 Hz to keep the main thread responsive. Runs in `.common` RunLoop mode so it fires during mouse tracking. |
| **DockMenu show delay** | 0.12s | `asyncAfter` | `DockHoverTracker.swift` | Prevents DockMenu from flickering during fast Dock scrubbing. Only shows if cursor remains on the same Dock icon for 120ms. |
| **DockMenu dismissal polling** | 0.05s repeating with 0.025s tolerance, 0.2s grace | `Timer` + `RunLoop.main` | `DockMenuDismissalPoller.swift` | No reliable event for "cursor left both the Dock icon and DockMenu panel". Polls cursor position at 50ms with timer tolerance so macOS can coalesce wakeups; dismisses after cursor stays outside the safe region for 200ms. |
| **Floating zone indicator hover-exit** | 0.06s | `asyncAfter` | `FloatingZoneIndicatorManager.swift` | Hysteresis for hover detection on the floating zone indicator. Delays the exit check by 60ms to avoid flicker during fast edge swiping. |
| **Add-zone indicator hover-exit** | 0.06s | `asyncAfter` | `AddZoneIndicatorManager.swift` | Same hysteresis for the add-zone indicator pill on the screen edge. |
| **External drag overlay teardown** | 0.05s | `asyncAfter` | `ExternalZoneDropInterceptor.swift` | Brief pause before cleaning up drag overlay UI after an external drop, allowing the drop animation to complete. |
| **Placeholder external drag overlay teardown** | 0.05s | `asyncAfter` | `AppController+WindowCapture.swift` | Same brief teardown delay for the placeholder-specific external drag overlay path. |
| **Async unminimize settle delay** | 0.01s | `asyncAfter` | `WindowController+WindowOps.swift` | When unminimizing a pre-positioned window, yields to the run loop for 10ms before issuing the AX unminimize call. Without this, the window can visually flash at its old position before snapping to the target. Skipped (unminimize runs synchronously) when the Debug preference "Disable pre-position of minimized windows prior to unminimize" is on, since the delay's purpose — letting the pre-position write settle — no longer applies. |
| **Launcher auto-show grace period** | 0.5s | deadline-based | `LauncherController.swift` | After auto-showing the Launcher, suppresses immediate dismissal for 0.5s. macOS may auto-focus a window behind the Launcher panel, which would otherwise trigger an unwanted dismiss. |
| **Window activity recording stability** | 0.25s | `asyncAfter` | `AppController+TargetingBehavior.swift` | Only records a window focus event for CmdTab/Launcher recency if the window remains focused for 250ms. Prevents twitchy recency updates during rapid app switching. |
| **User resize mouse-up grace** | 0.35s | deadline-based | `AppController.swift` | After mouse-up, there's a brief window where a border-adjacent resize is still classified as user-driven. Bridges the gap between the mouse release and the final AX resize notification. |

### Recapture (Display Topology Changes)

| Timer | Duration | Mechanism | File | Purpose |
|-------|----------|-----------|------|---------|
| **Deferred recapture** | 0.5s + 1.5s | `asyncAfter` | `AppController+Recapture.swift` | After display topology changes, schedules two deferred passes (at 0.5s and 1.5s) to capture new windows and place tracked-but-unzoned windows that may have appeared or moved during the transition. |

---

## Sleep/Wake

These timers handle the sleep/wake transition, where AX APIs become temporarily unavailable.

| Timer | Duration | Mechanism | File | Purpose |
|-------|----------|-----------|------|---------|
| **Wake readiness polling** | 0.5s repeating with 0.25s leeway | `DispatchSourceTimer` | `AppController+SleepWake.swift` | After `screensDidWakeNotification`, AX APIs may not be ready yet. Polls every 0.5s until the display is awake, the session is unlocked, and `NSWorkspace.shared.frontmostApplication` returns non-nil. The timer uses leeway so macOS can coalesce wakeups during recovery. (Uses NSWorkspace instead of AX because AX can hang indefinitely with some apps during wake recovery.) |
| **Deferred recapture (wake)** | 0.5s + 1.5s | `asyncAfter` | `AppController+Recapture.swift` | After wake-from-sleep, schedules the same two deferred recapture/placement passes as display topology changes. |

### Sleep Cancellation

When screens go to sleep (`screensDidSleepNotification`), Zonogy prevents AX operations from firing during sleep using two strategies:

**Explicitly cancelled:** Validation retries, wake readiness timer, frame retries, capture retries, screen-change recapture timers, and screen-change debounce timer are actively cancelled in `handleScreensDidSleep`.

**Guard-and-bail:** Some delayed work items are not explicitly cancelled but instead check `screensAsleep` when they fire and return early if true. This includes: minimize verification (`AppController+ZoneLifecycle.swift`) and startup capture (`AppController+Startup.swift`).

See [SPECIFICATION-WAKE.md](SPECIFICATION-WAKE.md).

---

## Startup & Application Events

| Timer | Duration | Mechanism | File | Purpose |
|-------|----------|-----------|------|---------|
| **Application window capture** | 0.0s + 0.4s | `asyncAfter` | `AppController+Startup.swift` | Schedules two capture attempts per application — one immediate (0.0s) and one at 0.4s. Used at startup for all running applications, and at runtime for app activation, launch, and unhide events. The second attempt catches windows that aren't AX-queryable right away. (Separate from `WindowCapturePipeline` backoff retries, which handle per-PID capture failures after `AXWindowCreated`.) |

---

## Preferences UI

| Timer | Duration | Mechanism | File | Purpose |
|-------|----------|-----------|------|---------|
| **Accessibility permission polling** | 1.0s repeating with 0.5s tolerance | `Timer.scheduledTimer` | `GeneralPreferencesViewController.swift` | No notification exists for accessibility/screen-recording permission changes. Polls every 1s while the Preferences General tab is open to update the UI, with timer tolerance so macOS can coalesce wakeups. |

---

## Notes

- **No global polling loops:** Every timer is tied to a concrete event (window creation, focus change, display reconfiguration, etc.). Scheduled timers (`asyncAfter`, `DispatchSourceTimer`, `Timer`) are cancelled when no longer needed. Deadline-based mechanisms (notification suppression, activity recording suppression) are not actively cancelled — they expire passively when checked.
- **Why so many AX workarounds?** The Accessibility API provides no guarantees on timing, ordering, or completeness of notifications. Windows may not be queryable when created, moves may silently fail, destroy notifications may never arrive, and the API may be entirely unavailable during sleep/wake transitions. Each retry mechanism targets a specific failure mode.
