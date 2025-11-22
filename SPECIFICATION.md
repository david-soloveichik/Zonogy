# Zonogy Window Manager for MacOS

## 1. Overview

Zonogy is a variation on a tiling window manager. In particular, it uses the concept of "zones" to give the user more control over tiling, essentially allowing reserving space for future windows. This also is meant to overcome a major annoyance with tiling window managers in that there is too much resizing and repositioning of windows and users close and open new windows.

## 2. Core Concepts

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

- **Subrole: AXStandardWindow** (ONLY AXStandardWindow; NOT AXDialogSubrole or any other subrole)
- **isMovable: T** (window position can be modified)
- **hasZoom: T** (window has a zoom button)
- **Height: >= 250px** (window must be at least 250 pixels tall)
- **_AXUIElementGetWindow** returns a valid `CGWindowID` for the window

### Window Identifiers

Every managed window (placeholders, and other applications' windows) gets a sequential `windowId` that the zone controller uses as its source of truth, even when the window also has a `CGWindowID` (obtained via `_AXUIElementGetWindow`). Placeholder panes never receive a `CGWindowID` and real windows can temporarily lack one, so always retain the internal `windowId` while logging both identifiers whenever the CGWindow value exists.

## 3. Zones

### Zone Abstraction Basics

A zone can either contain an (unminimized) window or be considered empty. There can be at most one window per zone. Minimized windows do not belong to any zone.
Each zone has an index (for example, if there are 3 zones, then the indexes are: 1, 2, and 3).

### Zone Visual Representation

If a zone contains a window, then that window simply "represents" the zone and there is no placeholder window. (Note that the size of the window may not match the size of the zone. For example, certain windows cannot be resized arbitrarily.)

Every empty zone should have a placeholder window created by our window manager. The placeholder windows should be semi-translucent, with no text. They should not have a title bar or any of the normal buttons (i.e., minimize, close, zoom). Instead there should be a blue button with an "x" in it, looking similar to a normal close button but larger and semi-translucent. Clicking this button should remove this zone. The border of the placeholder window should be a rounded rectangle.

Both normal windows and placeholder windows should preserve an 8 pixel buffer at the outer screen edges. When two zones share a boundary, they should split that buffer evenly so the visible gap between their contents is exactly 8 pixels (each zone contributes 4 pixels along the shared edge) for a consistent grid.

Placeholder windows must stay anchored to their zone. Dragging their surface should not reposition them; interaction is limited to resizing from their edges.

**Usage example**: Suppose the user starts with 2 zones, zone 1 containing window A and zone 2 containing window B. To get rid of zone 1 the user can take the following actions: minimize window A, which leads to the placeholder window appearing, and then clicking on the blue "x" button on the placeholder window. Clicking the placeholder itself (outside the button) will set that zone as the targeted zone before removal if it was not already targeted.

### Layout Rules

Whenever zones are added or removed on a screen, the dimensions of the remaining zones on that screen should be adjusted. Intuitively, they should be re-"tiled" to split the screen. The tiling is as follows:

- 1 zone: full screen (zone 1)
- 2 zones: split the screen into left (zone 1) and right (zone 2)
- 3 zones: split the screen into left (zone 1) and right/top (zone 2), right/bottom (zone 3)

### Targeted Zone

Exactly one zone across all screens is the *targeted zone* at any moment. Newly created or unminimized windows are *always* placed into this targeted zone, even if the window originates from another screen; windows are moved across screens as needed to satisfy this rule. If the targeted zone is not empty, then the new window replaces the old in the targeted zone. For the smoothest UI effect, we want to first move the new window to the right location, and then minimize the old window.

**Targeted zone selection:** ( in this section "zone" refers to just normal, not-temporary zones only; see below for temporary zones)

- Launching: target zone 1 on the primary display.
- Clicking any zone placeholder window or a zone's target indicator (see below): target exactly that zone.
- Control-Command + left-click anywhere inside a zone (occupied window, placeholder, or empty space) targets that zone; the gesture is consumed before it reaches the underlying application window.
- Whenever a normal (non-temporary) zone becomes empty because its window disappears (minimize, close, crash, or any other disappearance), immediately target that zone.
- When a new normal zone is created: target that new zone if the current target is filled or is an empty zone with a higher index; otherwise keep the current target.
- Whenever the targeted zone is filled: if another empty (normal, not-temporary) zone exists, retarget to the empty zone with the lowest index; if none exist, keep the zone you just filled targeted.
- If the targeted zone is removed: retarget to the lowest-index empty zone if there is one; otherwise choose the occupied zone with the highest index.

**Target indicator UI:** Every zone renders a slim translucent indicator (≈6 px tall, ≈⅓ the zone width) centered in the margin directly above the zone. The targeted zone's indicator glows brighter to communicate focus. Indicators respond to clicks to retarget zones.

**Add-zone indicator UI:** Each screen with fewer than 3 zones displays a vertical indicator (≈6 px wide, ≈⅓ screen height) on its right edge, vertically centered. Clicking this indicator adds a new zone to that specific screen.

### Initial Startup Behavior

When Zonogy starts, if there are already open (unminimized) eligible windows, they are immediately managed using the same placement rules as if they had appeared after launch. The initial number of zones on each screen should correspond to the number of open windows on that screen (up to max of 3; additional windows should be minimized). Run the following seeding flow independently per screen:

1. For each zone in order of its index, pick the remaining window whose bounds overlap the zone the most; when nothing overlaps, fall back to the left-most remaining window.
2. Send that window through the standard placement flow, remove it from the pool, and repeat until every zone is seeded or no eligible windows remain.

There must always be at least one zone per screen even if there is no initial window on that screen at startup. (For efficient window enumeration examples, see the source code of `winmanmon`.)

## 4. User Interactions

### Adding and Removing Zones

When adding or removing zones, the remaining zones should be reindexed. For example, if there are zones 1, 2, 3, and I remove zone 1, then zone 2 should become zone 1, and zone 3 should become zone 2.

There are two ways to remove a zone:

- By pressing the blue "x" button on the placeholder window of an empty zone.
- By pressing a keyboard shortcut Control-Cmd-[minus].

When invoking Control-Cmd-[minus], never remove the zone containing the currently active (aka key) window. Among the remaining zones, remove one using this priority: (1) prefer empty zones over occupied zones, (2) prefer non-targeted zones over the targeted zone, (3) break any remaining ties by choosing the zone with the highest index.

The minimum number of zones is 1. In other words, we cannot remove the last zone. The maximum number of zones is 3 (for now).

A zone can be added by pressing the global keyboard shortcut Control-Cmd-=. The new zone should be added with the highest index, and it should start out initially empty.

Pressing Control-Cmd-Space clears all zones on the active screen and empties the temporary zone. If the zones are already empty on the active screen, then it resets to a one-zone configuration (just zone 1). More specifically:
- Empty the temporary zone on the active screen (minimize the window in it if there is one).
- If all zones on the active screen are already empty, reduce the zone count to 1.
- Otherwise, minimize all windows on the active screen (making all zones empty).
- After this clear/reset completes, target zone 1 on that screen (regardless of prior target).
- Pressing Shift-Option-Control-Cmd-Space performs the same steps, but targets the screen currently holding the mouse pointer (fall back to the active screen only if the pointer is outside every managed display).

### Resizing Zones

#### If a zone is empty (contains a placeholder window)

The placeholder window can be resized. Resizing it, resizes the zone and re-adjusts the other zones appropriately.

The resize affordances should only allow motions that can actually change the zone layout. For example, when zone 1 is the left-most column its bottom edge cannot be dragged vertically—only its right edge can move horizontally. When there are three zones, the right-hand zones can adjust both horizontally (shared splitter with zone 1) and vertically (between themselves). Attempted drags in unsupported directions must be ignored.

While the user is dragging an edge, the rest of the zones should update live so the overall tiling responds immediately to the in-progress resize. When the drag completes, the resized zone and its neighbors should already reflect the final geometry, requiring no additional snap or jump.

For testing and automation, the REPL also exposes a `resize-zone <index> <x> <y> <width> <height>` command that resizes an empty zone using screen coordinates (before per-edge margins are applied—8px at the outer edges, 4px per zone along shared edges). The socket API mirrors this capability through a `resize-zone` method that accepts the zone index and a `frame` object with `x`, `y`, `width`, and `height` values.

#### If a zone contains a window

Resizing the window should resize the zone to the best of our ability. Unlike for the placeholder window, we don't want a "live update".
Also if the window is moved to another location and released, it should "snap" back to its proper location in its zone.

### Repositioning and Resizing Window to Zone

When our window manager assigns a window to a zone, the window should be moved and resized to match the zone dimensions.
**Important:** When some windows are resized, they might not actually attain the dimensions requested. For example, a window might have a minimum width, etc. We should *not* keep on trying to resize them in an infinite loop. See below for the relevant ActiveFit feature.

### Dragging Windows Between Zones

When the user drags a managed window, Zonogy suspends reflows until mouse-up, shows non-interactive overlays for every zone, and highlights the zone under the mouse cursor. The drop target is whichever zone currently contains the cursor; if no zone contains it, no zone is highlighted. Dropping onto an empty zone moves the window there; dropping onto an occupied zone swaps the two windows (across screens if needed). If the system cannot determine a drop target—either because the cursor is outside every zone or because the prospective target disappears mid-gesture—we cancel the drop and push the dragged window back through the normal placement pipeline.

If the source app destroys the dragged window mid-gesture (e.g., Chrome tab merges), we immediately tear down drag overlays and defer placing the replacement window until the app finishes creating it.

If a window is dragged and dropped over a screen's add-zone indicator ("new zone" pill), we immediately add the zone and place the dragged window into it. During tab tear-out flows (e.g., Chrome creating a fresh window mid-drag), keep the original zone's occupant intact until the new window lands in the newly created zone.

### Drag and Drop on Placeholder Windows and the Add-Zone Indicator

Placeholder windows and the add-zone indicator accept external drops so the user can route content directly into a zone.

**Files:** When a file is dropped on a placeholder window, immediately target that placeholder's zone and pass the file to the system default application (Launch Services "open"). Dropping on the add-zone indicator first creates the new zone (which automatically sets it as the target), and then opens the file the same way.

**URLs:** Accept pasteboard URLs (including custom schemes such as `message:`) on both placeholder windows and the add-zone indicator. Targeting behavior mirrors the file path above. After targeting, open the URL with its default handler unless it is an HTTP(S) link.

**Web links:** For HTTP and HTTPS links, determine the default browser, create **a new window** in that browser, and load the URL there instead of invoking the generic opener. We currently support Safari, Chrome, Firefox, and Edge for the new-window automation.

### Flip the Key Window to Another Screen

Pressing shortcut Control-Cmd-Enter moves the currently active/key window to another screen (if there is more than one screen).

If the targeted zone is on another screen, then immediately move the key window into it, minimize any displaced window.

If the targeted zone is on the same screen as the active/key window then: We pick the first `NSScreen` that is not the key window's current screen; all behavior below refers to that destination screen. Choose the lowest-index empty zone on the destination screen, or if none exist, the highest-index occupied zone. Make that zone be target, and perform the move described above.

In either case, since the original zone of the window is now empty, it should become targeted after this.

## 5. Special Features

### ActiveFit: Active Overflow Reveal for Key Windows

Some applications refuse to shrink below their minimum width/height, which means the standard zone-aligned frame can spill off-screen when the window lives in zone 2 or zone 3 (the right column). This is acceptable while the window is inactive, but when the user activates that window it must be temporarily repositioned so the entire frame fits within the display's visible bounds.

**Implementation requirements:**

1. ActiveFit only applies to non-placeholder windows assigned to zone 2 or zone 3 on any screen. Zone 1 never receives this treatment.
2. Attempt the normal zone-aligned move/resize first. Then determine whether ActiveFit is needed by anchoring the window's actual *post-resize* size to the zone's content origin (after margins). If the resulting predicted frame would extend beyond the screen's visible bounds (allow a ≤1 px tolerance), the window qualifies.
3. When a qualifying window becomes the active/key window, shift it left and/or upward just enough for the full frame to sit inside the screen's visible bounds. Do not shrink the window; this translation may cover neighboring zones temporarily.
4. When that window loses key status, leaves its zone, is minimized, or closes, move it back to its normal zone-aligned position so other zones reclaim their space.
5. ActiveFit adjustments should not fight the main zone-sync loop. While a window is expanded via ActiveFit, zone sync must skip reapplying the normal frame for that specific zone so the temporary positioning is preserved until the window deactivates.

This behavior makes oversized right-column windows usable without permanently disrupting the zone layout. The user-facing name of this capability is **ActiveFit**.

### Temporary Zones (another kind of zone)

The big picture is that the "temporary zone" (one per screen) provides a way for the user to temporarily float a window (eligible for management by Zonogy) over the other (tiled) zones. It is temporary in the sense that as soon as the user directs focus to a tiled zone window, the floating occupant is cleared (window minimized). More details:

- Holds at most one managed window (no placeholder). This is also called the "floating window". When placed into a temporary zone, a window is centered and resized once; after that the user may freely move/resize it without changing any tiled frames.
- Placing another window into the temporary zone minimizes the previous occupant. We minimize the floating window when another (non-placeholder managed) window on the same screen becomes active/front-most. Temporary zones on other screens stay untouched so each screen floats independently.
- Each screen renders a bottom-edge pill indicator for the temporary zone. Clicking that pill targets the temporary zone for that screen. The indicator sits flush with the screen bottom so edge clicks hit it.
- At the point when we fill the last previously empty tiled (normal) zone the temporary zone auto-targets. If that temporary zone is targeted **and** still contains a window, it keeps the target even when another tiled zone becomes empty or a new one is created; the user must explicitly retarget or empty the temporary zone to hand control back. Emptying the temporary zone never forces retargeting, but once it is empty (or manually deselected) normal targeting rules resume.
- Default drags merely reposition the floating window (not entering the usual replace pipeline). If the floating window is dragged to the new zone indicator (i.e., the mouse is over the new zone indicator when it's dropped), a new zone should be created and the window should be placed in it as normal.
- Control-Command-drag can be used to drop the floating window into an existing tiled zone via the usual replace pipeline; however, unlike the usual replace pipeline, the displaced window should be minimized (now swapped into the temporary zone). We should be able to start normal dragging and then hold Control-Command to enter this mode. Releasing Control-Command should revert back to normal drag mode (simply repositioning the floating window).
- When dragging a window from a normal (tiled zoned), dropping it onto the targeted zone indicator for the temporary zone should place that window in the temporary zone (replacing and minimizing any prior occupant). The temporary zone pill should highlight when the mouse is over it during drag matching the UI of the new zone indicator as much as possible.
- Control-Command-drag can also be used to place a tiled window (ie normal zone) into the temporary zone. (Same rules as above apply wrt to pressing or releasing Control-Command in the middle of the drag).
- Pressing Control-Cmd-DownArrow targets the temporary zone on the same screen as the currently targeted normal zone. If a temporary zone is already targeted, the shortcut does nothing.
- Pressing Control-Cmd-UpArrow switches from the targeted temporary zone to a normal zone on the same screen (prefers empty zone with lowest index, or filled zone with highest index if no empty zone exists). Does nothing if a temporary zone is not targeted.
- Pressing Control-Cmd-LeftArrow navigates left: if temporary zone is targeted, targets the temporary zone on the screen to the left; if normal zone is targeted, targets the zone with lower index on same screen, or wraps to the last zone on the previous screen.
- Pressing Control-Cmd-RightArrow navigates right: if temporary zone is targeted, targets the temporary zone on the screen to the right; if normal zone is targeted, targets the zone with higher index on same screen, or wraps to the first zone on the next screen.

### Screen Management

**Active screen determination:** If the mouse pointer and `NSScreen.main` are the same screen, that screen is active. Otherwise, choose between the pointer screen and `NSScreen.main` by preferring the one that currently holds the targeted zone. (`NSScreen.main` returns the screen containing the window currently receiving keyboard input, or the screen with the menu bar if no window has focus.)

**Independent zone management:** Each screen maintains its own set of zones (1-3 per screen). Keyboard shortcuts for adding/removing zones (`Control-Cmd-=` and `Control-Cmd-[minus]`) operate on the currently active screen only.

**Screen detection:** Matches Amethyst: calculate each window's frame overlap with every screen via `CGRectIntersection` and choose the display with the largest intersection area (fall back to the origin-containing screen if no overlap).

## 6. Implementation Details

### Destroyed Window Detection

Not all applications emit didTerminateApplication notification upon closing (eg Find My). So we need to also monitor other notifications. Specifically, we do the following:

After events such as application termination, workspace focus changes, or accessibility notifications, `AppController` validates every affected PID. An external window is removed immediately when either the window server stops reporting its `CGWindowNumber` or the accessibility element returns an invalid-element error. If the initial pass finds no destroyed windows but the PID still owns managed windows, the controller schedules a short series of PID-scoped revalidations with exponential backoff (≈0.2 s → 3.2 s). Retries cancel as soon as every window disappears or the process exits; no global polling timer runs.

### Additional Notes

- Placeholder windows need an interactive blue "x" control that sends a callback to remove the zone.
- `window_id`s should be monotonically increasing so logs stay unique; do not recycle identifiers after a window closes.
- When `NSWorkspace` reports that an application terminated, immediately drop every managed window for that pid and resync so placeholders reappear in vacated zones.
- We add a simple logging utility (e.g., `Logger.debug(_:)`) used by controllers and REPL commands so we can trace zone transitions and window lifecycle without attaching Xcode.
**Log monitoring tip:** To watch the live log output, run:
`stdbuf -oL -eL swift run 2>&1 | grep --line-buffered "keyword"`.
- **Notification suppression:** When Zonogy programmatically minimizes specific windows (e.g., bulk clear/reset, displacement, startup pruning), it suppresses only the *next* `AXWindowMiniaturized` notification for those window IDs (one-shot) with a safety timeout (~3s). Other windows remain unaffected and user-triggered actions still get through.
(`stdbuf` makes `swift run` flush each line immediately, and `grep --line-buffered` streams matching lines without delay.)
- The REPL keeps running until the process is terminated so we can script scenarios by piping command sequences (`printf "add-zone\nlist\n" | ./Zonogy`). Retain this interface in later stages for regression testing even once real-window integration is added.

## 7. Accessibility API Workarounds

### kAXWindowCreatedNotification and kAXFocusedWindowChangedNotification

`kAXWindowCreatedNotification` is not reliably generated, while `kAXFocusedWindowChangedNotification` is much more reliable. We subscribe to both for max reliability.

Unfortunately, there is an edge case which misses `kAXFocusedWindowChangedNotification`: When I close the last window of an application and then open a new window, the OS considers this not a focus change. We address this as follows: When the last managed window of an application A is closed (or minimized), and application A is frontmost, we run `NSRunningApplication.activate(options: [.activateIgnoringOtherApps])` first on Zonogy and then on application A. Then when A later creates a window it considers it a focus change. (Note that we need to focus it back on application A so that I could, for example, press Cmd-N to open a new window in that application, etc.)

## 8. Developer Tools

### Command-line REPL for Debugging

To allow an AI Agent to test the functionality of Zonogy, expose a simple command-line interface that reads lines from `stdin` (e.g., via `DispatchSourceRead` so it cooperates with the AppKit run loop).

**Note:** Zone manipulation commands (`add-zone`, `remove-zone`, `resize-zone`) operate on the currently active screen.

Required commands:

- `add-zone`: add a new zone (up to 3) and recompute layouts.
- `remove-zone <index>`: remove the specified zone (cannot remove the last remaining zone). Reflow remaining zones and reassign any window that was in the removed zone using the normal placement rules.
- `close-window <window_id>`: close the specified managed window and free its zone (placeholder appears).
- `minimize <window_id>` / `unminimize <window_id>`: toggle minimized state. When unminimizing, reapply the standard placement rules.

Helpful optional commands (for faster debugging):

- `list`: print the current zones, their frames, and which window (if any) they hold.
- `layout`: force a recomputation of zone frames (useful after changing screen size in tests).
- `window-info <window_id>`: display the zone index, the zone's desired frame, and the actual on-screen frame reported by AppKit so we can compare intended versus real geometry.
- `frames`: dump a quick summary of every managed window's actual frame (including minimized placeholders) to make tiling issues easy to spot.
- `resize-zone <index> <x> <y> <width> <height>`: resize an empty zone using screen coordinates.
- `help`: describe available commands.

### Unix Domain Socket Interface for Agent Interaction

To enable better AI Agent integration and programmatic control, Zonogy also exposes a Unix domain socket interface. This allows external clients (including AI agents like Claude Code) to interact with the window manager using structured JSON commands over a socket connection.

**Starting the socket server:**

```bash
.build/debug/Zonogy --socket
# Or with custom socket path:
.build/debug/Zonogy --socket --socket-path=/tmp/custom.sock
```

**Key features:**

- **JSON-RPC style protocol**: Commands and responses use structured JSON format
- **Newline-delimited**: Each request/response is a single JSON object followed by a newline
- **Default socket path**: `/tmp/zonogy.sock`
- **Non-blocking accept**: Uses a timer-based polling approach to accept connections
- **Thread-safe**: All commands are dispatched to the main thread for AppKit safety
- **Debug logging**: Writes to `/tmp/zonogy-debug.log` when in socket mode

**Request format:**

```json
{"method": "command-name", "id": 1, "params": {"param1": "value1"}}
```

**Response format:**

```json
{"id": 1, "success": true, "result": {...}, "error": null}
```

**Available commands:** All REPL commands are exposed via the socket with JSON equivalents. Zone manipulation commands operate on the currently active screen.

- `list`: Get all zones and their state
- `add-zone`: Add a new zone
- `remove-zone`: Remove a zone by index (requires `params: {"index": N}`)
- `close-window`: Close a window (requires `params: {"window_id": N}`)
- `minimize` / `unminimize`: Toggle window minimization (requires `params: {"window_id": N}`)
- `window-info`: Get detailed window information (requires `params: {"window_id": N}`)
- `frames`: Get all window frames
- `layout`: Force layout recalculation

For complete API documentation, examples, and error handling details, see **[SOCKET_API.md](SOCKET_API.md)**.

### Debug Log File

Zonogy always writes debug logs to `/tmp/zonogy-debug.log`. AI agents should read only the tail of this log (e.g., `tail -500`) since it can grow large during long sessions.

### Time-travel Debug Logging

When I am running Zonogy (either in REPL, socket, or other modes) and notice incorrect behavior, I should be able to press "Control-Command-z". This keystroke should be intercepted by Zonogy and not passed to other apps. When the shortcut is invoked, we save the *last 10 seconds of the log prior to the invocation of the shortcut* to `./time_travel_log.txt` to help us debug the problem.

After the time travel log file is written, the log buffer should be cleared. This means that pressing "Control-Command-z" twice within a short time window would only generate the log *between* the two presses.

### Sleep/Wake State Recovery

macOS can destroy and recreate application windows when the computer sleeps. Zonogy must preserve its layout across those transitions:

- **Temporary zone snapshot** – before sleep we record the floating window (bundle ID, CGWindowID, internal `windowId`, and title) for each screen's temporary zone. After wake we immediately reattach any returning window that matches the snapshot and keep it key/visible for a short protection window so newly recaptured tiled windows cannot minimize it.
- **Per-zone snapshot** – before sleep we also snapshot every tiled zone using the zone's `screenId`+index together with the window's identifiers described above. When a window is recaptured during wake, we first check whether it matches a stored snapshot. If so we force-place it back into its remembered zone (evicting placeholders or temporary occupants as needed) before running the normal placement logic. This applies independently per screen, so multi-display layouts are preserved exactly.
- **Multiple wake passes** – because Accessibility events can arrive slowly after wake, we replay the snapshot data immediately after the first sync *and* again after each scheduled recapture (0.5 s, 1.5 s, 3.0 s) so late-arriving windows still land in their original zones. Snapshots are cleared only after the matching window successfully returns to its zone.

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

## 9. Configuration

An optional `config.json` file lets users specify bundle identifiers that the window manager should ignore. When present, it is discovered using the following search order:

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
  ]
}
```

Bundle identifiers listed here are excluded from zone management and will not be minimized during startup. Zonogy always ignores its own bundle identifier automatically.
