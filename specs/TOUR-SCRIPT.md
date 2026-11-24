# Tour script

Every word the tour shows, chapter by chapter, in the order it appears. The app does not read this file: the
words live in `Sources/Tour/` and in the scene generators run by `scripts/build-tour-animations.sh`, and this
script is kept in sync with them. To change the wording, edit it here and have the edit (see `git diff`)
carried into the sources; pages and captions are then re-checked to still fit.

## How to edit

- Change wording freely. You can also delete, add, split, merge, or reorder paragraphs, bullets, and pages.
- Keep each block's marker, so the edit can be traced back to the sources:
  - `## Chapter: Welcome` starts a chapter. Its name labels the chapter's icon in the window's toolbar.
  - `### 3. Zones` is a page; the text after the number is the page's title.
  - A plain paragraph is a paragraph of body text.
  - `- **Lead** text` is a bullet. The bold part is set in bold in the app.
  - `> Try it: ...` is the tinted "Try it" line. The words "Try it:" are added by the app.
  - `[Button: ...]`, `[Checkbox: ...]`, `[Banners: ...]` and `[Pictograms: ...]` are controls and pictures. Only a button's or checkbox's title can be edited here.
  - Lines under `Scene captions` are text drawn inside the animation above the page: `Caption:` lines appear one after another under the picture, `Label:` lines point at parts of it, and `Keycap:` lines are the words on keycaps drawn under the display (keys the user can change say what they do instead of naming a key).
- Keep the `{tokens}`. The app replaces each with the user's current binding.

| Token | Stands for | Default |
|---|---|---|
| `{minimize}` | Minimize Focused Window | ⌘M |
| `{add zone}` | Add Zone | ⌃⌘= |
| `{one zone}` | Collapse to One Zone | ⌃⌘0 |
| `{clear}` | Clear/Reset Zones (Active Display) | ⌃⌘⎋ |
| `{launcher}` | Show Launcher | ⌃⌘Space |
| `{cmdtab}` | CmdTab Window Switcher | ⌘⇥ |
| `{gesture keys}` | the Mouse Gestures modifiers | ⌃⌘ |
| `{navigation keys}` | the Zone Navigation modifiers | ⌃⌘ |
| `{move key}` | the key of Move Focused Window to Destination | ↩ |
| `{launcher key}` | the key of Show Launcher | Space |
| `{add key}` | the key of Add Zone | = |
| `{remove key}` | the key of Remove Zone | - |
| `{minimize key}` | the key of Minimize Focused Window | M |
| `{jump top-right}` | the jump key for the top-right zone | S |
| `{save snapshot}` | Save WinShot Snapshot | ⌃⌘/ |
| `{chooser hold}` | the modifiers of Show WinShot Switcher | ⌃⌘ |
| `{chooser tap}` | the key of Show WinShot Switcher | ⇥ |

## What limits the wording

- **Window height.** The window is as tall as the tour's tallest page, in any chapter. Heights now, in points: Welcome 366, 206, 500, 558, 570, 552, 274, 114; Keyboard 555, 529, 529, 555, 583, 256; WinShot Snapshots 528, 326, 488. The scene takes 378 of that on a one-display page, 407 on one with keycaps under the display, and 258 on a two-display page. A line of body text is about 16 points, and holds about 88 characters.
- **Captions** sit on one line under the picture. The longest now is 70 characters; much longer will not fit.
- **Labels** are placed by hand around the picture. Keep them about as short as they are.
- **Shared text.** Four things here are also used elsewhere, so changing them changes that place too unless you say otherwise:
  - The captions of the Welcome page's scene are the README hero animation's captions.
  - The banner text is also shown in Preferences > General.
  - "Enable WinShot" is also the checkbox title in Preferences > Snapshots.
  - The two pictogram captions on the Jump keys page are also shown in Preferences > Shortcuts > Zone Navigation.

---

## Chapter: Welcome

### 1. Welcome to Zonogy

Scene captions (`welcome`, shared with the README):
- Caption: Minimizing a window opens the Launcher in that zone to fill it
- Caption: Or hover over a Dock icon and drag a specific window

Zonogy keeps your windows in zones: areas of the display that persist even when empty. The next window opens in the destination zone.

Zonogy replaces Spaces and Stage Manager, so turn Stage Manager off.

### 2. Permissions

[Banners: Accessibility, Screen Recording]

- **Accessibility** is required. It lets Zonogy move and resize windows and respond to its shortcuts.
- **Screen Recording** is optional. It is used only for the thumbnails of WinShot snapshots.

Zonogy restarts once Accessibility is granted, and this tour continues.

### 3. Zones

Scene captions (`zones`):
- Label: New Zone Bar
- Label: Empty zone
- Caption: Click a New Zone Bar to add a zone
- Caption: Click × on an empty zone to remove it
- Caption: Or drag an app from the Dock onto a bar: it opens in a new zone

An empty zone shows a placeholder that holds the space for a window. Click a New Zone Bar at the side of the display to add a zone, and × on an empty zone to remove it.

> Try it: Click a New Zone Bar, then × on the new zone. A full display shows no bar.

### 4. The destination zone

Scene captions (`destination`):
- Label: Reply
- Caption: Any new window, like an email reply, opens in the destination zone
- Caption: The destination then moves to another empty zone
- Caption: When every zone is full, new windows open in the floating zone

The next window opens in the destination zone, marked by a glow, whatever app it comes from. Click an empty zone to make it the destination.

Once that zone is filled, the destination moves to another empty zone. When every zone is full, new windows float above the tiles.

> Try it: Minimize a window with {minimize}, then open a new window in any app, such as an email reply.

### 5. Finding windows

Scene captions (`finding`):
- Caption: CmdTab switches between windows, most recent first
- Caption: Or hover over a Dock icon and pick one of its windows

Minimized windows are out of sight but one step away.

- **Launcher ({launcher}):** type to find any app or window. Tab lists an app's windows.
- **CmdTab ({cmdtab}):** switches between windows, not apps, most recent first.
- **Dock:** click an icon for the app's main or most recently used window, or hover to choose among its windows. Hold Shift for the normal Dock, for example to rearrange icons.

> Try it: Hover over a running app's Dock icon.

### 6. Moving and resizing

Scene captions (`moving`):
- Caption: Drag a window onto another zone: the two windows swap
- Caption: Drag the bar between zones to resize them
- Caption: A window too big for its zone slides into view while you use it

Drag a window onto another zone to move it there. A window already there swaps places.

To resize zones, hover between two zones and drag the bar that appears. (Note: Dragging a window's own edge is temporary: the window returns to its zone when you switch windows.)

With ActiveFit, a window too big for its zone slides fully into view while you use it.

> Try it: Drag a window onto another zone.

### 7. Finish setting up

These settings in System Settings > Desktop & Dock make Zonogy work better.

- **Minimize windows using:** Scale Effect. Zonogy minimizes often, and Scale is quicker.
- **Minimize windows into application icon:** on, so minimized windows do not fill the Dock.
- **Drag windows to left or right edge of screen to tile:** off. It interferes with dropping windows on a New Zone Bar.
- **Displays have separate Spaces:** on (the macOS default).
- **Stage Manager:** off. Zonogy takes its place.

[Button: Open Desktop & Dock Settings…]

More suggestions, such as remapping Caps Lock, are in the README.

[Button: Open Additional Suggestions…]

### 8. More to discover

- **{gesture keys}-click a zone** to make it the destination, even if occupied.
- **Drag a Dock icon, file, or link** onto an empty zone or a New Zone Bar to open it there.

More chapters are at the top of this window. Every shortcut is in Preferences > Shortcuts, and this tour is under Help in the Zonogy menu.

---

## Chapter: Keyboard

### 1. Adding and removing zones

Scene captions (`keyboard-zones`):
- Keycap: add zone
- Keycap: minimize
- Caption: Add a zone: it opens empty, with the Launcher in it
- Caption: Minimize a window: its zone stays, with the Launcher open
- Caption: Minimize again to remove the zone

Press {add zone} to add a zone. It opens empty, with the Launcher in it.

Press {minimize} to minimize the focused window, as usual. Its zone stays, with the Launcher open; press {minimize} again to remove the zone. The same goes for ⌘W, which closes the window.

> Try it: Press {add zone}, pick a window in the Launcher, then press {minimize} twice.

### 2. One zone

Scene captions (`keyboard-one-zone`):
- Keycap: one zone
- Caption: Keep only the focused window's zone
- Caption: It fills the display, and the other windows are minimized

Press {one zone} to keep only the focused window's zone. The window fills the display, and the other windows are minimized.

> Try it: Click a window, then press {one zone}.

### 3. Clearing the display

Scene captions (`keyboard-clear`):
- Keycap: clear
- Caption: Clear the display: every window is minimized, and the zones stay
- Caption: Clear it again to go back to one zone

Press {clear} to clear the display: every window on it is minimized, and its zones stay. Press it again to go back to one zone.

> Try it: Press {clear} twice, then pick a window in the Launcher.

### 4. Stepping between zones

Scene captions (`keyboard-stepping`):
- Keycap: hold
- Caption: Hold the modifier keys and press arrows: a circle steps between zones
- Caption: Release on an empty zone to make it the destination, with the Launcher
- Caption: Release on a window's zone to focus that window

Hold {navigation keys} and press an arrow key. A circle marks a zone, and each arrow steps it to the next zone in that direction.

Release {navigation keys} to focus this zone's window, or to make this zone the destination if it is empty.

> Try it: Hold {navigation keys}, press an arrow or two, then release.

### 5. Acting on this zone

Scene captions (`keyboard-acting`):
- Keycap: hold
- Keycap: move
- Keycap: add
- Caption: With the circle on a zone, the move key brings your window into it
- Caption: The add key adds a zone there, ready to fill

While still holding {navigation keys}, these keys act on the circle's zone (esc cancels):

- **{move key}** moves the focused window into this zone, swapping if it is occupied.
- **{launcher key}** makes this zone the destination and opens the Launcher.
- **{add key}, {remove key}, {minimize key}** add a zone, remove this zone, and minimize its window.

> Try it: Hold {navigation keys}, step to another zone, and press {move key}.

### 6. Jump keys

Jump keys take the circle straight to a zone or a display, with no stepping.

[Pictograms: the current jump keys, drawn on a display's zones and on the displays]
- Pictogram caption: Jump to that zone, adding it if it isn't there yet. The key on the bar is the floating zone.
- Pictogram caption: Jump to that display.

Change these keys, or the keys to hold, in Preferences > Shortcuts > Zone Navigation.

> Try it: Hold {navigation keys} and press {jump top-right}, then release.

---

## Chapter: WinShot Snapshots

### 1. WinShot snapshots

Scene captions (`winshot-switching`):
- Caption: The chooser shows saved arrangements, most recent first
- Caption: Restoring one brings back its zones and its windows
- Caption: A window can be part of several arrangements

A snapshot records which windows are in which zones on a display. Switching to it brings the whole arrangement back: the zones, and the windows in them.

Unlike a Space, a snapshot does not own its windows. The same window can be part of several snapshots, one for each task that uses it.

[Checkbox: Enable WinShot]

### 2. Saving snapshots

Save the arrangement on the active display with {save snapshot}, or with Save Snapshot in the Zonogy menu.

Zonogy can also save for you. Preferences > Snapshots offers two automatic modes:

- **Before Clear/Reset Zones or restoring a snapshot:** saves the arrangement you are about to lose.
- **After every change:** saves each arrangement once it has lasted a few seconds.

Saving an arrangement that already has a snapshot replaces it. A snapshot goes when one of its windows closes, and the oldest go once a display has more than the limit set in Preferences.

[Banners: Screen Recording]

Thumbnails need Screen Recording. Without it, a thumbnail shows gray blocks in place of the windows.

> Try it: With WinShot on, press {save snapshot} to save this arrangement.

### 3. Switching snapshots

Scene captions (`winshot-display`):
- Caption: Drag a snapshot to another display to open its arrangement there

Hold {chooser hold} and tap {chooser tap} to open the chooser on the active display, and tap again to step through its snapshots, most recent first. Add Shift to step back. Release to restore the selected snapshot; Escape cancels.

- **Timeline:** the wider the gap between two thumbnails, the more time passed between them.
- **Click a thumbnail** to restore it at once, or its × to delete it.
- **Drag a thumbnail to another display** to open the arrangement there, fitted to that display.
- **Clear All Snapshots** is in the Zonogy menu.

> Try it: Save two arrangements, then hold {chooser hold}, tap {chooser tap} twice, and release.

---

## Other text

### The tour window

- Window title: Zonogy Tour
- Toolbar: one icon per chapter, labeled with the chapter's name
- Buttons: Back, Continue (Done on a chapter's last page)
- Page position: 3 of 8

### Where the tour is opened from

- Help menu: Zonogy Tour... (reopens the tour at the page last shown)
- Preferences > Snapshots, button: WinShot Tour… (opens the WinShot Snapshots chapter)

### Permission banners (shared with Preferences > General)

- Accessibility, granted: Accessibility permission granted
- Accessibility, missing: Accessibility permission required
- Screen Recording, granted: Screen Recording permission granted (for WinShot Snapshots)
- Screen Recording, missing: Screen Recording permission not granted (for WinShot Snapshots)
- Button on each: Open Settings…

### Scene descriptions (read by VoiceOver, never shown)

- `welcome` (shared with the README): Zonogy on two displays. Each display keeps its own tiling zones. Minimizing a window, on either display, leaves its zone empty with the Launcher open there to pick a window for it. Dragging a specific window from the menu over its Dock icon onto any zone, on either display, replaces the window there.
- `zones`: Zones in Zonogy. A bar on each side edge of the display adds a tiling zone there. A new zone is empty: it shows a placeholder, with the Launcher open in it to pick a window for it. Clicking the placeholder's close button removes the zone. Dragging an app from the Dock onto a bar opens its window in a new zone on that side.
- `destination`: The destination zone in Zonogy. One empty zone is the destination, marked by a glow: replying to an email in Mail opens the reply there. The destination then moves to another empty zone, where the next reply opens. When every zone is full, a new window floats above the tiles.
- `finding`: Finding windows in Zonogy. CmdTab lists windows, most recent first, and the one chosen fills the empty destination zone. Hovering over a Dock icon lists that app's windows, and the one clicked fills the zone.
- `moving`: Moving and resizing in Zonogy. Dragging a window onto another zone moves it there, and the window in that zone takes its place. Dragging the bar between two zones resizes them, and their windows follow. A window that can't shrink to its zone runs off the display's edge, and slides fully into view while it is in use.
- `keyboard-zones`: Adding and removing zones with the keyboard in Zonogy. A shortcut adds a zone, which opens empty, with the Launcher in it. Minimizing a window leaves its zone in place, empty, with the Launcher open; minimizing again removes the zone.
- `keyboard-one-zone`: Keeping one zone with the keyboard in Zonogy. A shortcut keeps only the focused window's zone: the window fills the display, and the other windows are minimized.
- `keyboard-clear`: Clearing a display with the keyboard in Zonogy. A shortcut minimizes every window on the display, and its zones stay, empty, with the Launcher open in one. Pressed again, it resets the display to one zone.
- `keyboard-stepping`: Stepping between zones with the keyboard in Zonogy. While the modifier keys are held, each arrow key moves a circle to the next zone in that direction. Releasing over an empty zone makes it the destination and opens the Launcher there. Releasing over a window's zone focuses that window.
- `keyboard-acting`: Acting on a zone with the keyboard in Zonogy. While the modifier keys are held and the circle is on a zone, one key moves the focused window into that zone, swapping with the window there, and another adds a zone under it, where the Launcher opens.
- `winshot-switching`: WinShot snapshots in Zonogy. The chooser shows a timeline of saved window arrangements, most recent first. Restoring one brings back its zones and its windows. The same window can be part of several arrangements.
- `winshot-display`: Opening a WinShot snapshot on another display. Dragging a snapshot's thumbnail from the chooser onto another display opens that arrangement there, fitted to that display.
