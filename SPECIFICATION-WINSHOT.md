# WinShot Snapshots

WinShot allows users to save and restore window arrangement snapshots. Unlike virtual screens, the same window can appear in multiple snapshots.

## Creating Snapshots

- Explicitly created with the Control-Cmd-/ (default) shortcut on the active screen.
- Automatically created according to the auto-save mode set in Preferences (see **Automatic Snapshots** below).
- Each snapshot stores: zone configuration (count and frames), windows in zones (including floating zone), active window info, Sticky Resize remembered sizes (if any), and a low-resolution thumbnail. The thumbnail is an abstract composite — each window in the snapshot is captured individually and drawn at its zone position on a plain background, with no desktop, other windows, or Zonogy interface shown. When a floating zone occupant exists, it is always recorded as the active window, although actually a non-overlapping tiling zone might be active (so that it becomes frontmost after restoration).
- Snapshots are screen-specific (cannot restore across screens).
- Max snapshots per screen is configured in Preferences; oldest removed when limit exceeded.
- A snapshot is removed when any window in it is closed.
- If creating a snapshot with the same zone occupancy signature as an existing one, the old snapshot is replaced. The signature includes each window's zone assignment, the floating-zone occupant, and which tiling zones are present even when empty.

## Automatic Snapshots

Preferences offers an auto-save mode with three settings, each a superset of the one before it:

- **Off**: snapshots are created only with the Control-Cmd-/ shortcut (default).
- **On Clear/Reset Zones**: Automatically captured before Clear/Reset Zones (default Control-Cmd-Escape). Switching to a different snapshot from the chooser likewise saves a snapshot first.
- **On every zone occupancy change**: everything the previous mode does, plus continuous background capture as described below.

### Auto-save on zone occupancy change

In this mode each screen's arrangement is saved automatically once it has stayed put for a configurable settle delay (default 3 seconds). A **zone occupancy change** is any change to which window occupies which zone (including moves and swaps between zones), and which tiling zones are present (so adding or removing a zone counts, even an empty one). Resizing zones, or changing only which window is active, is not an occupancy change. As with manual saves, an automatic capture whose occupancy signature matches an existing snapshot replaces it.

Tracking is per screen, and the settle delay restarts on each occupancy change so only the arrangement that ultimately settles is captured. Screens paused for a full-screen Space are not tracked.

Opening the chooser captures the current arrangement immediately, and a snapshot that settles while the chooser is open is saved without disturbing it.

## Chooser Window

- Control-Cmd-Tab shows a floating horizontal strip chooser (like Command-Tab) on the active screen.
- Hold Control-Cmd and repeatedly press Tab/Shift-Tab to cycle through snapshots in forward or reverse order (respectively).
- Escape key or click outside to cancel.
- Release Control-Cmd to restore the selected snapshot. Alternatively, click on a snapshot to immediately restore it.
- Red "x" button on each snapshot allows deletion (appears on hover).
- Thumbnails sit in a single horizontal row, most recent on the left. The gap between two consecutive thumbnails encodes the time elapsed between those snapshots. Spacing is relative to the whole set: intervals are scaled logarithmically — shortest tight, longest wide — so differences stay visible whether the set spans seconds or days. (Roughly even spacing stays uniformly tight; gaps open only where intervals genuinely differ.)
- The chooser window fits the gap-spaced thumbnails up to a fraction of the screen width, so wider screens show more at once; when the strip is wider than that, the chooser scrolls to keep the selected thumbnail visible.

## Snapshot Restoration

- With auto-save snapshots enabled, switching to a prior snapshot first saves the current arrangement. (This should be logically equivalent to first Clear/Reset Zones, and then restore.)
- Restores zone configuration to the saved count and frames.
- Unminimizes all windows (tiled and floating) in parallel first, so users see new windows appear immediately.
- Current windows not in the snapshot are minimized afterward.
- Restore treats these programmatic minimizations as best-effort requests that must be verified: after each minimize, perform a short delayed AX minimized-state check (with a retry if needed) before finalizing restore cleanup for that window.
- Windows are pre-positioned (resized and moved) before unminimizing for smooth animation (see [SPECIFICATION-IMPLEMENTATION.md](SPECIFICATION-IMPLEMENTATION.md)).
- Restores any saved Sticky Resize remembered sizes for the snapshot's windows, so manually resized windows return to their custom sizes when reactivated.
- Activates the previously active window.
- **Targeting after restore:**
  - If the current target is on the restored screen, apply standard targeting rules (prefer lowest-index empty tiling zone, or floating zone if all tiling zones are filled).
  - If the current target is on another screen, leave targeting unchanged.

For floating zone protection and notification suppression details, see [SPECIFICATION-IMPLEMENTATION.md](SPECIFICATION-IMPLEMENTATION.md).
