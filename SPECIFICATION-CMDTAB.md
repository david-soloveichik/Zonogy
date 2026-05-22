# CmdTab

CmdTab provides a window switcher overlay for Zonogy, allowing quick navigation between recently used managed windows using a Cmd-Tab-style keyboard chord. It is analogous to the Launcher feature but optimized for quickly switching between windows.

## Overview

CmdTab shows a single list of all managed windows (both minimized and unminimized) ordered by last used (most recent first), allowing the user to quickly switch between windows using a familiar Cmd-Tab interaction pattern.

CmdTab MUST override the system app switcher for its configured shortcut. This requires macOS **Input Monitoring** permission and uses a keyboard `CGEventTap` to swallow the matching key events so the system app switcher does not appear.

## Activation

- **Default shortcut:** Cmd-Tab (configurable in Zonogy Preferences)
- **App-specific shortcut:** Cmd-` (configurable in Zonogy Preferences) — shows only windows from the currently active application
- **Optional active-window retargeting:** When the `CmdTab targets zone with active window` Targeting preference is enabled (default on), CmdTab first retargets to the zone containing the currently active managed window, unless the Launcher is visible. Launcher is always shown on the current target, so while it is visible CmdTab leaves targeting unchanged.
- CmdTab appears in the same location as the Launcher would appear when invoked
- The configured shortcut may include multiple modifiers (e.g. Control-Command-Tab)
- **Targeting invariant:** While CmdTab is visible, any target change re-centers CmdTab onto the new target — whether it is a floating zone, an empty tiling zone, or an occupied tiling zone. Unlike the Launcher, CmdTab does not dismiss when retargeting to an occupied tiling zone.

## UI / Presentation

- **No search field** — unlike the Launcher, CmdTab is purely navigational
- **Single flat list** of all managed windows across all applications, ordered by last used (most recently used at the top)
- **Window entries:** Each entry displays:
  - Application icon (same style as Launcher)
  - Window title (same truncation rules as Launcher)
- Visual styling should match the Launcher (vibrancy/blur, rounded corners, selection highlight)

## Navigation

- **Cycling:** While holding the configured modifier(s), pressing the shortcut key repeatedly (default: Tab) moves selection to the next window in the list
- **Direction:** Each press moves selection down the list (toward less recently used windows). Holding Shift cycles backward.
- **Wrap behavior:** In app-specific mode (Cmd-`), selection wraps around at list boundaries. In all-windows mode (Cmd-Tab), selection stops at the first/last item. (Wrapping works well with a few windows, but with many windows, rolling over, eg, to the least-recently-used window is unexpected.)
- On first show, CmdTab selects the second item (index 1), which is the previously active window (index 0 is the currently active window). If no managed window is currently focused, it selects the first item (index 0). If invoked with Shift held, it selects the least-recent window.

## Actions

- **Window activation:** Releasing the modifier key activates the currently selected window
- **Minimized windows:** Placed using the same placement rules as Launcher. Normally this means the targeted zone, but app-specific placement exceptions may redirect to the floating zone.
- **Unminimized windows:** Activated in place without being moved to the targeted zone (note: this is different from Launcher)
- While CmdTab is visible, clicking a window row activates that window immediately and dismisses CmdTab (even if modifiers are still held).
- **Clicks outside the CmdTab window while it's open retarget:**
  - A left-click (with or without Control-Command) inside a tiling zone targets that zone and flashes its border, just like Control-Command-click does normally.
  - A click on the floating-zone indicator targets the floating zone; while CmdTab is visible this never opens the Launcher, even if the floating zone was already targeted. Other Zonogy UI (placeholders, add-zone pill, resize bars) behaves normally.
- **Dragging a window row out:** Same drag-and-drop behavior as dragging a window row from the Launcher; CmdTab dismisses on drag start. A drop outside any target, or Escape mid-drag, cancels the drag and restores the pre-CmdTab target under the same rules as a CmdTab cancel.

## Dismissal

- **Activate:** Releasing the modifier key dismisses CmdTab and activates the selected window
- **Cancel:** Pressing Escape dismisses CmdTab without activating any window (even if the modifier key is still held)
- **Cancel:** Clicking outside every tiling zone and Zonogy UI dismisses CmdTab.
- **Target restoration:** CmdTab's open-time retarget is temporary. It commits when the user's selection places a window (unminimizing a minimized window or opening a new one). Otherwise — cancel, activating an already-placed window, or the user moving the target elsewhere mid-chooser — the pre-CmdTab target is restored only if the current target still matches the one CmdTab set on open; if the target has since moved (even to a zone and back), restoration is skipped.
- **Launcher shortcut:** Pressing the Launcher keyboard shortcut while CmdTab is visible dismisses CmdTab and opens the Launcher. The target remains wherever CmdTab had it (no additional retarget), and CmdTab's retarget session is inherited by the Launcher so a subsequent Launcher cancel follows the same pre-CmdTab restoration rule above.
- CmdTab dismisses if its screen enters full-screen pause.

## App-Specific Mode (Cmd-`)

When invoked with the app-specific shortcut (default Cmd-`), CmdTab shows only windows belonging to the currently active application:

- **Header:** Displays "[App Name] Windows" instead of "Switch Windows"
- **Window list:** Filtered to show only windows from the frontmost application
- **Empty state:** If the current app has no managed windows, or if the frontmost app has no bundle identifier, the empty state is shown
- **All other behavior** (navigation, activation, dismissal) is identical to the standard CmdTab

## Settings

- Keyboard shortcut configurable in Zonogy Preferences (default: Cmd-Tab)
- App-specific shortcut configurable in Zonogy Preferences (default: Cmd-`)
- `CmdTab targets zone with active window` toggle in Preferences → Targeting (default on)
- The modifier(s) for cycling are derived from the configured shortcut

## Implementation Notes

- Reuse Launcher components and code paths wherever possible:
  - Window list rendering
  - Window entry styling and title truncation
  - Window activation logic
  - Panel positioning and visual style
- The window order should be maintained by tracking window activation timestamps
- To avoid contaminating recency with brief intermediate activations, only record a focus-based activation if the window remains focused for at least **250ms** (shorter focus changes are ignored)
- Keyboard interception should use a `CGEventTap` for `keyDown` + `flagsChanged` events and swallow matching events to override the system app switcher
