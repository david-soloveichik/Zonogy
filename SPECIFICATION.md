# LatticeTopology Window Manager for MacOS

LatticeTopology is a variation on a tiling window manager. In particular, it uses the concept of "zones" to give the user more control over tiling, essentially allowing "reserving" space for future windows. This also is meant to overcome a major annoyance with tiling window managers in that there is too much resizing and repositioning of windows and users close and open new windows.

## Zones

### Zones abstraction

A zone can either contain an (unminimized) window or be empty. There can be at most one window per zone. Minimized windows do not belong to any zone.
Each zone has an index (for example, if there are 3 zones, then the indexes are: 1, 2, and 3).

### Initial startup behavior

When LatticeTopology starts, it begins with 1 empty zone by default. All windows on the screen should be minimized for a clean start.

### Window placement for new windows

If a new window is created by an application or an existing window is unminimized:

- If there is an empty zone it should be placed there. If multiple zones are empty, preference should be given to the zone with a lower index.
- If there is no empty zone, then the new window should replace the existing window in the zone with the highest index. The old window in that zone should be minimized. (For the smoothest UI effect, we want to first move the new window to the right location, and only then minimize the old window.)

### Repositioning and resizing window to zone

When our window manager assigns a window to a zone, the window should be moved and resized to match the zone dimensions.
Important: When some windows are resized, they might not actually attain the dimensions requested. For example, a window might have a minimum width, etc. We should _not_ keep on trying to resize them in an infinite loop.

### Zone visual representation

If a zone contains a window, then that window simply "represents" the zone and there is no placeholder window. (Note that the size of the window may not match the size of the zone. For example, certain windows cannot be resized arbitrarily.)

Every empty zone should have a placeholder window created by our window manager. The placeholder windows should be semi-translucent, with no text. They should not have a title bar or any of the normal buttons (ie minimize, close, zoom). Instead there should be a blue button with an "x" in it, looking similar to a normal close button but larger and semi-translucent. Clicking this button should remove this zone. The border of the placeholder window should be a rounded rectangle.

Both normal windows and placeholder windows should have a margin of 5 pixels from the side of the zone for a nicer visual effect.

Placeholder windows must stay anchored to their zone. Dragging their surface should not reposition them; interaction is limited to resizing from their edges.

**Usage example**: Suppose the user starts with 2 zones, zone 1 containing window A and zone 2 containing window B. To get rid of zone 1 the user can take the following actions: minimize window A, which leads to the placeholder window appearing, and then clicking on the blue "x" button on the placeholder window.

### Adding and removing zones

When adding or removing zones, the remaining zones should be reindexed. For example, if there are zones 1, 2, 3, and I remove zone 1, then zone 2 should become zone 1, and zone 3 should become zone 2.

Whenever zones are added or removed, the dimensions of the remaining zones should be adjusted. Intuitively, they should be re-"tiled" to split the screen. The tiling is as follows:

- 1 zone: full screen (zone 1)
- 2 zones: split the screen into left (zone 1) and right (zone 2)
- 3 zones: split the screen into left (zone 1) and right/top (zone 2), right/bottom (zone 3)

There are two ways to remove a zone:

- By pressing the blue "x" button on the placeholder window of an empty zone.
- By pressing a keyboard shortcut Control-Cmd-[minus].

The minimum number of zones is 1. In other words, we cannot remove the last zone. The maximum number of zones is 3 (for now).

A zone can be added by pressing the global keyboard shortcut Control-Cmd-=. The new zone should be added with the highest index, and it should start out initially empty.

### Resizing zones

#### If a zone is empty (contains a placeholder window)

The placeholder window can be resized. Resizing it, resizes the zone and re-adjusts the other zones appropriately.

The resize affordances should only allow motions that can actually change the zone layout. For example, when zone 1 is the left-most column its bottom edge cannot be dragged vertically—only its right edge can move horizontally. When there are three zones, the right-hand zones can adjust both horizontally (shared splitter with zone 1) and vertically (between themselves). Attempted drags in unsupported directions must be ignored.

While the user is dragging an edge, the rest of the zones should update live so the overall tiling responds immediately to the in-progress resize. When the drag completes, the resized zone and its neighbors should already reflect the final geometry, requiring no additional snap or jump.

For testing and automation, the REPL also exposes a `resize-zone <index> <x> <y> <width> <height>` command that resizes an empty zone using screen coordinates (before the 5px margin is applied). The socket API mirrors this capability through a `resize-zone` method that accepts the target zone index and a `frame` object with `x`, `y`, `width`, and `height` values.

#### If a zone contains a window

Resizing the window should resize the zone to the best of our ability. Unlike for the placeholder window, we don't want a "live update".
Also if the window is moved to another location and released, it should "snap" back to its proper location in its zone.

## Conditions for which windows are managed

We manage a window if it passes several conditions (see `winmanmon` source code for how it collects this information):

- Subrole: AXStandardWindow
- isMovable: T
- hasZoom: T

## External tools and code reference

### tool `winmanmon`

For debugging purposes, it may be useful to see where all the windows are, whether they are minimized or not, and obtain other information about them. This can help us debug, for example, whether the window was successfully moved to its zone location. This is enabled by the following `winmanmon` command line tool, which displays for each window:
    - Application bundle identifier (e.g., "com.apple.Dictionary")
    - Window ID
    - Title (may be empty)
    - Screen
    - Dimensions (x, y, width, height)
    - Is minimized? (T/F)
    - Subrole (e.g., kAXStandardWindowSubrole, kAXDialogSubrole)
    - isMovable (T/F) - whether window position can be modified
    - hasZoom (T/F) - whether window has a zoom button

(Certain applications and types of windows that we don't care about are excluded.)

Location: `/Users/dsolov/Documents/Development/VibeDevelopment/WindowManagerMonitor-claude/.build/release/winmanmon`
The `--help` argument explains the functionality.

### source code of `winmanmon`

The source code at `/Users/dsolov/Documents/Development/VibeDevelopment/WindowManagerMonitor-claude` is also useful to us to understand how to efficiencly read important properties of windows such as whether they have a zoom button, its subrole, and whether it is movable, etc.

### Amethyst and Silica

The source code for Amethyst tiling window manager (with my modifications) is at `/Users/dsolov/Documents/Development/VibeDevelopment/Amethyst`. This might be useful as a reference since it implements tiling and some of the functionality we are interested in. For parts of its functionality it relies on the Silica framework whose source code is at `/Users/dsolov/Documents/Development/VibeDevelopment/Silica`.

## Initial Implementation and Debugging

For our initial implementation of LatticeTopology, we won't want to manage the windows of other applications. Instead, the window manager should create its own "test" windows that have title like "test `window_id`", and manage those in the way described above. These windows are always created and owned by our process so that we can exercise the tiling logic without touching real apps.

### Runtime architecture

- Launch an AppKit `NSApplication`. The main entry point should initialize a singleton `AppController` that wires together all services and keeps the run loop alive.
- Maintain an in-memory model of zones and windows in a lightweight data layer. Suggested types:
  - `Zone`: stores `index`, `frame`, and optional `window_id` that currently occupies the zone.
  - `ManagedWindow`: stores the AppKit window reference, its current assignment (zone index or `nil` when minimized), and bookkeeping fields like `window_id` and `isPlaceholder`. Desired geometry lives on the owning `Zone`; the window just reports its actual frame when queried.
- A `ZoneLayout` helper computes the frame rectangles for 1, 2, or 3 zones. It should be stateless and take the screen frame as input so we can re-run it whenever the zone count changes.
- A `ZoneController` owns the ordered list of zones, enforces the min (1) and max (3) counts, and provides methods for adding/removing zones, assigning windows, and reindexing after structural changes.
- A `WindowController` encapsulates AppKit window creation and manipulation. It creates frameless placeholder windows for empty zones (semi-translucent background, custom blue “x” close control) and titled test windows (`test <window_id>`) for occupied zones. All show/minimize/close requests flow through this controller so the rest of the code stays platform-agnostic.
- The controller layer should react to model changes by reconciling AppKit state: reflow frames, show/hide placeholders, and perform the “replace highest-index window” sequence atomically (position the new test window first, then minimize the evicted one).

### Command-line REPL for debugging

To allow the Agent to test the functionality of LatticeTopology, expose a simple command-line interface that reads lines from `stdin` (e.g., via `DispatchSourceRead` so it cooperates with the AppKit run loop). Each command delegates to the controllers above and prints a concise status message.

Required commands:

- `add-zone`: add a new zone (up to 3) and recompute layouts.
- `remove-zone <index>`: remove the specified zone (cannot remove the last remaining zone). Reflow remaining zones and reassign any window that was in the removed zone using the normal placement rules.
- `create-window`: spawn a new test window with the next `window_id`, place it in the lowest-index empty zone if available, or replace the highest-index zone’s window.
- `close-window <window_id>`: close the specified test window and free its zone (placeholder appears).
- `minimize <window_id>` / `unminimize <window_id>`: toggle minimized state. When unminimizing, reapply the standard placement rules.

Helpful optional commands (for faster debugging):

- `list`: print the current zones, their frames, and which window (if any) they hold.
- `layout`: force a recomputation of zone frames (useful after changing screen size in tests).
- `window-info <window_id>`: display the target zone index, the zone’s desired frame, and the actual on-screen frame reported by AppKit so we can compare intended versus real geometry.
- `frames`: dump a quick summary of every managed window’s actual frame (including minimized placeholders) to make tiling issues easy to spot.
- `resize-zone <index> <x> <y> <width> <height>`: resize an empty zone using screen coordinates.
- `help`: describe available commands.

### Additional implementation notes

- `window_id`s should be monotonically increasing so logs stay unique; do not recycle identifiers after a window closes. The REPL can expose the next ID in status messages when `create-window` succeeds.
- Add a simple logging utility (e.g., `Logger.debug(_:)`) used by controllers and REPL commands so we can trace zone transitions and window lifecycle without attaching Xcode.
- Placeholder windows need an interactive blue “x” control that sends a callback to remove the zone. For the first cut, use an `NSButton` positioned in the top-left of the placeholder window and wire it to `ZoneController.removeZone(at:)`.
- Provide a pure-function test hook for layout calculations (for example, a `ZoneLayoutTests.run()` method invocable from the REPL via a `test-layout` command) to assert expected frames for 1–3 zones and quickly catch regressions.

The REPL keeps running until the process is terminated so we can script scenarios by piping command sequences (`printf "add-zone\ncreate-window\n" | ./LatticeTopology`). Retain this interface in later stages for regression testing even once real-window integration is added.

### Unix Domain Socket Interface for Agent Interaction

To enable better AI agent integration and programmatic control, LatticeTopology also exposes a Unix domain socket interface. This allows external clients (including AI agents like Claude Code) to interact with the window manager using structured JSON commands over a socket connection.

**Starting the socket server:**

```bash
.build/debug/LatticeTopology --socket
# Or with custom socket path:
.build/debug/LatticeTopology --socket --socket-path=/tmp/custom.sock
```

**Key features:**

- **JSON-RPC style protocol**: Commands and responses use structured JSON format
- **Newline-delimited**: Each request/response is a single JSON object followed by a newline
- **Default socket path**: `/tmp/lattice-topology.sock`
- **Non-blocking accept**: Uses a timer-based polling approach to accept connections
- **Thread-safe**: All commands are dispatched to the main thread for AppKit safety
- **Debug logging**: Writes to `/tmp/lattice-topology-debug.log` when in socket mode

**Request format:**

```json
{"method": "command-name", "id": 1, "params": {"param1": "value1"}}
```

**Response format:**

```json
{"id": 1, "success": true, "result": {...}, "error": null}
```

**Available commands:** All REPL commands are exposed via the socket with JSON equivalents:

- `list`: Get all zones and their state
- `add-zone`: Add a new zone
- `remove-zone`: Remove a zone by index (requires `params: {"index": N}`)
- `create-window`: Create a new test window
- `close-window`: Close a window (requires `params: {"window_id": N}`)
- `minimize` / `unminimize`: Toggle window minimization (requires `params: {"window_id": N}`)
- `window-info`: Get detailed window information (requires `params: {"window_id": N}`)
- `frames`: Get all window frames
- `layout`: Force layout recalculation

For complete API documentation, examples, and error handling details, see **[SOCKET_API.md](SOCKET_API.md)**.
