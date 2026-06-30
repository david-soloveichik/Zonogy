# Zonogy Regression Notes

Use this file as a pre-change checklist for tricky behaviors that have previously regressed.
Each entry is a brief bug report plus something an LLM should be sure to think about to avoid regressing when editing related code.
Keep entries short. When applicable, prefer phrasing them generally rather than tying them too tightly to one specific change, since the LLM should be able to figure out the rest when guided this way.

- Bug report: Sometimes if window A is in a tiling zone and window B is in floating zone, then minimizing A also minimizes B.
  - Think about: Focus/activation and sync can race.

- Bug report: Normal Zonogy behavior can steal active status from windows.
  - Think about: Ordinary UI repositioning, retargeting, and recovery paths should not activate Zonogy or change focus unless that behavior is explicitly intended.

- Bug report: If a managed tiled window is manually resized larger, zone resize bars can remain drawn over the active window.
  - Think about: Refresh resize-handle descriptors on non-programmatic resize notifications, and keep overlap clipping/hiding rules in one pure policy helper that covers all tiling zones.

- Bug report: After zone resizing, the Codex window can "jump" toward an older zone position a moment later.
  - Think about: Delayed AX frame retries can outlive newer retargeted moves; cancel/invalidate stale retry chains on retarget and guard retry work items so replaced chains cannot execute.

- Bug report: A newly created window (eg Chrome) routed into zone 2/3 can enter ActiveFit reveal mode before it resizes to the zone size, leaving it not filling the zone.
  - Think about: Entering reveal mode calls moveWindow which cancels the pending frame retry chain. ActiveFit must skip reveal evaluation when a frame retry is pending and re-evaluate when the retry settles.

- Bug report: A newly created window opened into a tiling zone can keep its opening size instead of filling the zone (eg NordVPN), then only snap to the zone later when an unrelated event triggers a fresh sync.
  - Think about: An app can reject the initial AX size write (window queried microseconds after creation) while the position write succeeds. Need an appropriate retry mechanism.

- Bug report: Native macOS tabs can be captured as separate windows because `_AXUIElementGetWindow` reports a fresh `CGWindowID` before `CGWindowListCopyWindowInfo` exposes its bounds.
  - Think about: When native tab handling is enabled, eligible unplaced windows should wait for a live WindowServer frame before normal placement so same-frame tab replacement can run. "Unplaced" includes already-tracked windows that are not assigned to any Zonogy zone; do not limit this to never-seen `CGWindowID` values.

- Bug report: Rapid Terminal tab changes can make the placed tab backing lose both its live WindowServer frame and current AX frame during adoption, causing the newly active tab to be captured as a new window and placed in another zone.
  - Think about: The native-tab adoption path should fall back to the placed window's remembered frame after confirming its old `CGWindowID` no longer has a live WindowServer frame.

- Bug report: Dragging a tiled window's last native tab into another tiled window can leave the moved source tab assigned to its old zone, so later focus/layout handling can snap the visible tab back there instead of treating the drag as a merge.
  - Think about: When an application-driven move puts a placed same-process source window at another placed window's frame, collapse the source into the destination: destination keeps its `windowId` and zone while adopting the source backing, and the source zone is emptied. Suppress immediate focus-driven reasserts briefly while such app-driven moves settle.

- Bug report: Selecting or dragging a parked native-tab window from Launcher, DockMenus, CmdTab, or another explicit chooser can place one tab identity in a tiling zone while sibling tab identities later get placed separately, making one real window appear to occupy multiple zones.
  - Think about: Explicit placement paths should not assign minimized windows directly. Set the intended target, then let the deminiaturize notification run unsuppressed so native-tab replacement can collapse the active tab into an existing placed managed window before any normal placement, and focus the resulting visible window afterward.

- Bug report: A full sync can see a placed native-tab backing missing from the global WindowServer snapshot and prune it before the safer PID-scoped close-rebind has a chance to adopt a surviving sibling tab.
  - Think about: Full sync should defer placed native-tab stale candidates to PID validation instead of choosing a sibling or pruning directly from a global WindowServer snapshot miss.

- Bug report: A newly discovered managed window can clear a very recent pending-prune entry for another window from the same PID before that original window has had a chance to reappear.
  - Think about: Same-PID new-window cleanup should preserve very recent pending-prune entries generally; this is not specific to native tabs and should not depend on the native-tab handling preference.

- Bug report: After sleep/wake or screen-change recapture, a pruned window can be re-placed from stale recapture state, leaving a tiling zone falsely occupied and routing subsequent windows into the floating zone.
  - Think about: Recapture placement must revalidate candidate IDs against the live registry, and sync must clear any zone occupant IDs with no managed window.

- Bug report: Restoring a WinShot snapshot with an empty tiling zone can leave that zone without its placeholder because restore sync ran before removing windows that should be absent.
  - Think about: WinShot restore must remove/minimize non-snapshot windows before its sync pass so placeholder reconciliation sees the final occupancy state.

- Bug report: Launcher auto-show can close almost immediately because focus-based dismissal races the panel open.
  - Think about: Preserve a real post-open grace window and/or require unmanaged-focus state to stabilize (short debounce or repeated confirmation) before dismissing.

- Bug report: Holding Control-Command after an external drag stops moving can show the intercepted zone overlay, but releasing without another mouse move drops nothing.
  - Think about: `flagsChanged` alone must not arm the intercepted overlay. Only a subsequent drag move should promote to Control-Command interception; otherwise keep the stationary UI truthful (including leaving empty-zone placeholder behavior unchanged).

- Bug report: A drag aimed at the add-zone pill or floating-zone pill can be stolen by an underlying tiling zone.
  - Think about: Edge-pill targets must take precedence over overlapping zone targets across drag contexts, and drag/highlight UI should stay truthful about which destination will actually win.

- Bug report: Sleep/wake can leave delayed retries or timers running into AX-not-ready periods, causing false window pruning or other incorrect lifecycle actions.
  - Think about: Route sleep-sensitive timer/work-item cancellation through `cancelSleepSensitiveAsyncWork(reason:)` (in `AppController+SleepWake.swift`), only resume AX-dependent work after wake readiness gates are satisfied, and keep sync-pruned windows in deferred-prune bookkeeping long enough to restore the same `windowId` if the same pid/CGWindowID reappears.

- Bug report: Launcher app-list cache can refresh in the background while the Launcher is open, but the visible list stays stale until close/reopen.
  - Think about: Keep reload behavior consistent across manual and automatic paths, and refresh live Launcher app-list state in place (without dismissing) when cache reload completes.

- Bug report: Launcher can appear somewhere other than the targeted zone.
  - Think about: Preserve the invariant that Launcher only ever follows the real current target and never keeps an independent destination.

- Bug report: Launcher and CmdTab chooser can both remain visible.
  - Think about: Explicit Launcher opens should hand off from CmdTab, while automatic Launcher opens should be suppressed until CmdTab is gone.

- Bug report: Placing a window into zone 2/3 can visibly flicker (rest-position move(s) before reveal).
  - Think about: Avoid immediate duplicate geometry writes for a just-placed window before ActiveFit reveal applies.

- Bug report: WinShot restore can leave the active window behind other restored windows.
  - Think about: Async unminimize animations complete after the active window's AXRaise; re-raise the active window when each suppressed deminiaturize notification arrives.

- Bug report: When a launching app processes its own queue of windows to unminimize, synchronously minimizing the displaced occupant appends it to the back of that queue, where the app re-unminimizes it — infinite minimize/unminimize loop.
  - Think about: A programmatic minimize issued during an app's own unminimize burst can be picked up and undone by the app's pending queue. Sequence or defer such minimizes so they don't feed the burst, and have a fallback that detects the loop and breaks it.

- Bug report: A managed window can briefly lose its zone (placeholder appears, Launcher auto-shows, then both vanish) when its app emits a spurious `AXUIElementDestroyed` while the window stays open — e.g. Finder recycling a window's AX element on clicking to rename a file (likely a Finder bug).
  - Think about: An `AXUIElementDestroyed` notification only proves the *element* went away, not the window. Cross-check the WindowServer ground truth (`CGWindowListCopyWindowInfo`) and confirm a fresh AX element binds before vacating the zone; rebind the element in place when the window is still present rather than pruning and later restoring.

- Bug report: Sticky Resize and ActiveFit both move and track a right-column window's frame on focus/activation events and can desync — Sticky Resize's size restore, its focus-loss snapback to the zone frame, and ActiveFit's reveal/rest transitions each run without fully accounting for the others. Symptoms seen: the window hanging off-screen at rest while ActiveFit still thinks it is revealed; thrashing between rest and reveal under a burst of notifications (e.g. Messages on unminimize); and stale reveal state after snapback, leaving resize-bar avoidance and frame-retry suppression keyed to a reveal frame the window has already left.
  - Think about: While a right-column window is revealed, ActiveFit is the single owner of its frame (it already folds the remembered sticky size into its reveal candidate). Every other frame path — Sticky Resize restore, manual-resize snapback, zone sync — must leave a revealed window alone rather than move it; ActiveFit decides when to return it to rest (on focus to another managed window, minimize, close, etc.; it deliberately keeps reveal when focus goes to an unmanaged/untracked window). ActiveFit must also reassert the reveal when the window's actual frame no longer matches its cached reveal frame rather than trusting stale state.

- Bug report: Removing a lower-index zone can reindex an ActiveFit reveal-mode window from zone 2 to zone 1, but the reveal-state cache still names the old zone 2 when exiting reveal mode. The stale rest transition can move the window back into the new zone 2, stacking it with that zone's occupant.
  - Think about: Rest-mode transitions should use the window's current zone assignment after reindexing, falling back to cached reveal state only if the current assignment is unavailable.

- Bug report: Activating another app can focus a managed window without delivering an AXFocusedWindowChanged event for the arriving app.
  - Think about: Mirror the Sticky Resize restore path from NSWorkspace activation when a tracked focused managed window is already known.

- Bug report: DockMenus window rows can stop highlighting on hover even though the app header still highlights.
  - Think about: Tracking areas in shared interaction views should use `.activeAlways` rather than `.activeInKeyWindow`, since the view may be hosted in non-activating panels that never become key.

- Bug report: In some rare circumstances, hovering Dock icons can silently stop showing DockMenus until the feature is toggled off and on.
  - Think about: The Dock can rebuild its accessibility hierarchy in place, potentially leaving the hover observer attached to a stale AXList element.

- Bug report: Dragging a managed window across a screen boundary can make macOS resize the window itself (e.g. clamping an oversized window to fit the display it is crossing into), firing a stream of non-programmatic AXResized events. Handling these as user "manual resize ended" corrupts manual-resize/Sticky-Resize state and thrashes the resize bars for the whole drag.
  - Think about: During a manual drag the OS can resize the window on its own, not just move it; resize handling should recognize an in-flight drag rather than treat those as a user resize.

- Bug report: A window that disappears mid floating-zone-drag (e.g. a Chrome tab tears out into a new window, or the window is minimized while being dragged) can leave the blue zone overlays stuck on screen until the app restarts, and a stale drag session can hijack the next drag.
  - Think about: Floating-zone drags and tiled drags keep separate state and overlays, so any path that ends a drag — including the window vanishing mid-drag — must tear down whichever kind is active.
