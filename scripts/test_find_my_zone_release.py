#!/usr/bin/env python3
"""
Troubleshooting script for investigating Find My window teardown handling.

The script launches LatticeTopology in socket mode, brings the Find My
application to the front, captures its window, and then quits Find My while
recording zone assignments, socket metadata, and winmanmon output. The goal is
to highlight cases where a zone continues to reference a window that has been
closed.

Usage:
    python3 scripts/test_find_my_zone_release.py
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
from typing import Any, Dict, List, Optional, Tuple

DELAY = 1.0
FIND_MY_BUNDLE_ID = "com.apple.findmy"
SOCKET_PATH = Path("/tmp/lattice-topology-findmy.sock")
FIND_MY_APP_PATH = "/System/Applications/FindMy.app"
REQUEST_COUNTER = itertools.count(1)
MODULE_CACHE_DIR = Path("/tmp/lattice-swift-modulecache")
CAPTURE_LOGS_ENV = "LT_DEBUG_CAPTURE_LOGS"
CAPTURE_LOGS = os.getenv(CAPTURE_LOGS_ENV) == "1"

os.environ.setdefault("SWIFT_MODULECACHE_PATH", str(MODULE_CACHE_DIR))
os.environ.setdefault("CLANG_MODULE_CACHE_PATH", str(MODULE_CACHE_DIR))
os.environ.setdefault("MODULE_CACHE_DIR", str(MODULE_CACHE_DIR))
MODULE_CACHE_DIR.mkdir(parents=True, exist_ok=True)


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


def wait_for_socket(path: Path, timeout: float = 10.0) -> None:
    """Wait until the Unix socket appears on disk."""
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


def ensure_find_my_closed() -> None:
    """Exit Find My if it's currently running."""
    script = '''
try
    tell application "System Events"
        set isRunning to (exists process "FindMy")
    end tell
    if isRunning then
        tell application id "com.apple.findmy" to quit
    end if
on error
    -- Ignore errors; the goal is simply best-effort shutdown
end try
'''
    try:
        run_osascript(script)
    except subprocess.CalledProcessError:
        pass
    time.sleep(DELAY)


def launch_find_my() -> None:
    """Launch the Find My application and bring it to the front."""
    print("Launching Find My…")
    run_command(["open", "-a", FIND_MY_APP_PATH], capture=False)
    time.sleep(DELAY)
    script = '''
tell application id "com.apple.findmy"
    activate
end tell
tell application "System Events"
    tell process "FindMy"
        set frontmost to true
    end tell
end tell
'''
    run_osascript(script)
    time.sleep(DELAY)


def wait_for_find_my_window(timeout: float = 10.0) -> Tuple[bool, List[Dict[str, Any]]]:
    """Poll winmanmon until a Find My window appears or timeout expires."""
    deadline = time.time() + timeout
    last_snapshot: List[Dict[str, Any]] = []
    while time.time() < deadline:
        snapshot = get_winmanmon()
        last_snapshot = snapshot
        if any(window.get("bundleIdentifier") == FIND_MY_BUNDLE_ID for window in snapshot):
            return True, snapshot
        time.sleep(0.5)
    return False, last_snapshot


def collect_stage(label: str) -> Dict[str, Any]:
    """Capture zone data, window metadata, and winmanmon output."""
    managed_windows: List[Dict[str, Any]] = []
    targeted_zone: Optional[Dict[str, Any]] = None
    managed_error: Optional[str] = None
    try:
        managed_state = send_socket_command("managed-windows")
        managed_windows = managed_state.get("windows", [])
        targeted_zone = managed_state.get("targeted_zone")
    except CommandError as exc:
        managed_error = str(exc)

    zones = send_socket_command("list").get("zones", [])
    zone_entries: List[Dict[str, Any]] = []
    for zone in zones:
        window_id = zone.get("window_id")
        info = None
        error: Optional[str] = None
        if window_id is not None:
            try:
                info = send_socket_command("window-info", {"window_id": window_id})
            except CommandError as exc:
                error = str(exc)
        zone_entries.append({"zone": zone, "info": info, "error": error})

    frames = send_socket_command("frames").get("windows", [])
    find_my_windows = [
        window for window in get_winmanmon() if window.get("bundleIdentifier") == FIND_MY_BUNDLE_ID
    ]

    find_my_running = False
    try:
        result = run_osascript(
            '''
            tell application "System Events"
                return (exists process "FindMy")
            end tell
            '''
        )
        find_my_running = result.lower() == "true"
    except subprocess.CalledProcessError:
        pass

    return {
        "label": label,
        "zones": zone_entries,
        "frames": frames,
        "findmy_windows": find_my_windows,
        "findmy_running": find_my_running,
        "managed_windows": managed_windows,
        "managed_windows_error": managed_error,
        "targeted_zone": targeted_zone,
    }


def format_frame(frame: Dict[str, Any]) -> str:
    return f"(x:{frame['x']}, y:{frame['y']}, w:{frame['width']}, h:{frame['height']})"


def format_deltas(zone_frame: Dict[str, Any], actual_frame: Dict[str, Any]) -> str:
    dx = actual_frame["x"] - zone_frame["x"]
    dy = actual_frame["y"] - zone_frame["y"]
    dw = actual_frame["width"] - zone_frame["width"]
    dh = actual_frame["height"] - zone_frame["height"]
    return f"Δx={dx:+.1f}, Δy={dy:+.1f}, Δw={dw:+.1f}, Δh={dh:+.1f}"


def extract_pid_from_stage(stage: Dict[str, Any], bundle_id: str) -> Optional[int]:
    for entry in stage.get("managed_windows", []):
        if entry.get("bundle_identifier") == bundle_id:
            pid = entry.get("pid")
            if isinstance(pid, int):
                return pid
    return None


def print_report(stages: List[Dict[str, Any]]) -> None:
    print("=== LatticeTopology Find My Closure Debug ===")
    for stage in stages:
        print(f"\nStage: {stage['label']}")
        for entry in stage["zones"]:
            zone = entry["zone"]
            zone_frame = zone["frame"]
            window_id = zone.get("window_id")
            if window_id is None:
                print(f"  Zone {zone['index']} frame {format_frame(zone_frame)} -> empty")
                continue

            print(f"  Zone {zone['index']} frame {format_frame(zone_frame)} -> window {window_id}")

            info = entry["info"]
            if info:
                actual = info["actual_frame"]
                print(
                    f"    window-info actual {format_frame(actual)} "
                    f"({format_deltas(info['zone_frame'], actual)})"
                )
                print(f"    owning app: {info.get('application_name', '<unknown>')}")
            elif entry["error"]:
                print(f"    window-info error: {entry['error']}")
            else:
                print("    (no additional data)")

        if stage.get("managed_windows_error"):
            print(f"  managed-windows error: {stage['managed_windows_error']}")
        else:
            managed_windows = stage.get("managed_windows", [])
            if managed_windows:
                print("  Managed windows:")
                for window in managed_windows:
                    window_id = window.get("window_id")
                    zone_index = window.get("zone_index")
                    screen_id = window.get("screen_display_id")
                    if isinstance(screen_id, (int, float)):
                        screen_desc = f"screen {int(screen_id)}"
                    elif screen_id is not None:
                        screen_desc = f"screen {screen_id}"
                    else:
                        screen_desc = "no screen"
                    placeholder_suffix = " placeholder" if window.get("is_placeholder") else ""
                    pid_value = window.get("pid")
                    bundle = window.get("bundle_identifier") or "<unknown>"
                    zone_desc = f"zone {zone_index}" if zone_index is not None else "unassigned"
                    window_number = window.get("window_number")
                    window_number_desc = f", window_number {window_number}" if window_number is not None else ""
                    print(
                        "    window {wid}: {typ}{ph}{wn}, {zone} on {screen}, pid {pid_repr} ({bundle})".format(
                            wid=window_id,
                            typ=window.get("type", "unknown"),
                            ph=placeholder_suffix,
                            wn=window_number_desc,
                            zone=zone_desc,
                            screen=screen_desc,
                            pid_repr=pid_value if pid_value is not None else "?",
                            bundle=bundle,
                        )
                    )
            else:
                print("  Managed windows: none")

        targeted = stage.get("targeted_zone")
        if targeted:
            screen_id = targeted.get("screen_display_id")
            if isinstance(screen_id, (int, float)):
                screen_desc = f"screen {int(screen_id)}"
            elif screen_id is not None:
                screen_desc = f"screen {screen_id}"
            else:
                screen_desc = "unknown screen"
            zone_index = targeted.get("index")
            print(f"  Targeted zone: {zone_index} on {screen_desc}")

        find_my_windows = stage["findmy_windows"]
        print(f"  Find My running (System Events): {stage['findmy_running']}")
        if find_my_windows:
            print("  Find My windows (winmanmon):")
            for window in find_my_windows:
                title = window.get("title") or "<untitled>"
                print(f"    {title} id {window['windowID']}: {format_frame(window['dimensions'])}")
        else:
            print("  Find My windows (winmanmon): none")

        placeholders = [w for w in stage["frames"] if w.get("is_placeholder")]
        if placeholders:
            print("  Placeholders:")
            for placeholder in placeholders:
                print(f"    id {placeholder['window_id']}: {format_frame(placeholder['frame'])}")


def cleanup(process: Optional[subprocess.Popen[Any]]) -> None:
    """Terminate LatticeTopology and ensure Find My is closed."""
    ensure_find_my_closed()

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

    ensure_find_my_closed()

    print("Building LatticeTopology…")
    run_command(["swift", "build"], capture=False)

    print("Starting LatticeTopology (socket mode)…")
    process = subprocess.Popen(
        ["./.build/debug/LatticeTopology", "--socket", f"--socket-path={SOCKET_PATH}"],
        stdout=None if CAPTURE_LOGS else subprocess.DEVNULL,
        stderr=None if CAPTURE_LOGS else subprocess.DEVNULL,
        preexec_fn=os.setsid,
    )

    stages: List[Dict[str, Any]] = []
    find_my_pid: Optional[int] = None

    try:
        wait_for_socket(SOCKET_PATH)
        stage = collect_stage("after launch")
        stages.append(stage)
        if find_my_pid is None:
            find_my_pid = extract_pid_from_stage(stage, FIND_MY_BUNDLE_ID)

        launch_find_my()
        found, _ = wait_for_find_my_window()
        if not found:
            print("Warning: Find My window not detected via winmanmon; continuing anyway.")
        else:
            print("Find My window detected via winmanmon.")

        print("Capturing frontmost window via socket command…")
        try:
            result = send_socket_command("capture-frontmost")
            assigned_zone = result.get("zone_index")
            window_id = result.get("window_id")
            print(f"capture-frontmost: window {window_id} -> zone {assigned_zone}")
        except CommandError as exc:
            print(f"capture-frontmost failed: {exc}")

        stage = collect_stage("after capture-frontmost")
        stages.append(stage)
        if find_my_pid is None:
            find_my_pid = extract_pid_from_stage(stage, FIND_MY_BUNDLE_ID)

        print("Waiting for zone synchronization…")
        time.sleep(1.5)
        stage = collect_stage("after stabilization delay")
        stages.append(stage)
        if find_my_pid is None:
            find_my_pid = extract_pid_from_stage(stage, FIND_MY_BUNDLE_ID)

        print("Quitting Find My…")
        ensure_find_my_closed()

        print("Waiting for teardown propagation…")
        time.sleep(2.0)
        stage = collect_stage("after quit + 2s")
        stages.append(stage)

        if find_my_pid is not None:
            print(f"Invoking validate-application for pid {find_my_pid}…")
            try:
                result = send_socket_command("validate-application", {"pid": find_my_pid})
                print(f"validate-application result: {result}")
            except CommandError as exc:
                print(f"validate-application failed: {exc}")
            stages.append(collect_stage("after validate-application"))
        else:
            print("Skipping validate-application: no Find My pid recorded.")

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
