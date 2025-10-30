#!/usr/bin/env python3
"""
Automated regression script for LatticeTopology window positioning.

The script exercises the window manager through its Unix domain socket while
observing actual AppKit window geometry via ``winmanmon``. It launches
TextEdit, captures its windows into zones, adds more zones, and verifies that
resulting frames respect the spec-mandated 5px inset.

Usage:
    python3 scripts/test_window_positioning.py
"""

from __future__ import annotations

import itertools
import json
import os
import signal
import socket
import subprocess
import sys
import time
from pathlib import Path
from typing import Any, Dict, List, Optional

CLOSE_POLL_TIMEOUT_SECONDS = 6.0
CLOSE_POLL_INTERVAL_SECONDS = 0.25
SETTLE_SECONDS = 0.7
SOCKET_PATH = Path("/tmp/lattice-topology-test.sock")
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


def close_textedit_document(title: str) -> bool:
    """Close a TextEdit document by title; return True if any document was closed."""
    escaped = applescript_quote(title)
    script = f'''
set closedAny to false
tell application "TextEdit"
    set matchingWindows to (every window whose name is "{escaped}")
end tell
if (count of matchingWindows) is 0 then
    return false
end if
repeat with windowRef in matchingWindows
    try
        tell application "TextEdit"
            if (exists windowRef) then
                set index of windowRef to 1
                activate
            end if
        end tell
        delay 0.1
        tell application "System Events"
            tell process "TextEdit"
                set frontmost to true
                keystroke "w" using {{command down}}
                delay 0.1
                if (exists sheet 1 of window 1) then
                    try
                        click button "Don't Save" of sheet 1 of window 1
                    end try
                end if
            end tell
        end tell
        delay 0.2
        set closedAny to true
    end try
end repeat
return closedAny
'''
    result = run_osascript(script)
    time.sleep(SETTLE_SECONDS)
    return result.lower() == "true"


def log_winmanmon_snapshot(label: str) -> None:
    """Dump current TextEdit windows from winmanmon with a label."""
    print(f"Cleanup snapshot: {label}")
    windows = [
        window
        for window in get_winmanmon()
        if window.get("bundleIdentifier") == "com.apple.TextEdit"
    ]
    if not windows:
        print("  No TextEdit windows (winmanmon)")
        return
    print("  TextEdit windows (winmanmon):")
    for window in windows:
        title = window.get("title") or "<untitled>"
        print(f"    {title} id {window['windowID']}: {format_frame(window['dimensions'])}")


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


def capture_textedit_window(title: str, attempts: int = 5) -> None:
    """Ensure the specified TextEdit window is managed by LatticeTopology."""
    for attempt in range(1, attempts + 1):
        run_osascript(
            f"""
tell application "TextEdit"
    activate
    set targetWindow to (first window whose name is "{title}")
    set miniaturized of targetWindow to false
    set index of targetWindow to 1
end tell
"""
        )
        time.sleep(0.8)
        try:
            send_socket_command("capture-frontmost")
            return
        except CommandError as exc:
            if "Frontmost application" in str(exc) and attempt < attempts:
                time.sleep(0.5)
                continue
            raise


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


def determine_target_title(
    stage: Dict[str, Any],
    zone_entry: Dict[str, Any],
    fallback_title: str,
) -> str:
    """Determine the TextEdit title for a zone prior to closing."""
    target_title = fallback_title
    zone_info = zone_entry.get("info")
    if zone_info and zone_info.get("actual_frame"):
        target_signature = frame_signature(zone_info["actual_frame"])
        for window in stage["textedit"]:
            dims = window.get("dimensions")
            if not dims:
                continue
            if frame_signature(dims) == target_signature:
                candidate_title = window.get("title")
                if candidate_title:
                    target_title = candidate_title
                break
    return target_title


def wait_for_zone_to_clear(
    zone_index: int,
    label: str,
    timeout: float = CLOSE_POLL_TIMEOUT_SECONDS,
    poll_interval: float = CLOSE_POLL_INTERVAL_SECONDS,
) -> tuple[Dict[str, Any], bool]:
    """Poll until the specified zone no longer reports a managed window."""
    deadline = time.time() + timeout
    last_stage: Optional[Dict[str, Any]] = None
    while time.time() < deadline:
        stage = collect_stage(label)
        zone_entry = find_zone_entry(stage, zone_index)
        if zone_entry["zone"].get("window_id") is None:
            return stage, True
        last_stage = stage
        time.sleep(poll_interval)

    if last_stage is None:
        last_stage = collect_stage(label)

    zone_entry = find_zone_entry(last_stage, zone_index)
    debug_dump = {
        "zone": zone_entry["zone"],
        "info": zone_entry["info"],
        "placeholders": [p for p in last_stage["frames"] if p.get("is_placeholder")],
    }
    print(f"Debug: Zone {zone_index} state after waiting {timeout:.1f}s:")
    print(json.dumps(debug_dump, indent=2))

    return last_stage, False


def close_zone_window(
    zone_index: int,
    initial_stage: Dict[str, Any],
    fallback_title: str,
    stages: List[Dict[str, Any]],
    stage_label: str,
) -> Dict[str, Any]:
    """Close the TextEdit window occupying the given zone via AppleScript."""
    zone_entry = find_zone_entry(initial_stage, zone_index)
    window_id = zone_entry["zone"].get("window_id")
    if window_id is None:
        print(f"Zone {zone_index} already empty; skipping close.")
        return initial_stage

    previous_placeholder_count = count_placeholders(initial_stage)
    target_title = determine_target_title(initial_stage, zone_entry, fallback_title)

    print(f"Closing TextEdit document '{target_title}' via AppleScript…")
    closed = close_textedit_document(target_title)
    if not closed:
        raise AssertionError(f"AppleScript failed to close TextEdit document '{target_title}'")

    send_socket_command("layout")

    after_close, cleared = wait_for_zone_to_clear(zone_index, stage_label)
    stages.append(after_close)

    final_stage = after_close
    if not cleared:
        print(f"AppleScript close did not clear zone {zone_index}; invoking REPL close-window fallback.")
        send_socket_command("close-window", {"window_id": window_id})
        time.sleep(SETTLE_SECONDS)
        final_stage = collect_stage(f"{stage_label} (after close-window fallback)")
        stages.append(final_stage)

    zone_after_close = find_zone_entry(final_stage, zone_index)
    if zone_after_close["zone"].get("window_id") is not None:
        raise AssertionError(f"Zone {zone_index} still reports a window after AppleScript close")
    if zone_after_close["info"] is not None:
        raise AssertionError(f"Window info unexpectedly available after closing zone {zone_index}")

    new_placeholder_count = count_placeholders(final_stage)
    if new_placeholder_count <= previous_placeholder_count:
        raise AssertionError(f"No new placeholder appeared after closing zone {zone_index}")

    return final_stage


def create_new_textedit_document() -> str:
    script = """
tell application "TextEdit"
    set newDoc to make new document
    delay 0.1
    set docWindow to front window
    set miniaturized of docWindow to false
    set index of docWindow to 1
    activate
    return name of newDoc
end tell
"""
    title = run_osascript(script)
    time.sleep(0.5)
    return title


def find_zone_entry(stage: Dict[str, Any], zone_index: int) -> Dict[str, Any]:
    for entry in stage["zones"]:
        if entry["zone"].get("index") == zone_index:
            return entry
    raise AssertionError(f"Zone {zone_index} not present in stage '{stage['label']}'")


def count_placeholders(stage: Dict[str, Any]) -> int:
    return sum(1 for window in stage["frames"] if window.get("is_placeholder"))


def format_frame(frame: Dict[str, Any]) -> str:
    return f"(x:{frame['x']}, y:{frame['y']}, w:{frame['width']}, h:{frame['height']})"


def frame_signature(frame: Dict[str, Any]) -> tuple[float, float, float, float]:
    """Create a rounded frame signature for approximate equality checks."""
    return tuple(round(float(frame[key]), 1) for key in ("x", "y", "width", "height"))


def format_deltas(zone_frame: Dict[str, Any], actual_frame: Dict[str, Any]) -> str:
    dx = actual_frame["x"] - zone_frame["x"]
    dy = actual_frame["y"] - zone_frame["y"]
    dw = actual_frame["width"] - zone_frame["width"]
    dh = actual_frame["height"] - zone_frame["height"]
    return f"Δx={dx:+.1f}, Δy={dy:+.1f}, Δw={dw:+.1f}, Δh={dh:+.1f}"


def print_report(stages: List[Dict[str, Any]]) -> None:
    print("=== LatticeTopology Window Positioning ===")
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


def ensure_textedit_ready() -> str:
    """Launch TextEdit and return the name of the front document."""
    run_osascript('tell application "TextEdit" to quit saving no')
    time.sleep(0.5)
    run_osascript('tell application "TextEdit" to activate')
    time.sleep(0.8)
    return create_new_textedit_document()


def make_new_textedit_document() -> str:
    """Create a new TextEdit document and return its title."""
    return create_new_textedit_document()


def cleanup(process: Optional[subprocess.Popen[Any]], created_titles: List[str]) -> None:
    """Stop LatticeTopology, remove socket, and shut down TextEdit."""
    try:
        unique_titles = list(dict.fromkeys(created_titles))
        for title in unique_titles:
            try:
                closed = close_textedit_document(title)
            except subprocess.CalledProcessError:
                closed = False
            status = "closed" if closed else "not found"
            print(f"Cleanup: requested close for TextEdit document '{title}' ({status})")
            log_winmanmon_snapshot(f"after close request for '{title}'")
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

    print("Building LatticeTopology…")
    run_command(["swift", "build"], capture=False)

    print("Starting LatticeTopology (socket mode)…")
    process = subprocess.Popen(
        ["./.build/debug/LatticeTopology", "--socket", f"--socket-path={SOCKET_PATH}"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        preexec_fn=os.setsid,
    )

    try:
        wait_for_socket(SOCKET_PATH)
        time.sleep(0.5)

        created_titles: List[str] = []
        initial_title = ensure_textedit_ready()
        created_titles.append(initial_title)
        capture_textedit_window(initial_title)
        time.sleep(SETTLE_SECONDS)

        stages: List[Dict[str, Any]] = []
        stages.append(collect_stage("single zone"))

        print("Adding second zone…")
        send_socket_command("add-zone")
        time.sleep(SETTLE_SECONDS)

        second_title = make_new_textedit_document()
        created_titles.append(second_title)
        capture_textedit_window(second_title)
        time.sleep(SETTLE_SECONDS)
        stages.append(collect_stage("two zones"))

        print("Adding third zone…")
        send_socket_command("add-zone")
        time.sleep(SETTLE_SECONDS)
        third_title = make_new_textedit_document()
        created_titles.append(third_title)
        capture_textedit_window(third_title)
        time.sleep(SETTLE_SECONDS)
        three_zones = collect_stage("three zones")
        stages.append(three_zones)

        final_stage = close_zone_window(
            zone_index=3,
            initial_stage=three_zones,
            fallback_title=third_title,
            stages=stages,
            stage_label="after closing zone 3 window",
        )

        final_stage = close_zone_window(
            zone_index=2,
            initial_stage=final_stage,
            fallback_title=second_title,
            stages=stages,
            stage_label="after closing zone 2 window",
        )

        final_stage = close_zone_window(
            zone_index=1,
            initial_stage=final_stage,
            fallback_title=initial_title,
            stages=stages,
            stage_label="after closing zone 1 window",
        )

        print_report(stages)
        return 0
    finally:
        cleanup(process, locals().get("created_titles", []))


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print("\nInterrupted", file=sys.stderr)
        sys.exit(1)
