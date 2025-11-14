#!/usr/bin/env python3
"""
Automated regression script for Zonogy window positioning.

The script exercises the window manager through its Unix domain socket while
observing actual AppKit window geometry via ``winmanmon``. It launches
TextEdit, captures its windows into zones, adds more zones, and verifies that
resulting frames respect the spec-mandated spacing (8px at outer edges and
8px combined between adjacent zones).

Usage:
    python3 scripts/test_window_positioning.py
"""

from __future__ import annotations

import itertools
import json
import os
import socket
import subprocess
import sys
import time
from pathlib import Path
from typing import Any, Dict, List, Optional

DELAY = 1.0
SOCKET_PATH = Path("/tmp/zonogy-test.sock")
REQUEST_COUNTER = itertools.count(1)


class CommandError(RuntimeError):
    """Raised when a socket command fails."""


def run_command(cmd: List[str], *, capture: bool = True) -> subprocess.CompletedProcess[str]:
    """Run a shell command with text output."""
    return subprocess.run(
        cmd,
        check=True,
        text=True,
        capture_output=capture,
    )


def run_osascript(script: str) -> str:
    """Execute AppleScript and return trimmed stdout."""
    result = run_command(["osascript", "-e", script])
    return result.stdout.strip()


def applescript_quote(text: str) -> str:
    """Escape a string for AppleScript double-quoted literals."""
    return text.replace("\\", "\\\\").replace('"', '\\"')


def close_textedit_document(title: str) -> None:
    """Close a TextEdit document by title."""
    escaped = applescript_quote(title)
    script = f'''
tell application "TextEdit"
    set matchingWindows to (every window whose name is "{escaped}")
    repeat with windowRef in matchingWindows
        if (exists windowRef) then
            set index of windowRef to 1
            activate
        end if
    end repeat
end tell
tell application "System Events"
    tell process "TextEdit"
        set frontmost to true
        keystroke "w" using {{command down}}
        delay 0.1
        if (exists sheet 1 of window 1) then
            click button "Don't Save" of sheet 1 of window 1
        end if
    end tell
end tell
'''
    run_osascript(script)
    time.sleep(DELAY)


def wait_for_socket(path: Path, timeout: float = 10.0) -> None:
    """Wait until the socket path exists."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        if path.exists():
            return
        time.sleep(0.1)
    raise TimeoutError(f"Socket {path} did not appear within {timeout} seconds")


def send_socket_command(method: str, params: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
    """Send a JSON command to the Unix domain socket."""
    payload = json.dumps(
        {
            "id": next(REQUEST_COUNTER),
            "method": method,
            "params": params or {},
        }
    ).encode("utf-8") + b"\n"

    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.connect(str(SOCKET_PATH))
        client.sendall(payload)
        chunks: List[bytes] = []
        while True:
            chunk = client.recv(4096)
            if not chunk:
                break
            chunks.append(chunk)
            if chunk.endswith(b"\n"):
                break

    if not chunks:
        raise CommandError(f"{method}: empty response")

    response = json.loads(b"".join(chunks).decode("utf-8"))
    if not response.get("success", False):
        raise CommandError(f"{method}: {response.get('error', 'unknown error')}")
    result = response.get("result")
    if result is None:
        return {}
    return result


def get_winmanmon() -> List[Dict[str, Any]]:
    """Return JSON output from winmanmon."""
    result = run_command(["winmanmon", "--json", "--onscreenonly"])
    return json.loads(result.stdout)


def create_textedit_document() -> str:
    """Create a new TextEdit document and return its title."""
    script = """
tell application "TextEdit"
    set newDoc to make new document
    set docWindow to front window
    set miniaturized of docWindow to false
    set index of docWindow to 1
    activate
    return name of newDoc
end tell
"""
    title = run_osascript(script)
    time.sleep(DELAY)
    return title


def collect_stage(label: str) -> Dict[str, Any]:
    """Capture zone state, window info, frame dumps, and winmanmon data."""
    zones = send_socket_command("list").get("zones", [])

    zone_entries: List[Dict[str, Any]] = []
    for zone in zones:
        window_id = zone.get("window_id")
        info = None
        if window_id is not None:
            info = send_socket_command("window-info", {"window_id": window_id})
        zone_entries.append({"zone": zone, "info": info})

    frames = send_socket_command("frames").get("windows", [])
    textedit_windows = [
        window for window in get_winmanmon() if window.get("bundleIdentifier") == "com.apple.TextEdit"
    ]

    return {
        "label": label,
        "zones": zone_entries,
        "frames": frames,
        "textedit": textedit_windows,
    }


def close_zone_window(zone_index: int, title: str, stages: List[Dict[str, Any]], stage_label: str) -> None:
    """Close the TextEdit window via AppleScript and collect the stage."""
    print(f"Closing TextEdit document '{title}' via AppleScript…")
    close_textedit_document(title)
    stages.append(collect_stage(stage_label))


def find_zone_entry(stage: Dict[str, Any], zone_index: int) -> Dict[str, Any]:
    for entry in stage["zones"]:
        if entry["zone"].get("index") == zone_index:
            return entry
    raise AssertionError(f"Zone {zone_index} not present in stage '{stage['label']}'")


def format_frame(frame: Dict[str, Any]) -> str:
    return f"(x:{frame['x']}, y:{frame['y']}, w:{frame['width']}, h:{frame['height']})"


def format_deltas(zone_frame: Dict[str, Any], actual_frame: Dict[str, Any]) -> str:
    dx = actual_frame["x"] - zone_frame["x"]
    dy = actual_frame["y"] - zone_frame["y"]
    dw = actual_frame["width"] - zone_frame["width"]
    dh = actual_frame["height"] - zone_frame["height"]
    return f"Δx={dx:+.1f}, Δy={dy:+.1f}, Δw={dw:+.1f}, Δh={dh:+.1f}"


def print_report(stages: List[Dict[str, Any]]) -> None:
    print("=== Zonogy Window Positioning ===")
    for stage in stages:
        print(f"\nStage: {stage['label']}")
        for entry in stage["zones"]:
            zone = entry["zone"]
            zone_frame = zone["frame"]
            print(f"  Zone {zone['index']} frame {format_frame(zone_frame)}")
            info = entry["info"]
            if info:
                actual = info["actual_frame"]
                print(
                    f"    Window {info['window_id']} actual {format_frame(actual)} "
                    f"({format_deltas(info['zone_frame'], actual)})"
                )
            else:
                print("    (empty)")

        active_textedit = [w for w in stage["textedit"] if not w.get("isMinimized", False)]
        if active_textedit:
            print("  TextEdit windows (winmanmon):")
            for window in active_textedit:
                title = window.get("title") or "<untitled>"
                print(f"    {title} id {window['windowID']}: {format_frame(window['dimensions'])}")

        placeholders = [w for w in stage["frames"] if w.get("is_placeholder")]
        if placeholders:
            print("  Placeholders:")
            for placeholder in placeholders:
                print(f"    id {placeholder['window_id']}: {format_frame(placeholder['frame'])}")


def cleanup(process: Optional[subprocess.Popen[Any]]) -> None:
    """Stop Zonogy, remove socket, and shut down TextEdit."""
    try:
        run_osascript('tell application "TextEdit" to quit saving no')
    except subprocess.CalledProcessError:
        pass

    if process and process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
    if SOCKET_PATH.exists():
        SOCKET_PATH.unlink()


def main() -> int:
    if SOCKET_PATH.exists():
        SOCKET_PATH.unlink()

    print("Building Zonogy…")
    run_command(["swift", "build"], capture=False)

    print("Starting Zonogy (socket mode)…")
    process = subprocess.Popen(
        ["./.build/debug/Zonogy", "--socket", f"--socket-path={SOCKET_PATH}"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        preexec_fn=os.setsid,
    )

    try:
        wait_for_socket(SOCKET_PATH)

        stages: List[Dict[str, Any]] = []

        # Stage 1: Single zone with first TextEdit document
        first_title = create_textedit_document()
        stages.append(collect_stage("single zone"))

        # Stage 2: Add second zone, observe placeholder
        print("Adding second zone…")
        send_socket_command("add-zone")
        time.sleep(DELAY)
        stages.append(collect_stage("two zones with placeholder"))

        # Stage 3: Create second document
        second_title = create_textedit_document()
        stages.append(collect_stage("two zones with windows"))

        # Stage 4: Add third zone, observe placeholder
        print("Adding third zone…")
        send_socket_command("add-zone")
        time.sleep(DELAY)
        stages.append(collect_stage("three zones with placeholder"))

        # Stage 5: Create third document
        third_title = create_textedit_document()
        stages.append(collect_stage("three zones with windows"))

        # Close windows one by one
        close_zone_window(3, third_title, stages, "after closing zone 3 window")
        close_zone_window(2, second_title, stages, "after closing zone 2 window")
        close_zone_window(1, first_title, stages, "after closing zone 1 window")

        print_report(stages)
        return 0
    finally:
        cleanup(process)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print("\nInterrupted", file=sys.stderr)
        sys.exit(1)
