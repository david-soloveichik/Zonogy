# LatticeTopology Unix Socket API

## Overview

LatticeTopology exposes a Unix domain socket interface for programmatic control and agent interaction. This allows AI agents and other clients to interact with the window manager via structured JSON commands.

## Starting the Socket Server

```bash
# Start in socket mode
.build/debug/LatticeTopology --socket

# Or specify a custom socket path
.build/debug/LatticeTopology --socket --socket-path=/tmp/custom.sock
```

**Default socket path:** `/tmp/lattice-topology.sock`

## Protocol

The socket uses a simple JSON-RPC style protocol:

**Request format:**
```json
{
  "method": "command-name",
  "id": 1,
  "params": {
    "param1": "value1"
  }
}
```

**Response format:**
```json
{
  "id": 1,
  "success": true,
  "result": { ... },
  "error": null
}
```

Requests and responses are newline-delimited JSON.

## Available Commands

### list
List all zones and their current state.

**Request:**
```json
{"method": "list", "id": 1}
```

**Response:**
```json
{
  "id": 1,
  "success": true,
  "result": {
    "zones": [
      {
        "index": 1,
        "window_id": 2,
        "frame": {
          "x": 44,
          "y": 0,
          "width": 734,
          "height": 944
        }
      },
      {
        "index": 2,
        "window_id": null,
        "frame": {
          "x": 778,
          "y": 0,
          "width": 734,
          "height": 944
        }
      }
    ]
  },
  "error": null
}
```

### add-zone
Add a new zone (up to 3 zones maximum).

**Request:**
```json
{"method": "add-zone", "id": 2}
```

**Response:**
```json
{
  "id": 2,
  "success": true,
  "result": {
    "zone_index": 2,
    "zone_count": 2
  },
  "error": null
}
```

### remove-zone
Remove a zone by index.

**Request:**
```json
{"method": "remove-zone", "id": 3, "params": {"index": 2}}
```

**Response:**
```json
{
  "id": 3,
  "success": true,
  "result": {
    "removed_index": 2,
    "zone_count": 1
  },
  "error": null
}
```

### create-window
Create a new test window.

**Request:**
```json
{"method": "create-window", "id": 4}
```

**Response:**
```json
{
  "id": 4,
  "success": true,
  "result": {
    "window_id": 2,
    "zone_index": 1
  },
  "error": null
}
```

### close-window
Close a window by ID.

**Request:**
```json
{"method": "close-window", "id": 5, "params": {"window_id": 2}}
```

**Response:**
```json
{
  "id": 5,
  "success": true,
  "result": {
    "window_id": 2
  },
  "error": null
}
```

### minimize
Minimize a window.

**Request:**
```json
{"method": "minimize", "id": 6, "params": {"window_id": 2}}
```

### unminimize
Unminimize a window.

**Request:**
```json
{"method": "unminimize", "id": 7, "params": {"window_id": 2}}
```

### window-info
Get detailed information about a specific window.

**Request:**
```json
{"method": "window-info", "id": 8, "params": {"window_id": 2}}
```

**Response:**
```json
{
  "id": 8,
  "success": true,
  "result": {
    "window_id": 2,
    "is_placeholder": false,
    "zone_index": 1,
    "actual_frame": {
      "x": 44,
      "y": 0,
      "width": 734,
      "height": 944
    },
    "zone_frame": {
      "x": 44,
      "y": 0,
      "width": 734,
      "height": 944
    }
  },
  "error": null
}
```

### frames
Get all window frames.

**Request:**
```json
{"method": "frames", "id": 9}
```

**Response:**
```json
{
  "id": 9,
  "success": true,
  "result": {
    "windows": [
      {
        "window_id": 2,
        "is_placeholder": false,
        "frame": {
          "x": 44,
          "y": 0,
          "width": 734,
          "height": 944
        }
      }
    ]
  },
  "error": null
}
```

### layout
Force a layout recalculation.

**Request:**
```json
{"method": "layout", "id": 10}
```

**Response:**
```json
{
  "id": 10,
  "success": true,
  "result": {
    "zone_count": 2
  },
  "error": null
}
```

## Example Clients

### Python

```python
import socket
import json

def send_command(sock_path, command):
    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    client.connect(sock_path)

    message = json.dumps(command) + "\n"
    client.sendall(message.encode('utf-8'))

    response = b""
    while True:
        chunk = client.recv(4096)
        if not chunk:
            break
        response += chunk
        if b"\n" in response:
            break

    client.close()
    return json.loads(response.decode('utf-8'))

# Usage
result = send_command("/tmp/lattice-topology.sock", {
    "method": "list",
    "id": 1
})
print(result)
```

### Bash

```bash
# Using nc (netcat)
echo '{"method":"list","id":1}' | nc -U /tmp/lattice-topology.sock

# Or using a Python one-liner
python3 -c "
import socket, json
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect('/tmp/lattice-topology.sock')
s.sendall(b'{\"method\":\"list\",\"id\":1}\n')
print(s.recv(4096).decode())
s.close()
"
```

### Claude Code Bash Tool

Claude Code can interact with the socket using the Bash tool:

```bash
# List zones
python3 -c "
import socket, json
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect('/tmp/lattice-topology.sock')
s.sendall(b'{\"method\":\"list\",\"id\":1}\n')
print(s.recv(4096).decode())
s.close()
"

# Create a window
python3 -c "
import socket, json
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect('/tmp/lattice-topology.sock')
s.sendall(b'{\"method\":\"create-window\",\"id\":2}\n')
print(s.recv(4096).decode())
s.close()
"
```

## Error Handling

If a command fails, the response will have `success: false` and an error message:

```json
{
  "id": 1,
  "success": false,
  "result": null,
  "error": "Failed to add zone (max 3 zones)"
}
```

Common errors:
- `"Unknown command: <method>"` - Invalid method name
- `"Missing required parameter: <param>"` - Required parameter not provided
- `"Failed to add zone (max 3 zones)"` - Cannot add more than 3 zones
- `"Failed to remove zone <index>"` - Cannot remove last zone or invalid index
- `"Window <id> not found"` - Invalid window_id

## Thread Safety

All commands are automatically dispatched to the main thread, so AppKit operations are thread-safe. The socket server handles multiple clients sequentially.

## Implementation Notes

- The socket is created with permissions `0o666` so any local user can connect
- Each client connection is handled independently
- The socket file is automatically cleaned up on exit
- Logging is written to `/tmp/lattice-topology-debug.log` in socket mode
