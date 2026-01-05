# AltTab

AltTab provides a window switcher overlay for Zonogy, allowing quick navigation between recently used managed windows using a Cmd-Tab-style keyboard chord. It is analogous to the Launcher feature but optimized for quickly switching between windows.

## Overview

AltTab shows a single list of all managed windows (both minimized and unminimized) ordered by last used (most recent first), allowing the user to quickly switch between windows using a familiar Cmd-Tab interaction pattern.

AltTab MUST override the system app switcher for its configured shortcut. This requires macOS **Input Monitoring** permission and uses a keyboard `CGEventTap` to swallow the matching key events so the system app switcher does not appear.

## Activation

- **Default shortcut:** Cmd-Tab (configurable in Zonogy Preferences)
- **App-specific shortcut:** Cmd-` (configurable in Zonogy Preferences) — shows only windows from the currently active application
- AltTab appears in the same location as the Launcher would appear when invoked
- The configured shortcut may include multiple modifiers (e.g. Control-Command-Tab)

## UI / Presentation

- **No search field** — unlike the Launcher, AltTab is purely navigational
- **Single flat list** of all managed windows across all applications, ordered by last used (most recently used at the top)
- **Window entries:** Each entry displays:
  - Application icon (same style as Launcher)
  - Window title (same truncation rules as Launcher)
- Visual styling should match the Launcher (vibrancy/blur, rounded corners, selection highlight)

## Navigation

- **Cycling:** While holding the configured modifier(s), pressing the shortcut key repeatedly (default: Tab) moves selection to the next window in the list
- **Direction:** Each press moves selection down the list (toward less recently used windows). Holding Shift cycles backward.
- Selection wraps to the top when reaching the bottom of the list
- On first show, AltTab selects the second item (index 1), which is the previously active window (index 0 is the currently active window). If no managed window is currently focused, it selects the first item (index 0). If invoked with Shift held, it selects the least-recent window.

## Actions

- **Window activation:** Releasing the modifier key activates the currently selected window
- **Minimized windows:** Placed into the targeted zone (same behavior as Launcher)
- **Unminimized windows:** Activated in place without being moved to the targeted zone (note: this is different from Launcher)
- While AltTab is visible, clicking a window row activates that window immediately and dismisses AltTab (even if modifiers are still held).
  Note: There is potential conflict with the "Control-Command-Click" gesture that targets zones (it is globally intercepted and consumed). So while AltTab is visible, we disable the "Control-Command-Click" targeting gesture so:
  - Row clicks can activate as expected
  - Outside clicks can dismiss AltTab as expected

## Dismissal

- **Activate:** Releasing the modifier key dismisses AltTab and activates the selected window
- **Cancel:** Pressing Escape dismisses AltTab without activating any window (even if the modifier key is still held)
- **Cancel:** Clicking outside the AltTab window dismisses AltTab without activating any window

## App-Specific Mode (Cmd-`)

When invoked with the app-specific shortcut (default Cmd-`), AltTab shows only windows belonging to the currently active application:

- **Header:** Displays "[App Name] Windows" instead of "Switch Windows"
- **Window list:** Filtered to show only windows from the frontmost application
- **Empty state:** If the current app has no managed windows, or if the frontmost app has no bundle identifier, the empty state is shown
- **All other behavior** (navigation, activation, dismissal) is identical to the standard AltTab

## Settings

- Keyboard shortcut configurable in Zonogy Preferences (default: Cmd-Tab)
- App-specific shortcut configurable in Zonogy Preferences (default: Cmd-`)
- The modifier(s) for cycling are derived from the configured shortcut

## Implementation Notes

- Reuse Launcher components and code paths wherever possible:
  - Window list rendering
  - Window entry styling and title truncation
  - Window activation logic
  - Panel positioning and visual style
- The window order should be maintained by tracking window activation timestamps
- Keyboard interception should use a `CGEventTap` for `keyDown` + `flagsChanged` events and swallow matching events to override the system app switcher
