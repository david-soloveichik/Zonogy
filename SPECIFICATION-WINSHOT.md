# WinShot Snapshots

WinShot allows users to save and restore window arrangement snapshots. Unlike virtual screens, the same window can appear in multiple snapshots.

## Creating Snapshots

- With WinShot auto-save snapshots enabled in Preferences, Clear/Reset Zones (Control-Cmd-Escape or variant) captures the pre-clear arrangement when that screen has managed windows.
- Explicitly created with Control-Cmd-/ shortcut on the active screen.
- Each snapshot stores: zone configuration (count and frames), windows in zones (including temporary zone), active window info, and a low-resolution screenshot. When a temporary zone occupant exists, it is always recorded as the active window, although actually a non-overlapping tiling zone might be active (so that it becomes frontmost after restoration).
- Snapshots are screen-specific (cannot restore across screens).
- Max snapshots per screen is configured in Preferences; oldest removed when limit exceeded.
- A snapshot is removed when any window in it is closed.
- If creating a snapshot with the same zone occupancy signature as an existing one, the old snapshot is replaced. The signature includes each window's zone assignment, the temporary-zone occupant, and which tiling zones are present even when empty.

## Chooser Window

- Control-Cmd-Tab shows a floating horizontal strip chooser (like Command-Tab) on the active screen.
- Hold Control-Cmd and repeatedly press Tab/Shift-Tab to cycle through snapshots in forward or reverse order (respectively).
- Escape key or click outside to cancel.
- Release Control-Cmd to restore the selected snapshot. Alternatively, click on a snapshot to immediately restore it.
- Red "x" button on each snapshot allows deletion (appears on hover).
- The chooser window width scales with screen width; the number of thumbnails visible without scrolling increases on wider screens, but never exceeds the WinShot "max snapshots stored" setting.
- The chooser renders a horizontal timeline rail above thumbnails. Each snapshot has a timeline point whose x-position reflects its `createdAt` timestamp (most recent on the left), so visible gaps on the rail represent time gaps.
- Thumbnail tiles remain evenly spaced. Each timeline point connects to its corresponding thumbnail with an orthogonal arrow path (down, then horizontal, then down); horizontal segments are staggered onto nearby lanes to avoid connector crossings whenever possible. Hovering or selecting a thumbnail highlights that snapshot's connector and timeline point.

## Snapshot Restoration

- With auto-save snapshots enabled, switching to a prior snapshot first saves the current arrangement. (This should be logically equivalent to first Clear/Reset Zones, and then restore.)
- Restores zone configuration to the saved count and frames.
- Unminimizes all windows (tiled and temporary) in parallel first, so users see new windows appear immediately.
- Current windows not in the snapshot are minimized afterward.
- Restore treats these programmatic minimizations as best-effort requests that must be verified: after each minimize, perform a short delayed AX minimized-state check (with a retry if needed) before finalizing restore cleanup for that window.
- Windows are pre-positioned (resized and moved) before unminimizing for smooth animation (see [SPECIFICATION-IMPLEMENTATION.md](SPECIFICATION-IMPLEMENTATION.md)).
- Activates the previously active window.
- **Targeting after restore:**
  - In "Targeting follows focus" mode: the zone containing the activated window becomes targeted.
  - In "Targeting independent of focus" mode: if the current target is on the restored screen, apply standard targeting rules (prefer lowest-index empty tiling zone, or temporary zone if all tiling zones are filled). If the current target is on another screen, leave targeting unchanged.

For temporary zone protection and notification suppression details, see [SPECIFICATION-IMPLEMENTATION.md](SPECIFICATION-IMPLEMENTATION.md).
