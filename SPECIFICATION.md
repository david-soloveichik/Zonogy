# Zonogy Window Manager for MacOS

## Overview

Zonogy is a variation on a tiling window manager built around the concept of **zones**. Traditional tiling managers are “twitchy”: the layout constantly reflows as you open/close windows, causing distracting resizing and repositioning. Zonogy addresses this by keeping a set of tiling zones per screen that can remain present even when empty, so the layout is stable and the user can reserve space for future windows. At any time, one destination is **targeted**, and new/unminimized windows flow into that target predictably. Zonogy also includes a (per-screen) **temporary zone** to float a single window above the tiled layout.

## Core Concepts

### Zones

Zonogy organizes managed windows into **zones**. Each screen has 1–3 **tiling zones** (indexed 1…zoneCount) that form the main layout, and one **temporary zone** used for floating a single window above the tiled layout.

A zone contains at most one unminimized window or is empty. Minimized windows do not belong to any zone.

Empty tiling zones are represented by placeholder windows (except in UnderCovers mode). Empty temporary zones have no placeholder.

At any moment exactly one zone is targeted. Newly created or unminimized windows are placed into the targeted zone (moving across screens if needed).

If the targeted zone already holds a managed window, the new window replaces the occupant and the displaced window is minimized. (If the tiling zone is empty and represented only by a placeholder, that placeholder is closed.)

Detailed targeting controls, tiling layout rules, placeholder behavior, and temporary-zone behavior are specified in **User Interactions** below.

### **CRITICAL: Coordinate System**

**All zone frames, window positions, and dimensions MUST use screen coordinates with y:0 at the top-left corner of the screen.**

This is fundamentally different from Cocoa/AppKit coordinates which have y:0 at the bottom-left:

- **Screen coordinates** (used by Accessibility API and zones): y:0 is at the **TOP-LEFT**, y increases **DOWNWARD**
- **Cocoa coordinates** (used by NSScreen, NSWindow): y:0 is at the **BOTTOM-LEFT**, y increases **UPWARD**

**Implementation requirements:**

1. All zone frames computed by `ZoneLayout` and stored in `ZoneController` must be in screen coordinates
2. When obtaining screen bounds from `NSScreen.visibleFrame` or `NSScreen.frame`, **convert from Cocoa to screen coordinates**
3. When positioning **AppKit windows** (placeholder windows), **convert from screen to Cocoa coordinates** before calling `setFrame()`
4. When positioning **external windows via Accessibility API**, use screen coordinates directly (no conversion needed)
5. All logging, REPL output, and socket API responses must report frames in screen coordinates

**Example for 3-zone layout on a 1080p display:**

- Zone 1 (left column): `{x: 0, y: 0, width: 960, height: 1080}` — starts at top-left
- Zone 2 (right-top): `{x: 960, y: 0, width: 960, height: 540}` — **y:0 is at the TOP**
- Zone 3 (right-bottom): `{x: 960, y: 540, width: 960, height: 540}` — y:540 is **BELOW** zone 2

Never mix coordinate systems or windows will be positioned incorrectly.

### Window Management Criteria

We manage a window if it passes **all** of the following conditions (see `winmanmon` source code for how it collects this information):

- If the window is unminimized: **Subrole: AXStandardWindow** (ONLY AXStandardWindow; NOT AXDialogSubrole or any other subrole). (We do not perform this check for minimized windows because some applications report them as AXDialogSubrole; see "Accessibility API Workarounds" below.)
- **isMovable: T** (window position can be modified)
- **hasZoom: T** (window has a zoom button)
- **Height: >= 250px** (window must be at least 250 pixels tall)
- **_AXUIElementGetWindow** returns a valid `CGWindowID` for the window

### Window Identifiers

Every managed window (other applications' windows) and placeholder window gets a sequential `windowId` that the zone controller uses as its source of truth, even when the window also has a `CGWindowID` (obtained via `_AXUIElementGetWindow`). Placeholder panes never receive a `CGWindowID` and real windows can temporarily lack one, so always retain the internal `windowId` while logging both identifiers whenever the CGWindow value exists.

## User Interactions

### Tiling Layout and Spacing

Tiling zones have indexes (1, 2, 3). When tiling zones are added or removed on a screen, remaining zones reindex sequentially and the tiling zones on that screen are re-tiled to split the screen as follows:

- 1 zone: full screen (zone 1)
- 2 zones: left (zone 1) and right (zone 2)
- 3 zones: left (zone 1), right-top (zone 2), right-bottom (zone 3)

Both windows and placeholders preserve an 8 pixel buffer at the outer screen edges. When two zones share a boundary, they split that buffer evenly so the visible gap between their contents is exactly 8 pixels (each zone contributes 4 pixels along the shared edge) for a consistent grid.

### Placeholders

Placeholder windows are translucent, frameless stand-ins for empty tiling zones. They have a rounded rectangle border and no title bar or standard window controls. A large semi-translucent blue button in the upper-left corner shows "x" (to remove the zone) or "⌄" (to enter UnderCovers mode; see **Special Features**).

Placeholders stay anchored to their zone: dragging their surface does not reposition them. Resize zones via zone resize bars (see **Resizing Zones**).

### Adding and Removing Zones

There are several ways to remove a zone, the main ones being:

- By pressing the blue "x" button on the placeholder window of an empty zone.
- By pressing a keyboard shortcut Control-Cmd-[minus].

When invoking Control-Cmd-[minus], never remove the zone containing the currently active (aka key) window. Among the remaining zones, remove one using this priority:

1. Prefer empty zones over occupied zones.
2. Prefer non-targeted zones over the targeted zone.
3. Break any remaining ties by choosing the zone with the highest index.

The minimum number of zones is 1. In other words, we cannot remove the last zone. The maximum number of zones is 3 (for now).

**Example:** Suppose the user has 2 zones—zone 1 with window A and zone 2 with window B—and wants to remove zone 1. They minimize window A (causing a placeholder to appear in zone 1), then click the blue "x" on that placeholder. Zone 2 becomes zone 1, and window B shifts to fill the left side of the screen.

A zone can be added by pressing the global keyboard shortcut Control-Cmd-=. The new zone should be added with the highest index, and it should start out initially empty.

Each screen with fewer than 3 tiling zones also displays an add-zone indicator: a vertical pill (≈6 px wide, ≈⅓ screen height) on its right edge, vertically centered. Clicking this indicator adds a tiling zone to that screen.

Pressing Control-Cmd-Space clears all zones on the active screen and empties the temporary zone. If the zones are already empty on the active screen, then it resets to a one-zone configuration (just zone 1). After this clear/reset completes, target zone 1 on that screen.

Pressing Shift-Option-Control-Cmd-Space performs the same steps, but works with the screen currently holding the mouse pointer.

### Targeting

**Targeting rule:** Exactly one zone (tiling zone or temporary zone) is targeted at any moment. Newly created or unminimized windows are always placed into the targeted zone.

**Target indicator UI (tiling zones):** Every tiling zone renders a slim translucent indicator (≈6 px tall, ≈⅓ the zone width) centered in the margin directly above the zone. The targeted zone's indicator glows brighter. Indicators respond to clicks to retarget zones.

**Temporary zone indicator UI:** Each screen renders a bottom-edge pill indicator for its temporary zone. Clicking that pill targets the temporary zone for that screen. The indicator sits flush with the screen bottom so edge clicks hit it.

**Target selection:**

- Clicking a tiling zone placeholder window or a tiling zone's target indicator: target that tiling zone.
- Clicking the temporary zone indicator: target that screen's temporary zone.
- Control-Command + left-click anywhere inside a tiling zone (occupied window, placeholder, or empty space) targets that tiling zone; the gesture is consumed before it reaches the underlying window.
- Whenever a tiling zone becomes empty because its window disappears (minimize, close, crash, or any other disappearance), target that zone.
- When a new tiling zone is created: target it if the current target is filled or has a higher index; otherwise keep the current target.
- Whenever the targeted tiling zone is filled: if another empty tiling zone exists on the same screen, retarget to the lowest-index empty tiling zone; if none exist, target the temporary zone on that same screen.
- If the targeted zone is removed: retarget to the lowest-index empty tiling zone on the same screen if there is one; otherwise target the temporary zone on that same screen.

**Target navigation shortcuts:**

- Control-Cmd-DownArrow: target the temporary zone on the same screen as the currently targeted tiling zone. If a temporary zone is already targeted, the shortcut does nothing.
- Control-Cmd-UpArrow: switch from the targeted temporary zone to a tiling zone on the same screen (prefer empty zone with lowest index, or filled zone with highest index if no empty zone exists). Does nothing if a temporary zone is not targeted.
- Control-Cmd-LeftArrow: navigate left. If temporary zone is targeted, target the temporary zone on the screen to the left. If tiling zone is targeted, target the zone with lower index on same screen, or wrap to the last zone on the previous screen.
- Control-Cmd-RightArrow: navigate right. If temporary zone is targeted, target the temporary zone on the screen to the right. If tiling zone is targeted, target the zone with higher index on same screen, or wrap to the first zone on the next screen.

### Temporary Zone Behavior

Each screen has exactly one temporary zone for floating a single managed window over the tiled layout.

When placed into the temporary zone, a window is centered and resized once. After that, the user may freely move/resize it without affecting tiled frames.

Placing another window into the temporary zone minimizes the previous occupant.

The temporary zone occupant is minimized when a non-placeholder managed window on the same screen becomes active/front-most. Temporary zones on other screens are unaffected.

When a managed window in a tiling zone is minimized by the user (emptying its zone), and that screen currently has a temporary-zone occupant, promote the temporary window into the newly emptied zone. (Minimizations performed as part of internal policies should not trigger this promotion.)

When a new tiling zone is created via an explicit add-zone action (e.g., `Control-Cmd-=`) on a screen that currently has a temporary-zone occupant, immediately move the temporary window into the newly created zone. (When a new zone is created as part of a drag/drop onto the add-zone indicator, do not auto-promote the temporary occupant since the dragged window is taking that new zone.)

### Resizing Zones

#### Resizing Empty or Occupied Zones (via zone resize bars)

Zones are resized by dragging a zone resize bar: a thin white separator located in the margin between zones. This bar is only visible when the mouse hovers over the margin between zones. Dragging it adjusts the layout ratios for the involved zones.

If an ActiveFit window in reveal mode (zone 2 or 3) would overlap a zone resize bar, the bars adapt so they do not interfere with that window: the vertical bar between zone 1 and zones 2/3 is shortened or hidden so it stays outside the reveal frame, and the horizontal bar between zones 2 and 3 is hidden whenever it would intersect an ActiveFit window in zone 2 or 3. When the window exits reveal mode (loses focus or moves to a different window), the bars return to the normal layout.

#### Resizing Managed Windows

If a zone contains a managed window, resizing that window manually (by dragging its edges) does **not** resize the zone. Instead, the window temporarily detaches from the strict zone frame, allowing the user to see content at a custom size. The window will snap back to the zone dimensions upon the next layout sync (e.g., when zones are added/removed/resized), or when the window loses focus.

While the user is dragging a zone resize bar, the rest of the zones should update live so the overall tiling responds immediately to the in-progress resize. When the drag completes, the resized zone and its neighbors should already reflect the final geometry, requiring no additional snap or jump.

For testing and automation, the REPL also exposes a `resize-zone <index> <x> <y> <width> <height>` command that resizes an empty zone using screen coordinates (before per-edge margins are applied—8px at the outer edges, 4px per zone along shared edges). The socket API mirrors this capability through a `resize-zone` method that accepts the zone index and a `frame` object with `x`, `y`, `width`, and `height` values.

### Repositioning and Resizing Window to Zone

When our window manager assigns a window to a zone, the window should be moved and resized to match the zone dimensions.
**Important:** When some windows are resized, they might not actually attain the dimensions requested. For example, a window might have a minimum width, etc. We should *not* keep on trying to resize them in an infinite loop. See below for the relevant ActiveFit feature.

### Dragging Windows Between Zones

Dragging behavior differs between tiled windows and temporary-zone (floating) windows.

**Tiled window drags:** When the user drags a managed window that is currently assigned to a tiling zone, Zonogy suspends reflows until mouse-up, shows non-interactive overlays for every tiling zone, and highlights the zone under the mouse cursor. The drop target is whichever tiling zone currently contains the cursor; if no zone contains it, no zone is highlighted. Dropping onto an empty zone moves the window there; dropping onto an occupied zone swaps the two windows (across screens if needed). If the system cannot determine a drop target—either because the cursor is outside every tiling zone or because the prospective target disappears mid-gesture—we cancel the drop and push the dragged window back through the normal placement pipeline.

If the source app destroys the dragged window mid-gesture (e.g., Chrome tab merges), we immediately tear down drag overlays and defer placing the replacement window until the app finishes creating it.

If a tiled window is dropped onto a temporary zone indicator, place it into that screen's temporary zone (replacing and minimizing any prior temporary occupant). The temporary zone indicator should highlight when the mouse is over it during drag.

**Temporary-zone window drags:** Default drags merely reposition the floating window (no zone overlays). Holding Control-Command promotes the drag into the normal zone overlay + drop pipeline. In this mode, dropping onto a tiling zone uses the usual replace pipeline, except that if the drop displaces an occupied window, the displaced window is minimized (it does not swap back into the temporary zone). You can start a normal temporary drag and then hold Control-Command to enter this mode; releasing Control-Command returns to normal temporary dragging.

Holding Control-Command during a tiled drag promotes it into a temporary-zone drag (the window is moved into the temporary zone immediately). Releasing Control-Command cancels the conversion and resumes the tiled drag.

If a window is dragged and dropped over a screen's add-zone indicator ("new zone" pill), we immediately add the zone and place the dragged window into it (works for both tiled and temporary-zone drags). During tab tear-out flows (e.g., Chrome creating a fresh window mid-drag), keep the original zone's occupant intact until the new window lands in the newly created zone.

### Drag and Drop on Placeholder Windows and the Add-Zone Indicator

Placeholder windows and the add-zone indicator accept external drops so the user can route content directly into a zone.

**Files:** When a file is dropped on a placeholder window, immediately target that placeholder's zone and pass the file to the system default application (Launch Services "open"). Dropping on the add-zone indicator first creates the new zone (which automatically sets it as the target), and then opens the file the same way.

**URLs:** Accept pasteboard URLs (including custom schemes such as `message:`) on both placeholder windows and the add-zone indicator. Targeting behavior mirrors the file path above. After targeting, open the URL with its default handler unless it is an HTTP(S) link.

**Web links:** For HTTP and HTTPS links, determine the default browser, create **a new window** in that browser, and load the URL there instead of invoking the generic opener. We currently support Safari, Chrome, Firefox, and Edge for the new-window automation.

### Minimize Active Window

Pressing Cmd-M minimizes the currently active/key window. This overrides any app-specific behavior for this shortcut to ensure consistent window minimization across all applications. **Exception**: When the Launcher is visible, Cmd-M removes the targeted zone instead; see SPECIFICATION-LAUNCHER.md. (The big picture of this behavior is that we can use Cmd-M for two purposes: to minimize a window and to remove a zone.)

Pressing Shift-Option-Control-Cmd-M performs a cursor-targeted action:

- If there is a managed (non-placeholder) window under the mouse pointer, minimize that window using the same behavior as the Cmd-M override (including zone removal, placeholder creation, and exiting ActiveFit reveal mode if applicable).
- Otherwise, if the mouse pointer is over an empty zone's placeholder, remove that zone.

### Application Hide

When an app is hidden (via MacOS's Cmd-H or any hide action), treat every currently unminimized managed window of that app as if it were minimized by the user. This means the same downstream behavior should occur. Implementation-wise, we achieve this by observing application hide notification and immediately unhiding the app and automatically minimizing its windows.

### Flip the Key Window to Another Screen

Pressing shortcut Control-Cmd-\ moves the currently active/key window to another screen (if there is more than one screen).

If the targeted zone is on another screen, then immediately move the key window into it, minimize any displaced window.

If the targeted zone is on the same screen as the active/key window then: We pick the first `NSScreen` that is not the key window's current screen; all behavior below refers to that destination screen. Choose the lowest-index empty zone on the destination screen, or if none exist, the highest-index occupied zone. Make that zone be target, and perform the move described above.

In either case, since the original zone of the window is now empty, it should become targeted after this.

### Startup

- **Initial target:** Tiling zone 1 on the primary display. After seeding completes, if no empty tiling zone exists anywhere, target the temporary zone on the primary display instead.
- On launch, Zonogy seeds tiling zones per screen. The initial zone count on each screen equals the number of unminimized windows on that screen (minimum 1, maximum 3); extra windows beyond 3 are minimized. Temporary zones start empty.
- Windows are assigned to zones in zone-index order by selecting the remaining window whose bounds overlap the zone the most (falling back to the left-most window if nothing overlaps).

## Special Features

### ActiveFit: Active Overflow Reveal for Key Windows

Some applications refuse to shrink below their minimum width/height, which means the standard zone-aligned frame can spill off-screen when the window lives in zone 2 or zone 3 (the right column). This is acceptable while the window is inactive, but when the user activates that window it must be temporarily repositioned so the entire frame fits within the display's visible bounds.

**Terminology:**

- **ActiveFit rest mode**: The window's top-left corner is anchored to the zone origin (with margins). The window may overflow off the right or bottom edge of the screen — this is the normal/default state when the window is *not* the active/key window.
- **ActiveFit reveal mode**: The window is shifted left and/or upward so the entire frame fits within the visible screen bounds. This state is entered when the window *becomes* the active/key window and qualifies for ActiveFit.

**Implementation requirements:**

1. ActiveFit only applies to non-placeholder windows assigned to zone 2 or zone 3 on any screen. Zone 1 never receives this treatment.
2. Attempt the normal zone-aligned move/resize first. Then determine whether ActiveFit is needed by anchoring the window's actual *post-resize* size to the zone's content origin (after margins). If the resulting predicted frame would extend beyond the screen's visible bounds (allow a ≤1 px tolerance), the window qualifies.
3. When a qualifying window becomes the active/key window, enter **reveal mode**: shift it left and/or upward just enough for the full frame to sit inside the screen's visible bounds. Do not shrink the window; this translation may cover neighboring zones temporarily.
4. When that window loses key status, leaves its zone, is minimized, or closes, exit reveal mode and return to **rest mode**: move the window back to its normal zone-anchored position so other zones reclaim their space.
5. ActiveFit adjustments should not fight the main zone-sync loop. While a window is in reveal mode, zone sync must skip reapplying the normal frame for that specific zone so the temporary positioning is preserved until the window deactivates.

This behavior makes oversized right-column windows usable without permanently disrupting the zone layout. The user-facing name of this capability is **ActiveFit**.

### UnderCovers Mode

When a screen has exactly one (empty) tiling zone, its placeholder shows a blue "⌄" button instead of "x". Clicking "⌄" closes that screen's placeholder window but keeps zone 1 logically present so Zonogy can still target it. In this UnderCovers state, unmanaged windows and desktop icons can surface. Target indicators remain visible and work normally.

This per-screen UnderCovers state ends (and the normal placeholder reappears) when any of the following occurs on that screen:

- A managed window is about to be placed into tiling zone 1.
- A zone is added.
- A zone is removed (including clear/reset variants).
- The "minimize window or remove zone at cursor" shortcut is used.

When UnderCovers is active, the first add-zone action on that screen just exits UnderCovers without changing the zone count; subsequent adds behave normally.

### Screen Management

**Active screen determination:** If the mouse pointer and `NSScreen.main` are the same screen, that screen is active. Otherwise, choose between the pointer screen and `NSScreen.main` by preferring the one that currently holds the targeted zone. (`NSScreen.main` returns the screen containing the window currently receiving keyboard input, or the screen with the menu bar if no window has focus.)

**Independent zone management:** Each screen maintains its own set of zones (1-3 per screen). Keyboard shortcuts for adding/removing zones (`Control-Cmd-=` and `Control-Cmd-[minus]`) operate on the currently active screen only.

**Screen detection:** Matches Amethyst: calculate each window's frame overlap with every screen via `CGRectIntersection` and choose the display with the largest intersection area (fall back to the origin-containing screen if no overlap).

**Display removal:** When a display is disconnected or otherwise disappears from `NSScreen.screens`, minimize every non-placeholder managed window that was on that display (instead of reassigning it to another screen). Close any placeholders tied to the removed display.

**Recapture after display/wake events:** After display topology changes or wake-from-sleep (see `SPECIFICATION-WAKE.md`), Zonogy runs a recapture pass. This pass captures any previously unseen windows and also identifies tracked windows that are unminimized but not currently in any zone (tiled or temporary); such windows are placed via the normal placement flow.

### WinShot Snapshots

WinShot allows users to save and restore window arrangement snapshots. Unlike virtual screens, the same window can appear in multiple snapshots.

**Creating Snapshots:**

- Automatically created when pressing Clear/Reset Zones shortcut (Control-Cmd-Space or variant) when the corresponding screen has managed windows in zones.
- Automatically created before restoring a different snapshot (if current windows differ from snapshot being restored), allowing the user to return to their previous arrangement.
- Explicitly created with Control-Cmd-/ shortcut on the active screen.
- Each snapshot stores: zone configuration (count and frames), windows in zones (including temporary zone), active window info, and a low-resolution screenshot.
- Snapshots are screen-specific (cannot restore across screens).
- Max 10 snapshots per screen; oldest removed when limit exceeded.
- A snapshot is removed when any window in it is closed.
- If creating a snapshot with the same exact windows as an existing one, the old snapshot is replaced.

**Chooser Window:**

- Control-Cmd-Tab shows a floating horizontal strip chooser (like Command-Tab) on the active screen.
- Hold Control-Cmd and repeatedly press Tab/Shift-Tab to cycle through snapshots in forward or reverse order (respectively).
- Escape key or click outside to cancel.
- Release Control-Cmd to restore the selected snapshot. Alternatively, click on a snapshot to immediately restore it.
- Red "x" button on each snapshot allows deletion (appears on hover).

**Snapshot Restoration:**

- Restores zone configuration to the saved count and sizes (ratios).
- Current windows not in the snapshot are minimized first (before unminimizing snapshot windows) to avoid visual overlap.
- Unminimizes windows that were minimized (but not closed).
- Windows are pre-positioned (resized and moved) before unminimizing for smooth animation (see "Accessibility API Workarounds" section).
- Activates the previously active window.

## Implementation Details

### Destroyed Window Detection

Not all applications emit didTerminateApplication notification upon closing (eg Find My). So we need to also monitor other notifications. Specifically, we do the following:

After events such as application termination, workspace focus changes, or accessibility notifications, `AppController` validates every affected PID. An external window is removed immediately when either the window server stops reporting its `CGWindowNumber` or the accessibility element returns an invalid-element error. If the initial pass finds no destroyed windows but the PID still owns managed windows, the controller schedules a short series of PID-scoped revalidations with exponential backoff (≈0.2 s → 3.2 s). Retries cancel as soon as every window disappears or the process exits; no global polling timer runs.

### Restore Protection Windows (WinShot + Sleep/Wake)

When restoring layouts from either sleep/wake snapshots or WinShot snapshots, we apply a short protection window so that internal restore operations do not fight normal layout behavior:

- The floating temporary-zone occupant is temporarily protected from auto-minimization triggered by focus shifts or new tiled placements on the same screen, so it is not immediately cleared while other windows are being recaptured.
- For ActiveFit candidate zones, we temporarily suppress ActiveFit during the restore layout pass and then evaluate it once for the active window after the restore settles. The active window is first restored to its zone-aligned frame; if it no longer fits there, a later ActiveFit pass may snap it into a reveal position.

### Additional Notes

- Placeholder windows need an interactive blue "x" control that sends a callback to remove the zone.
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

- **(Per-application) destroyed-window validation retries (PID-scoped):** After AX-relevant lifecycle events (window focus changes, application activation/deactivation/hide, screen-topology changes, REPL/socket “validate” commands), `ValidationRetryManager` schedules a short series of PID-scoped validation passes (≈0.2–3.2s backoff) when AX-based destroyed-window detection is inconclusive. These retries are cancelled when the process exits, when all windows are pruned, or when screens go to sleep (`handleScreensDidSleep` calls `cancelAllValidationRetries()`). See also §6 “Destroyed Window Detection” for a fuller description of this pipeline.
- **(Per-application) AX window-capture retries (PID-scoped):** When `AXWindowCreated` notifications fail to yield a manageable window (e.g., transient AX errors), `WindowCapturePipeline` schedules a small number of delayed recapture attempts per PID using `cancelAllRetries()` to tear them down when captures succeed, the app exits, or the system goes to sleep.
- **(Per-window) AX frame application retries:** When applying a zone-aligned frame via AX leaves a window off-screen or far from the requested geometry, `WindowController` schedules a one-shot delayed frame retry for that window. These per-window timers are cancelled whenever zone topology/geometry changes or when screens go to sleep so no stale frame targets are applied later.

### Window subrole for minimized windows

Some applications report the subrole for their minimized windows as AXDialogSubrole even if it later becomes kAXStandardWindowSubrole upon un-minimization. So for enumeration of windows to manage, we don't check subrole for minimized windows.

### Async unminimize after pre-positioning ("pre-move" feature)

When unminimizing a window that needs to appear at a specific position (e.g., restoring a WinShot snapshot or selecting a minimized window from Launcher), we first set the window's position and size while the window is still minimized. However, if we unminimize synchronously right after setting position/size, the window sometimes visually appears at its old location before snapping to the correct position. To address this, we default to async mode for unminimization.

## Launcher

For the application launcher and window switcher feature (Control-Command-Enter), see **[SPECIFICATION-LAUNCHER.md](SPECIFICATION-LAUNCHER.md)**.

## Developer Tools

### REPL and Socket API

For programmatic interaction with Zonogy (command-line REPL and Unix domain socket interface), see **[SPECIFICATION-REPL.md](SPECIFICATION-REPL.md)**.

### Debug Log File

Zonogy always writes debug logs to `/tmp/zonogy-debug.log`. AI agents should read only the tail of this log (e.g., `tail -500`) since it can grow large during long sessions.

### Time-travel Debug Logging

When I am running Zonogy (either in REPL, socket, or other modes) and notice incorrect behavior, I should be able to press "Control-Command-z". This keystroke should be intercepted by Zonogy and not passed to other apps. When the shortcut is invoked, we save the *last 10 seconds of the log prior to the invocation of the shortcut* to `./time_travel_log.txt` to help us debug the problem.

After the time travel log file is written, the log buffer should be cleared. This means that pressing "Control-Command-z" twice within a short time window would only generate the log *between* the two presses.

### Sleep/Wake State Recovery

The sleep/wake behavior and recovery pipeline are specified in `SPECIFICATION-WAKE.md`. This main specification only references it at a high level; all detailed rules, timing, and edge cases for sleep/wake live in that dedicated document.

### External Tool: `winmanmon`

For debugging purposes, it may be useful to see where all the windows are, whether they are minimized or not, and obtain other information about them. This can help us debug, for example, whether the window was successfully moved to its zone location. This is enabled by the following `winmanmon` command line tool, which displays for each window:
    - Application bundle identifier (e.g., "com.apple.Dictionary")
    - Accessibility Window ID (`CGWindowID`)
    - Title (may be empty)
    - Screen
    - Dimensions (x, y, width, height)
    - Is minimized? (T/F)
    - Subrole (e.g., kAXStandardWindowSubrole, kAXDialogSubrole)
    - isMovable (T/F) - whether window position can be modified
    - hasZoom (T/F) - whether window has a zoom button

(Certain applications and types of windows that we don't care about are excluded.)

The tool is available in the shell path.

The `--help` argument explains the functionality.

The source code at `/Users/dsolov/Documents/Development/VibeDevelopment/WindowManagerMonitor-claude` is also useful to us to understand how to efficiently read important properties of windows such as whether they have a zoom button, its subrole, and whether it is movable, etc.

### Reference Implementations

The source code for Amethyst tiling window manager (with my modifications) is at `/Users/dsolov/Documents/Development/VibeDevelopment/Amethyst`. This might be useful as a reference since it implements tiling and some of the functionality we are interested in. For parts of its functionality it relies on the Silica framework whose source code is at `/Users/dsolov/Documents/Development/VibeDevelopment/Silica`.

## Configuration

An optional `config.json` file lets users (a) specify bundle identifiers that the window manager should ignore entirely and (b) define per-application exception rules that tweak the default eligibility checks for specific apps. When present, it is discovered using the following search order:

1. The executable directory (sibling to the built binary)
2. The current working directory
3. `~/Library/Application Support/Zonogy/config.json`
4. `~/.zonogy/config.json`

The file schema:

```json
{
  "ignoredBundleIdentifiers": [
    "com.example.App",
    "org.example.OtherApp"
  ],
  "bundleExceptions": [
    {
      "bundleIdentifier": "com.example.HelperApp",
      "ignoreActivationPolicy": true,
      "ignoreZoomButtonRequirement": true
    }
  ]
}
```

Fields:

- `ignoredBundleIdentifiers` – optional array of bundle IDs that should be completely ignored by Zonogy. Windows belonging to these apps are never captured or managed.
- `bundleExceptions` – optional array of per-application exception rules. Each object has:
  - `bundleIdentifier` – the app's bundle identifier (e.g., `"com.apple.Dictionary"`).
  - `ignoreActivationPolicy` – when `true`, Zonogy ignores the app's `NSApplication.activationPolicy` check and may manage helpers/accessory apps that are not `.regular`.
  - `ignoreZoomButtonRequirement` – when `true`, Zonogy does not require the app's windows to expose a zoom button; such windows can still be managed if they pass the other criteria.
  - `hasMainWindow` – when `true`, the Launcher selects the window with the lowest Zonogy ID (first created) when the user presses Enter on this running app. When `false` or unset (default), the most recently active window is selected.

For every window considered, Zonogy logs which eligibility checks passed or failed (role, subrole, movability, zoom button, height ≥ 250px, and CGWindowID). These logs, combined with `bundleExceptions`, should be used to decide when a “weird” app needs a tailored exception. Unknown fields in `bundleExceptions` objects should be ignored so the schema can evolve without breaking existing configs.
