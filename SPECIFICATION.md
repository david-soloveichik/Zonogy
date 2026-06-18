# Zonogy Window Manager for MacOS

## Overview

Zonogy is a variation on a tiling window manager built around the concept of **zones**. Traditional tiling managers are “twitchy”: the layout constantly reflows as you open/close windows, causing distracting resizing and repositioning. Zonogy addresses this by keeping a set of tiling zones per screen that can remain present even when empty, so the layout is stable and the user can reserve space for future windows. At any time, one destination is **targeted**, and new/unminimized windows flow into that target predictably. Zonogy also includes a (per-screen) **floating zone** to float a single window above the tiled layout.

## Core Concepts

### Zones

Zonogy organizes managed windows into **zones**. Each screen has 1–3 **tiling zones** (indexed 1…zoneCount) that form the main layout, and one **floating zone** used for floating a single window above the tiled layout.

A zone contains at most one unminimized managed window or is empty. Minimized windows do not belong to any zone. (Throughout this specification, "managed window" refers to windows from other applications that Zonogy positions.)

Empty tiling zones are represented by placeholder windows (except in UnderCovers mode). Empty floating zones have no placeholder.

At any moment exactly one zone is targeted. Newly created or unminimized windows are placed into the targeted zone (moving across screens if needed).

If the targeted zone already holds a managed window, the new window replaces the occupant and the displaced window is minimized. (If the tiling zone is empty and represented only by a placeholder, that placeholder is closed.)

Detailed targeting controls, tiling layout rules, placeholder behavior, and floating-zone behavior are specified in **User Interactions** below.

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
5. All logging must report frames in screen coordinates

**Example for 3-zone layout on a 1080p display:**

- Zone 1 (left column): `{x: 0, y: 0, width: 960, height: 1080}` — starts at top-left
- Zone 2 (right-top): `{x: 960, y: 0, width: 960, height: 540}` — **y:0 is at the TOP**
- Zone 3 (right-bottom): `{x: 960, y: 540, width: 960, height: 540}` — y:540 is **BELOW** zone 2

Never mix coordinate systems or windows will be positioned incorrectly.

### **IMPORTANT: Screen Identity and Logging**

Zonogy has two different ways of referring to a “screen”, and mixing them causes very confusing logs and bugs:

- **`CGDirectDisplayID` (aka `displayId`)**: stable identifier used for all internal per-screen state (zone controllers, snapshots, floating zones, etc).
- **Screen index (0, 1, 2, …)**: user-facing identifier used in logs (matches `winmanmon` / `NSScreen.screens` ordering). This ordering can change when displays are added/removed/rearranged.

**Implementation/logging requirements:**

1. Never treat a `CGDirectDisplayID` as a screen index in logs (avoid messages like “screen \(displayId)”).
2. When logging a screen, prefer a single helper that formats something like `screen <index> (displayId <id>)` when helpful, so it’s obvious which identifier is being used.

### Window Management Criteria

We manage a window if it passes **all** of the following conditions (see `winmanmon` source code for how it collects this information):

- **Role: AXWindow** and, if the window is unminimized, **Subrole: AXStandardWindow** (ONLY AXStandardWindow; NOT AXDialogSubrole or any other subrole). (We do not perform the subrole check for minimized windows because some applications report them as AXDialogSubrole; see "Accessibility API Workarounds" below.) Apps whose windows report non-standard roles or subroles can opt in to management via `manageNonStandardWindows` (see Configuration below).
- **Title: any** (empty titles are allowed by default; apps can opt out via `disallowEmptyTitleWindows`)
- **isMovable: T** (window position can be modified)
- **hasZoom: T** (window has a zoom button)
- **Height: >= 250px** (window must be at least 250 pixels tall)
- **_AXUIElementGetWindow** returns a valid `CGWindowID` for the window

### Window Identifiers

Every managed window (from other applications) receives a sequential `windowId` used as the source of truth for zone assignments, even when the window also has a `CGWindowID` (obtained via `_AXUIElementGetWindow`). Placeholder windows do not have windowIds—they are owned directly by zones. Always log both identifiers when the CGWindowID value exists.

## User Interactions

### Tiling Layout and Spacing

Tiling zones have indexes (1, 2, 3). When tiling zones are added or removed on a screen, remaining zones reindex sequentially and the tiling zones on that screen are re-tiled to split the screen as follows:

- 1 zone: full screen (zone 1)
- 2 zones: left (zone 1) and right (zone 2)
- 3 zones: left (zone 1), right-top (zone 2), right-bottom (zone 3)

Both windows and placeholders preserve an 8 pixel buffer at the outer screen edges. When two zones share a boundary, they split that buffer evenly so the visible gap between their contents is exactly 8 pixels (each zone contributes 4 pixels along the shared edge) for a consistent grid.

### Placeholders

Placeholder windows are translucent, frameless stand-ins for empty tiling zones. They have a rounded rectangle border and no title bar or standard window controls. A large semi-translucent blue button in the upper-left corner shows "×" (to remove the zone) or "⌄" (to enter UnderCovers mode; see **Special Features**). When a placeholder's zone is targeted, its border is highlighted with a bluish tint to make the target destination visually clear.

Placeholders stay anchored to their zone: dragging their surface does not reposition them, and they cannot be resized by dragging their edges. Resize zones via zone resize bars (see **Resizing Zones**).

### Adding and Removing Zones

There are several ways to remove a zone, the main ones being:

- By pressing the blue "×" button on the placeholder window of an empty zone.
- By pressing a keyboard shortcut Control-Cmd-[minus].

When invoking Control-Cmd-[minus], never remove the zone containing the currently active (aka key) window. Among the remaining zones, remove one using this priority:

1. Prefer empty zones over occupied zones.
2. Prefer non-targeted zones over the targeted zone.
3. Break any remaining ties by choosing the zone with the highest index.

Removing a zone preserves the surviving tiling zones on that same screen in index order, so higher-index survivors collapse inward to fill the gap. If the removed zone contained a window, if no tiling zone remains for it on that screen after the collapse, minimize it instead.

Pressing Control-Cmd-0 performs that same shortcut-removal action repeatedly on the active screen until only one tiling zone remains.

If the currently active (key) managed window is a floating-zone occupant, Control-Cmd-0 collapses that window's screen to a single tiling zone (minimizing every tiled occupant on that screen) and promotes the floating window into tiling zone 1 on that screen.

The minimum number of zones is 1. In other words, we cannot remove the last zone. The maximum number of zones is 3 (for now).

**Example:** Suppose the user has 2 zones—zone 1 with window A and zone 2 with window B—and wants to remove zone 1. They minimize window A (causing a placeholder to appear in zone 1), then click the blue "×" on that placeholder. Zone 2 becomes zone 1, and window B shifts to fill the left side of the screen.

A zone can be added by pressing the global keyboard shortcut Control-Cmd-=. The new zone should be added with the highest index, and it should start out initially empty.

Each screen with fewer than 3 tiling zones also displays an add-zone indicator: a vertical pill (≈6 px wide, ≈⅓ screen height) on its right edge, vertically centered. Clicking this indicator adds a tiling zone to that screen.

Pressing Control-Cmd-Escape clears all zones on the active screen and empties the floating zone. If the zones are already empty on the active screen, then it resets to a one-zone configuration (just zone 1). After this clear/reset completes, target zone 1 on that screen. (With WinShot auto-save snapshots enabled, the pre-clear arrangement is captured first when managed windows are present. See [SPECIFICATION-WINSHOT.md](SPECIFICATION-WINSHOT.md).)

Pressing Shift-Control-Cmd-Escape performs the same steps, but works with the screen currently holding the mouse pointer.

### Targeting

**Targeting rule:** Exactly one zone (tiling zone or floating zone) is targeted at any moment. Newly created or unminimized windows are always placed into the targeted zone.

**Full-screen pause:** When a screen's active Space is showing a native macOS full-screen window, Zonogy pauses on that screen. Switching away from that full-screen Space or minimizing the full-screen window clears the pause. No Zonogy UI/overlays should appear there (placeholders, Launcher, targeting indicators, add‑zone indicator, zone resize bars, drag overlays, etc). Zones on that screen are not targetable; when a screen enters full‑screen mode, retarget using normal rules. (If all screens are full‑screen, target screen 0 (normal rules) as a last resort to maintain the invariant that one zone is always targeted.)

When a screen is full-screen and a managed window appears on it (opens or is unminimized):

- **Native full-screen** (the green-button kind that creates a dedicated Space): Place the window into the currently targeted zone (which by the retargeting rule lives on a different, non-paused screen) then re-raise the originating screen's full-screen window so macOS switches that screen back to its full-screen Space. This avoids interrupting what user was doing (eg watching full screen movie).
- **Otherwise** (non-native full-screen, or the all-screens-full-screen fallback): defer placement until the screen exits full-screen mode, then place the window on that same screen (into the lowest-index empty tiling zone, or its floating zone if none is empty).


Focus changes do not retarget zones by themselves. Targeting is controlled by the rules and shortcuts below, plus a small number of feature-specific options described in the Launcher, DockMenus, and CmdTab specifications.

**Target indicator UI (tiling zones):** If the current target is a tiling zone, that zone renders a slim translucent indicator (≈6 px tall, ≈⅓ the zone width) centered in the margin directly above the zone. When the targeted tiling zone is empty, its placeholder border is highlighted with a bluish tint (see **Placeholders**). When the targeted tiling zone is occupied, an analogous bluish border is drawn over the zone frame, on top of the occupant window, so the destination of the next window is apparent.

**Floating zone indicator UI:** Each screen renders a bottom-edge pill indicator for its floating zone (whether it's targeted or not). The indicator sits flush with the screen bottom so edge clicks hit it. If that floating zone is targeted, the indicator is highlighted. When a floating zone becomes targeted (or an explicit gesture re-selects the already-targeted floating zone), its indicator briefly flashes (enlarges and settles back to confirm the target). This is the floating-zone counterpart to the tiling-zone target change flash.

**Target change flash (tiling zones):** Whenever the targeted tiling zone changes a brief bluish border flash confirms the new target: empty tiling zones pulse the placeholder border; occupied tiling zones pulse their zone-frame border (settling into the persistent border described above). Explicit gestures (Control-Command-click, clicking a placeholder, or picking a zone in CmdTab) flash even when re-selecting the already-targeted zone. Removing a zone likewise confirms the surviving target with a flash. Creating a tiling zone does not flash, even though the new zone becomes targeted.

**Indicator click behavior:**

- Tiling zone indicator (shown only on the targeted tiling zone): clicking or double-clicking opens the Launcher.
- Floating zone indicator: clicking a non-targeted indicator targets that floating zone; clicking an already-targeted indicator opens the Launcher. Double-clicking targets that floating zone and opens the Launcher.

**Target selection:**

- Clicking a tiling zone placeholder window: target that tiling zone. Double-clicking also opens the Launcher.
- Control-Command + left-click any point within a tiling zone's bounds targets that tiling zone (showing the target change flash described above); the gesture is consumed before it reaches the underlying window. Control-Command + left-double-click also opens the Launcher. Exception: if the topmost window under the click belongs to an app with `disableControlCommandMouseGestures`, Zonogy does not intercept the click; Zonogy-owned UI (placeholders and indicators) still behaves normally.
- Whenever a tiling zone becomes empty because its window disappears (minimize, close, crash, etc), target that zone. Exception: if the zone became empty as a side effect of explicitly placing that window into a different destination (e.g., Launcher moving a window), preserve the user's intended target (do not retarget to the source zone).
- When a new tiling zone is created on a screen: always target the lowest-index empty tiling zone on that screen.
- Whenever a window is placed into the targeted tiling zone: retarget using this priority:
  1. Lowest-index empty tiling zone on the same screen
  2. Lowest-index empty tiling zone on a different screen (tie-break by screen index; lower is preferred)
  3. Floating zone on the same screen
  4. Floating zone on a different screen (tie-break by screen index; lower is preferred)
- If a floating zone is filled: keep the current target.
- If a floating zone is emptied because its window is minimized or closed (etc): If the current target is another floating zone (e.g., on a different screen), retarget to the now-empty floating zone. (Conceptually, floating-zone emptying is "weaker" than tiling-zone emptying as it never steals targeting from a tiling zone, only from another floating zone.)
- If the targeted tiling zone is removed: retarget using the same priority order as above.
- If the targeted destination becomes invalid (zone removed, screen removed, etc): repair it using the same priority order as above.

**Target navigation shortcuts:**

- Control-Command with an arrow key (Up, Down, Left, or Right) moves the target to the nearest zone in that physical direction. Left and Right move only among tiling zones (when a tiling zone is targeted) or only among floating zones (when a floating zone is targeted). Up and Down move among all zones and are the way to switch between tiling and floating. Each zone is placed by its true on-screen rectangle; the floating zone sits at the location of its bottom-edge bar.
- If no zone lies in the pressed direction the target does not change. Zones on a screen that is paused for a full-screen window are not targetable and are skipped. (See [SPECIFICATION-IMPLEMENTATION.md](SPECIFICATION-IMPLEMENTATION.md) for the precise candidate-selection and tie-breaking rules.)
- Control-Cmd-Return: Toggle Target Zone with Focused Window. If the zone holding the focused window is not the current target, target that zone (a tiling zone, or the floating zone if the focused window is floating). If it is already the target, advance the target off it using the same priority applied after a window fills the targeted zone. It also works while the Launcher or CmdTab chooser is open — the chooser stays open and re-anchors to the new target — and does nothing when no managed window is focused in a zone. Inside a chooser the retarget is tentative: cancelling the chooser restores the target it started with (and in CmdTab, choosing an already-open window does too).
- [No default shortcut]: If the currently targeted zone (tiling or floating) contains a managed window, make that window frontmost.

### Floating Zone Behavior

Each screen has exactly one floating zone for floating a single managed window over the tiled layout.

When placed into the floating zone, a window is centered and sized to the first available of: its remembered floating-zone size, its current size, or 55% of the screen's visible bounds, clamped between 1/3 and 80% of those bounds. After placement, the user may freely move/resize it without affecting tiled frames.

Zonogy records a window's floating-zone size on first placement and updates it on each user resize in the floating zone. The size survives promotions to tiling zones and is cleared only when the window is destroyed.

Placing another window into the floating zone minimizes the previous occupant.

#### Automatic minimization of floating zone occupant

The floating zone occupant is minimized when it becomes *occluded* by an occupied tiling zone (on the same screen). For this rule, test overlap against the tiling zone's frame, not the tiling window's current frame. This means temporary tiling-window geometry changes outside the zone frame (for example, ActiveFit reveal mode) do not increase the floating window's measured occlusion. Ignore tiny overlaps (e.g., window shadows) when computing occlusion.

#### Promotion to tiling zone

When a tiling zone on a screen becomes empty and that screen has a floating-zone occupant, promote the floating window into the emptied zone **only if the floating window’s current frame overlaps the emptied zone’s frame**. Exception: If the tiling zone became empty because the user explicitly moved that zone’s window into the floating zone (e.g., by dragging onto the floating zone indicator, by Control-Command drag promotion, or by placing it into the floating zone via the Launcher), do not promote the floating-zone occupant in response to that same emptying event.

When a new tiling zone is created on a screen, promote the floating-zone occupant into that zone if its current frame overlaps the new zone's frame (ignoring tiny overlaps). If there is no overlap, the floating-zone occupant stays as is. (When a new zone is created as part of a drag/drop onto the add-zone indicator, do not auto-promote the floating occupant since the dragged window is taking that new zone.)

If an empty-zone placeholder is activated and that tiling zone's frame overlaps the floating-zone occupant (on the same screen), promote the floating window into that tiling zone.

### Resizing Zones

#### Resizing Empty or Occupied Zones (via zone resize bars)

Zones are resized by dragging a zone resize bar: a thin white separator located in the margin between zones. This bar is only visible when the mouse hovers over the margin between zones. Dragging it adjusts the layout ratios for the involved zones. During a drag, a dedicated overlay bar tracks the mouse directly (independent of window repositioning) so the bar visual stays smooth even when managed windows lag behind.

If an ActiveFit window in reveal mode (zone 2 or 3) would overlap a zone resize bar, the bars adapt so they do not interfere with that window: the vertical bar between zone 1 and zones 2/3 is shortened or hidden so it stays outside the reveal frame, and the horizontal bar between zones 2 and 3 is hidden whenever it would intersect an ActiveFit window in zone 2 or 3. When the window exits reveal mode (loses focus or moves to a different window), the bars return to the normal layout.

If the front-most managed window on a screen would overlap a zone resize bar, the bars adapt so they do not interfere with that active window: the vertical bar between zone 1 and zones 2/3 is hidden whenever it would intersect a front-most zone‑1 window, and the horizontal bar between zones 2 and 3 is shortened (or hidden if fully covered) so it stays outside the front‑most window (zone 1/2/3). Ignore small overlaps (e.g., window shadows) when computing these intersections. Recompute these bar adjustments immediately when the active/front‑most window changes (including app activation) and after a resize drag completes.

When the floating zone is occupied on a screen, hide the zone resize bars that the floating zone window would overlap. Bars that do not intersect the floating window remain visible. (During an active resize drag, the dragged bar is never hidden by this rule.)

When an unmanaged window has focus on a screen, hide all zone resize bars on that screen to avoid overlapping the unmanaged window.
For this rule, and Launcher auto-show suppression, unmanaged focus must be confirmed (with retries) as described in [SPECIFICATION-IMPLEMENTATION.md](SPECIFICATION-IMPLEMENTATION.md).

**Pinned resize bar mode:** When a placeholder is activated (e.g. clicked), zone resize bars on that screen enter pinned mode (per-screen). We still avoid having resize bars that (substantially) overlap any managed window by resizing them, but a bar cannot shrink below the extent of its adjacent placeholder windows or be hidden entirely—placeholder boundaries serve as the minimum visible region for each bar. Pinned mode exits when (1) a managed window becomes active, or (2) the user clicks outside any visible Zonogy-owned window.

#### Resizing Managed Windows

If a zone contains a managed window, resizing that window manually (by dragging its edges) does **not** resize the zone.

By default, a manual resize is temporary: the window detaches from the strict zone frame, allowing the user to see content at a custom size, and then snaps back to the zone dimensions when it loses focus or on the next layout sync that changes that screen's tiling geometry (for example, adding/removing a zone or dragging a zone resize bar).

There is an option in Zonogy Preferences called **Sticky Resize** to remember manual tiled-window sizes until that screen's tiling geometry changes. With this option enabled, a manually resized tiled window still returns to its normal zone-aligned inactive frame when another window becomes active, but when that same window becomes active again Zonogy restores its remembered manual size instead of the zone size. If zones are resized on a screen, clear every remembered manual size on that screen. Emptying a zone or moving a window to a different zone also clears the remembered manual size for that window. Dropping a tiled window back into its existing tiling zone also clears its remembered manual size.

While the user is dragging a zone resize bar, the rest of the zones should update live so the overall tiling responds immediately to the in-progress resize. When the drag completes, the resized zone and its neighbors should already reflect the final geometry, requiring no additional snap or jump. After the drag completes, run the standard occlusion check for the floating-zone occupant on that screen (tiling windows may now occlude it).

### Repositioning and Resizing Window to Zone

When our window manager assigns a window to a zone, the window should be moved and resized to match the zone dimensions.
**Important:** When some windows are resized, they might not actually attain the dimensions requested. For example, a window might have a minimum width, etc. We should *not* keep on trying to resize them in an infinite loop. See below for the relevant ActiveFit feature.

Per-app exception: applications may opt into `doNotResizeWidth`. For those windows, Zonogy still moves them to the zone origin and applies the target height, but preserves the current width instead of attempting to change it. ActiveFit should treat these windows naturally, as though they cannot be resized narrower.

### Dragging Windows Between Zones

Dragging behavior differs between tiled windows and floating-zone (floating) windows.

**Tiled window drags:** When the user drags a managed window that is currently assigned to a tiling zone, Zonogy suspends reflows until mouse-up, shows non-interactive overlays for every tiling zone, and highlights the zone under the mouse cursor. The drop target is whichever tiling zone currently contains the cursor; if no zone contains it, no zone is highlighted. Dropping onto an empty zone moves the window there; dropping onto an occupied zone swaps the two windows (across screens if needed). If the system cannot determine a drop target—either because the cursor is outside every tiling zone or because the prospective target disappears mid-gesture—we cancel the drop and push the dragged window back through the normal placement pipeline.

If the source app destroys the dragged window mid-gesture (e.g., Chrome tab merges), we immediately tear down drag overlays and defer placing the replacement window until the app finishes creating it.

If a tiled window is dropped onto a floating zone indicator, place it into that screen's floating zone (replacing and minimizing any prior floating occupant). The floating zone indicator should highlight when the mouse is over it during drag.

**Floating-zone window drags:** Default drags merely reposition the floating window (no zone overlays), except when the cursor is over an empty tiling zone (placeholder): in that case, the drag automatically behaves as a promoted drag — showing zone overlays and highlighting the empty zone as a drop target. Dropping onto the empty zone places the window there. Moving the cursor away from the empty zone (or over an occupied zone) reverts to normal repositioning.

Holding Control-Command promotes the drag into the full zone overlay + drop pipeline for occupied zones, but the behavior is inverted for empty zones: Control-Command over an empty zone merely repositions the floating window (no drop). In this mode, dropping onto an occupied tiling zone uses the usual replace pipeline, except that if the drop displaces an occupied window, the displaced window is minimized (it does not swap back into the floating zone). You can start a normal floating drag and then hold Control-Command to enter this mode; releasing Control-Command returns to normal floating dragging.

Holding Control-Command during a tiled drag promotes it into a floating-zone drag (the window is moved into the floating zone immediately). Releasing Control-Command cancels the conversion and resumes the tiled drag.

If a window is dragged and dropped over a screen's add-zone indicator ("new zone" pill), we immediately add the zone and place the dragged window into it (works for both tiled and floating-zone drags). During tab tear-out flows (e.g., Chrome creating a fresh window mid-drag), keep the original zone's occupant intact until the new window lands in the newly created zone.

### Drag and Drop on Placeholder Windows and the Add-Zone Indicator

Placeholder windows and the add-zone indicator accept external drops so the user can route content directly into a zone.

Dragging external content over an empty-zone placeholder shows the same full-screen blue zone-overlay UI used for tiled-window drags, with that placeholder's zone highlighted.

Holding Control-Command during an external drag over an **occupied** tiling zone (or empty-zone placeholder) temporarily promotes that gesture into the same full-screen zone-overlay UI used for tiled-window drags. Dropping onto an occupied tiling zone in this mode first empties that zone by minimizing its current occupant, then treats the drop exactly as though it landed on that zone's empty placeholder window. Exception: if the source app that began the drag has `disableControlCommandMouseGestures`, Zonogy does not promote/intercept that Control-Command external drag; normal placeholder/add-zone behavior still applies.

**Files:** When a file is dropped on a placeholder window, immediately target that placeholder's zone and pass the file to the system default application (Launch Services "open"). Dropping on the add-zone indicator first creates the new zone, targets the lowest-index empty tiling zone on that screen, and then opens the file the same way.

**URLs:** Accept pasteboard URLs (including custom schemes such as `message:`) on both placeholder windows and the add-zone indicator. Targeting behavior mirrors the file path above. After targeting, open the URL with its default handler unless it is an HTTP(S) link.

**Web links:** For HTTP and HTTPS links, determine the default browser, create **a new window** in that browser, and load the URL there instead of invoking the generic opener. We currently support Safari, Chrome, Firefox, and Edge for the new-window automation.

### Minimize Active Window

Pressing Cmd-M minimizes the currently active/key window. This overrides any app-specific behavior for this shortcut to ensure consistent window minimization across all applications. **Exception**: When the Launcher is visible, Cmd-M (or Cmd-W) removes the targeted zone instead; see SPECIFICATION-LAUNCHER.md. (The big picture of this behavior is that we can use Cmd-M for two purposes: to minimize a window and to remove a zone.)

Pressing Control-Cmd-M performs a cursor-targeted action:

- If there is a managed (non-placeholder) window under the mouse pointer, minimize that window using the same behavior as the Cmd-M override (including zone removal, placeholder creation, and exiting ActiveFit reveal mode if applicable).
- Otherwise, if the mouse pointer is over an empty zone's placeholder, remove that zone.

### Application Hide

When an app is hidden (via MacOS's Cmd-H or any hide action), treat every currently unminimized managed window of that app as if it were minimized by the user. This means the same downstream behavior should occur. Implementation-wise, we achieve this by observing application hide notification and immediately unhiding the app and automatically minimizing its windows.

### Startup

- **Initial target:** Tiling zone 1 on the primary display. After seeding completes, if no empty tiling zone exists anywhere, target the floating zone on the primary display instead.
- On launch, Zonogy seeds tiling zones per screen. The initial zone count on each screen equals the number of unminimized windows on that screen (minimum 1, maximum 3); extra windows beyond 3 are minimized. Floating zones start empty.
- Windows are assigned to zones in zone-index order by selecting the remaining window whose bounds overlap the zone the most (falling back to the left-most window if nothing overlaps).

## Special Features

### ActiveFit: Active Overflow Reveal for Key Windows

Some applications refuse to shrink below their minimum width/height, which means the standard zone-aligned frame can spill off-screen when the window lives in zone 2 or zone 3 (the right column). This is acceptable while the window is inactive, but when the user activates that window it must be temporarily repositioned so the entire frame fits within the display's visible bounds.

**Terminology:**

- **ActiveFit rest mode**: The window's top-left corner is anchored to the zone origin (with margins). The window may overflow off the right or bottom edge of the screen — this is the normal/default state when the window is *not* the active/key window.
- **ActiveFit reveal mode**: The window is shifted left and/or upward so the entire frame fits within the visible screen bounds. This state is entered when the window *becomes* the active/key window and qualifies for ActiveFit.

**Implementation requirements:**

1. ActiveFit only applies to non-placeholder windows assigned to zone 2 or zone 3 on any screen. Zone 1 never receives this treatment.
2. Determine the candidate active size for the window. Normally this is the window's actual *post-resize* size after the standard zone-aligned move/resize. However, if the Sticky Resize option is enabled, and this zone has a remembered manual size for its current occupant, use that remembered size instead. Anchor the candidate size to the zone's content origin (after margins) and determine whether the resulting predicted frame would extend beyond the screen's visible bounds (allow a ≤1 px tolerance). If it would, the window qualifies for ActiveFit.
3. When a qualifying window becomes the active/key window, enter **reveal mode**: first apply the candidate active size (zone size or remembered manual size), then shift it left and/or upward just enough for the full frame to sit inside the screen's visible bounds. Do not shrink the window; this translation may cover neighboring zones temporarily.
4. When that window loses key status, leaves its zone, is minimized, or closes, exit reveal mode and return to **rest mode**: move the window back to its normal zone-anchored position so other zones reclaim their space.
5. ActiveFit adjustments should not fight the main zone-sync loop. While a window is in reveal mode, zone sync must skip reapplying the normal frame for that specific zone so the temporary positioning is preserved until the window deactivates.

This behavior makes oversized right-column windows usable without permanently disrupting the zone layout. The user-facing name of this capability is **ActiveFit**.

### UnderCovers Mode

When a screen has exactly one (empty) tiling zone, its placeholder shows a blue "⌄" button instead of "×". Clicking "⌄" closes that screen's placeholder window but keeps zone 1 logically present so Zonogy can still target it. In this UnderCovers state, unmanaged windows and desktop icons can surface. Target indicators remain visible and work normally. If the Launcher is open, dismiss it when entering UnderCovers so it doesn't cover the desktop.

This per-screen UnderCovers state ends (and the normal placeholder reappears) when any of the following occurs on that screen:

- A managed window is about to be placed into tiling zone 1.
- A zone is added.
- A zone is removed (including clear/reset variants).
- The "minimize window or remove zone at cursor" shortcut is used.

When UnderCovers is active, the first add-zone action on that screen just exits UnderCovers without changing the zone count; subsequent adds behave normally.

### Screen Management

**Active screen determination:** If the mouse pointer and `NSScreen.main` are the same screen, that screen is active. Otherwise, choose between the pointer screen and `NSScreen.main` by preferring the one that currently holds the targeted zone. (`NSScreen.main` returns the screen containing the key window, or the primary screen if no key window exists.)

**Independent zone management:** Each screen maintains its own set of zones (1-3 per screen). Keyboard shortcuts for adding/removing zones (`Control-Cmd-=` and `Control-Cmd-[minus]`) operate on the currently active screen only.

**Screen detection:** Matches Amethyst: calculate each window's frame overlap with every screen via `CGRectIntersection` and choose the display with the largest intersection area (fall back to the origin-containing screen if no overlap).

**Display removal:** When a display is disconnected or otherwise disappears from `NSScreen.screens`, minimize every non-placeholder managed window that was on that display (instead of reassigning it to another screen). Close any placeholders tied to the removed display.

**Recapture after display/wake events:** After display topology changes or wake-from-sleep (see `SPECIFICATION-WAKE.md`), Zonogy runs a recapture pass. This pass captures any previously unseen windows and also identifies tracked windows that are unminimized but not currently in any zone (tiled or floating); such windows are placed via the normal placement flow. The pass also handles floating-zone occupants whose live position no longer sits on the screen their floating slot is booked against (which can happen when a display reattaches and the system relocates the window): such an occupant is minimized.

### WinShot Snapshots

For the snapshot save/restore feature (Control-Cmd-Tab chooser, Control-Cmd-/ to save), see **[SPECIFICATION-WINSHOT.md](SPECIFICATION-WINSHOT.md)**.

## Implementation Details and Accessibility API Workarounds

For implementation details (destroyed window detection, floating zone protection, notification suppression) and accessibility API workarounds (retry mechanisms, subrole handling, async unminimize), see **[SPECIFICATION-IMPLEMENTATION.md](SPECIFICATION-IMPLEMENTATION.md)**.

## Launcher

For the application launcher and window switcher feature (Control-Command-Space), see **[SPECIFICATION-LAUNCHER.md](SPECIFICATION-LAUNCHER.md)**.

## DockMenus

For DockMenus (hover/click integration with the macOS Dock), see **[SPECIFICATION-DOCKMENUS.md](SPECIFICATION-DOCKMENUS.md)**.

## CmdTab

For the CmdTab window switcher feature, see **[SPECIFICATION-CMDTAB.md](SPECIFICATION-CMDTAB.md)**.

## Developer Tools

### Debug Preferences

Zonogy Preferences includes a **Debug** tab with four independent debug toggles, all **off by default**:

- Save debug log to file (`/tmp/zonogy-debug.log`)
- Show Dock debug rectangle
- Show full-screen debug rectangles
- Disable pre-position of minimized windows prior to unminimize

Changes apply immediately while Zonogy is running.

The "Disable pre-position…" toggle suppresses the optimization that moves a minimized window to its destination zone frame before unminimizing it. When the toggle is on, the window is positioned only after it is unminimized, which can be useful for debugging pre-position-related issues.

When "Save debug log to file" is off, Zonogy does not write to `/tmp/zonogy-debug.log` and does not modify any existing file at that path.
When this toggle is turned on, Zonogy clears `/tmp/zonogy-debug.log` before writing new entries.

### Debug Log File

When "Save debug log to file" is enabled, Zonogy writes debug logs to `/tmp/zonogy-debug.log`. AI agents should read only the tail of this log (e.g., `tail -500`) since it can grow large during long sessions.

The Debug tab displays the exact path/name for both the regular debug log and the time-travel debug log.

### Time-travel Debug Logging

When I am running Zonogy and notice incorrect behavior, I should be able to press "Control-Command-z". This keystroke should be intercepted by Zonogy and not passed to other apps. When the shortcut is invoked, we save the *last 10 seconds of the log prior to the invocation of the shortcut* to `/tmp/zonogy-debug-time-travel.log` to help us debug the problem.

Time-travel log capture via the keyboard shortcut should always be available and does not depend on any Debug tab toggle.

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

## Configuration

Zonogy uses a single user-editable configuration file, seeded from bundled defaults on first launch.

### Configuration Loading

1. **Bundled defaults** – `Resources/defaults.json` is included in the app bundle and provides sensible defaults for common applications.
2. **User config** – `~/Library/Application Support/Zonogy/config.json` is the active configuration file.

On launch, if the user config file does not exist, it is created by copying the bundled defaults. The user config is the single source of truth—users edit it directly to customize behavior.

### File Schema

```json
{
  "ignoredBundleIdentifiers": [
    "com.example.App",
    "org.example.OtherApp"
  ],
  "deriveBundleIdFromPathForProcesses": [
    "java"
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
- In Preferences → Exceptions, each listed app exposes an **Ignore this application altogether** toggle backed by `ignoredBundleIdentifiers`. When enabled, all other exception controls for that app are disabled.
- `deriveBundleIdFromPathForProcesses` – optional array of executable names (process names) for which Zonogy derives the bundle identifier by walking up the executable path to find a containing `.app` or `.bundle` directory and reading its `Info.plist`. Useful for Java apps (e.g., Minecraft) where the `java` process is launched from within a JRE bundle but macOS doesn't report a bundle identifier. The default configuration includes `"java"`.
- `bundleExceptions` – optional array of per-application exception rules. Each object has:
  - `bundleIdentifier` – the app's bundle identifier (e.g., `"com.apple.Dictionary"`).
  - `ignoreActivationPolicy` – when `true`, Zonogy ignores the app's `NSApplication.activationPolicy` check and may manage helpers/accessory apps that are not `.regular`.
  - `ignoreZoomButtonRequirement` – when `true`, Zonogy does not require the app's windows to expose a zoom button.
  - `requireActiveZoomButton` – when `true`, a window's zoom button must be enabled (not grayed out) for Zonogy to manage it. (Has no effect when `ignoreZoomButtonRequirement` is `true` and the window has no zoom button at all.)
  - `ignoreHeightRequirement` – when `true`, Zonogy does not require the app's windows to be at least 250px tall.
  - `manageNonStandardWindows` – when `true`, Zonogy manages this app's windows even when they report a non-standard accessibility role (e.g., `AXUnknown`) or subrole (e.g., `AXDialog`) instead of the usual `AXWindow` / `AXStandardWindow`. The remaining criteria (movable, zoom button, height) still apply. Useful for some Adobe apps.
  - `disallowEmptyTitleWindows` – when `true`, Zonogy ignores windows with empty titles from this app. By default, empty-title windows are managed.
  - `hasMainWindow` – preferred-window rule for Launcher and DockMenus when a running app has managed windows: `true` selects the lowest `CGWindowID`.
  - `snapToZoneOnSelfResize` – when `true`, if the app resizes one of its tiled windows internally (e.g., a panel opening/closing), Zonogy immediately snaps the window back to the zone frame. (User edge-drag resizes still follow the manual-resize behavior described above.)
  - `doNotResizeWidth` – when `true`, Zonogy preserves the window's current width during zone-aligned moves/resizes instead of attempting to apply the zone width. Height and position still update normally.
  - `disableControlCommandMouseGestures` – when `true`, Zonogy does not consume that app's Control-Command click targeting or Control-Command external-drag promotion/interception; the app receives those gestures normally instead.
  - `excludedWindowTitles` – array of window titles to exclude from management. Windows with titles exactly matching any string in this list will be ignored.

For every window considered, Zonogy logs which eligibility checks passed or failed (role, subrole, title, movability, zoom button, height ≥ 250px, and CGWindowID). These logs, combined with `bundleExceptions`, should be used to decide when a “weird” app needs a tailored exception. Unknown fields in `bundleExceptions` objects should be ignored so the schema can evolve without breaking existing configs.
