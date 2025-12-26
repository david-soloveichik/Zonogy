# Zonogy REPL and Socket API

This document describes the developer tools for interacting with Zonogy programmatically.

## Command-line REPL for Debugging

To allow an AI Agent to test the functionality of Zonogy, expose a simple command-line interface that reads lines from `stdin` (e.g., via `DispatchSourceRead` so it cooperates with the AppKit run loop).

**Note:** Zone manipulation commands (`add-zone`, `remove-zone`, `resize-zone`) operate on tiling zones on the currently active screen. Temporary zones are not accessible via REPL commands.

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

## Unix Domain Socket Interface for Agent Interaction

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
