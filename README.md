# Zonogy

Zonogy is a zone-based window manager for macOS. (The name suggests "the origin or formation of zones.") Zonogy is free and open source.

Zonogy divides each screen into persistent tiling zones plus a floating zone, with one zone targeted for the next window. Entire arrangements can be snapshotted to switch working contexts, and you can find any window with a keyboard-driven Launcher or hover-over Dock menus.

> Philosophy: An intentional place for every window.

<img src="docs/images/hero-screenshot.png" alt="Hero screenshot, showing various features of Zonogy" style="zoom: 35%;" />

## Overview

Zonogy rethinks multiple aspects of the operating system UI, including window management, virtual desktops, application/window launching, and interacting with the Dock.

**Window management:** Tiling window managers promise to tame a cluttered screen but they feel twitchy. Every time you open, close, or minimize a window, the entire layout reflows. Zonogy takes a different approach, allowing you to define zones that persist even when empty, so your layout stays stable. An additional floating zone on each screen lets you float a window above others when you need quick access to a window without disrupting the tiling zones.

**Virtual desktops**: Virtual desktops like macOS's built-in Spaces have a limitation that a window can only belong to one space, yet the same window often belongs to more than one task. With Zonogy's **WinShot snapshots**, you can save and restore different window arrangements that could share the same windows.

**Application/window launching and switching:** Most launchers and Spotlight let you switch to an *application*, or a specific *document*, but not a specific *window.* Zonogy's **CmdTab** replacement allows fast switching between open windows. Zonogy's **DockMenus** lets you hover over any Dock icon to see that app's windows and pick one, or just click the Dock icon to open the app's "main" or most recently used window. The **Launcher** takes a fast-search approach: Drill down into an app and search its windows by title within an overlay that appears directly in the zone you're about to fill. The Launcher also allows general shortcuts to files and folders with optional aliases (search keywords), and learns over time.

Drag and drop is woven throughout. For example, windows can be swapped between zones. An app can be dragged from the Dock to a zone to open it there, and similarly for documents or URLs. Items can be dragged onto visual indicators (along screen edge) to place them in a new tiling zone or the floating zone.

Multi-screen setups are first-class and each screen gets its own independent set of zones.

## Core Concepts

### Zones

Each screen has 1–3 **tiling zones** that form the main layout, plus a **floating zone** for floating a single window above the tiles. Empty tiling zones show a "placeholder" so you can see the structure of your layout and drag content into them.

Exactly one zone is **targeted** at any moment, indicated by a glowing indicator above the zone. New or unminimized windows are always placed into the targeted zone.

<img src="docs/images/zone-layouts.svg" alt="Zones core concepts" style="zoom: 25%;"/>

Filling the targeted tiling zone advances to the next empty tiling zone (or the floating zone if none are empty). Emptying a tiling zone makes it targeted automatically. You can target any tiling zone with `Control-Cmd`-click. (Alternative mode: "target follows focus", where activating a window retargets to that window's zone.)

## Features

- **Launcher** (`Control-Cmd-Space`) — a searchable overlay for switching windows, launching apps, and opening folders or documents. Fuzzy matching with smart ranking: it learns which items you pick for each query and prioritizes them next time. Supports optional short aliases for quick access. Appears directly in the targeted zone and auto-shows when a zone becomes empty.

<img src="docs/images/launcher.png" alt="Launcher" style="zoom: 35%;" /><img src="docs/images/launcher-preferences.png" alt="Launcher Preferences window" style="zoom: 35%;" />

- **CmdTab** (`Cmd-Tab`) — a fast window switcher replacing the macOS app switcher. Hold Cmd and tap Tab to cycle windows ordered by recency.

- **WinShot Snapshots** (`Control-Cmd-/` to save, `Control-Cmd-Tab` to browse) — save and restore entire window arrangements. A visual timeline chooser lets you scrub through past snapshots.

<img src="docs/images/winshot-chooser.png" alt="WinShot Chooser" style="zoom: 35%;" />

- **DockMenus** — hover over any Dock icon to see a compact panel of that app's windows. Click to activate, or drag the icon or a window entry onto a zone to place it there. Shift-click bypasses Zonogy for normal Dock behavior.

<img src="docs/images/dockmenus.png" alt="DockMenus" style="zoom: 35%;" />

- **ActiveFit** — windows in the right column that can't shrink to fit are automatically shifted into view when focused (outside of their zone's bounds), then slide back when you move on.
- **UnderCovers mode** — reveal the desktop and unmanaged windows.

## Mouse Controls

| Gesture | Action |
| --- | --- |
| Click new zone pill (on right edge of each screen) | Add a tiling zone |
| Click floating zone targeting indicator (on bottom edge of each screen) | Target the floating zone |
| `Control-Cmd`-click anywhere in a zone (even if zone is occupied) | Target that zone |
| Drag resize bar between zones (appears on hover) | Adjust zone proportions live |
| Drag window → tiling zone | Move it there, swapping if occupied |
| Drag window → new zone pill | Add a zone and place the window in it |
| Drag window → floating zone indicator | Float the window above the tiles |
| Hold `Control-Cmd` during window drag | Promote between tiled and floating zone |
| Drag file or URL → empty zone or new zone pill | Open it there in the default app |
| Hold `Control-Cmd` during file or URL drag | Replace zone occupant with the dragged item opened in default app |
| Drag Dock icon or DockMenu window → zone | Place that window there (or launch the app) |

## Default Keyboard Shortcuts (configurable)

> **Tip:** Most default Zonogy shortcuts use `Control-Cmd` as the modifier. Using [Karabiner-Elements](https://karabiner-elements.pqrs.org/) to remap Caps Lock to `Control-Cmd` makes all of them single-hand accessible — e.g., Caps Lock + Space opens the Launcher.

| Shortcut | Action |
| --- | --- |
| `Control-Cmd-=` | Add a zone |
| `Control-Cmd--` | Remove zone (following preference order, keeping current window open) |
| `Cmd-M` | Minimize active window; with Launcher open, removes the zone (so `Cmd-M` twice = minimize + remove zone) |
| `Cmd-Tab` | CmdTab window switcher (<code>Cmd-\`</code> cycles current app's windows) |
| `Control-Cmd-/` | Save WinShot snapshot |
| `Control-Cmd-Tab` | Browse WinShot snapshots |
| `Control-Cmd-Arrows` | Change target zone with arrow keys |
| `Control-Cmd-Space` | Open Launcher in targeted zone |
| `Control-Cmd-Escape` | Clear zones on active screen (optionally automatically saving snapshot). Pressing twice resets to single-zone layout. |

## Requirements

- **macOS** — tested on Sequoia 15.7.3 and Tahoe 26.3
- **Accessibility Permissions** — required for window management (moving, resizing, and reading window properties via the Accessibility API) and for global keyboard/mouse event monitoring (CmdTab's Cmd-Tab override, shortcuts, and zone click targeting)
- **Screen Recording Permissions** — only needed for the WinShot snapshot feature, which captures screenshot thumbnails for the snapshot chooser.
- **Automation Permissions** — needed to open web links in a new browser window when URLs are dropped onto zones. macOS will prompt you to grant Automation access for each browser individually. This applies to Safari, Chrome, and Edge (which use AppleScript). Firefox uses direct process launching instead and does not require this permission.

## Development

Zonogy is developed with [Claude Code](https://claude.ai/claude-code) and [Codex](https://openai.com/index/codex/), following a specification-driven approach. The `SPECIFICATION*.md` files in the repo serve as the single source of truth for behavior and double as detailed documentation — see them for a much more extensive description of Zonogy's functionality than this README covers.

## History

My day job is [teaching and research at UT Austin](https://www.solo-group.link/), but better UI is a passionate hobby. I originally built Zonogy for myself and decided to share it in case others find it useful. The project is unapologetically *opinionated* and reflects how I work. For example, I've never needed more than 3 tiled windows per screen (plus a floating-zone slot), so that defines the current limit. Of course, Zonogy is open source, and contributions, experiments, and personal forks are all welcome.

## Additional suggestions

Remove the Zoom button floating menu; we won't use the Zoom button for anything other than making the window full-screen.

```sh
$ defaults write -g NSZoomButtonShowMenu -bool no
$ # to bring it back:
$ defaults delete -g NSZoomButtonShowMenu
```
