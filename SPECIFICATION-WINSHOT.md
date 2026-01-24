# WinShot Snapshots

WinShot allows users to save and restore window arrangement snapshots. Unlike virtual screens, the same window can appear in multiple snapshots.

## Creating Snapshots

- Automatically created when pressing Clear/Reset Zones shortcut (Control-Cmd-Escape or variant) when the corresponding screen has managed windows in any zone (tiling or temporary).
- Automatically created before restoring a different snapshot (if current windows differ from snapshot being restored), allowing the user to return to their previous arrangement.
- Explicitly created with Control-Cmd-/ shortcut on the active screen.
- Each snapshot stores: zone configuration (count and frames), windows in zones (including temporary zone), active window info, and a low-resolution screenshot.
- Snapshots are screen-specific (cannot restore across screens).
- Max 10 snapshots per screen; oldest removed when limit exceeded.
- A snapshot is removed when any window in it is closed.
- If creating a snapshot with the same exact windows as an existing one, the old snapshot is replaced.

## Chooser Window

- Control-Cmd-Tab shows a floating horizontal strip chooser (like Command-Tab) on the active screen.
- Hold Control-Cmd and repeatedly press Tab/Shift-Tab to cycle through snapshots in forward or reverse order (respectively).
- Escape key or click outside to cancel.
- Release Control-Cmd to restore the selected snapshot. Alternatively, click on a snapshot to immediately restore it.
- Red "x" button on each snapshot allows deletion (appears on hover).

## Snapshot Restoration

- Restores zone configuration to the saved count and frames.
- Unminimizes windows that were minimized first, so users see new windows appear immediately.
- Current windows not in the snapshot are minimized afterward.
- Windows are pre-positioned (resized and moved) before unminimizing for smooth animation (see [SPECIFICATION-IMPLEMENTATION.md](SPECIFICATION-IMPLEMENTATION.md)).
- Activates the previously active window.
- **Targeting after restore:**
  - In "Targeting follows focus" mode: the zone containing the activated window becomes targeted.
  - In "Targeting independent of focus" mode: if the current target is on the restored screen, apply standard targeting rules (prefer lowest-index empty tiling zone, or temporary zone if all tiling zones are filled). If the current target is on another screen, leave targeting unchanged.

For temporary zone protection and notification suppression details, see [SPECIFICATION-IMPLEMENTATION.md](SPECIFICATION-IMPLEMENTATION.md).
