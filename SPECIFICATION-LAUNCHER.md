# Zonogy Launcher

This specification describes the Launcher feature for Zonogy - a window switcher and application launcher that integrates with Zonogy's zone-based window management.

## Overview

The Launcher provides a quick way to switch between windows or launch applications, with the launched/selected window being placed into the targeted zone. The Launcher appears as a floating overlay over the currently targeted zone.

## Activation

The Launcher opens via:

- **Control-Command-Space** (opens the Launcher; does not close it if already open), configurable in settings alongside other Zonogy shortcuts
- Clicking the **search pill** on any placeholder window (targets that zone and opens the Launcher, even if already targeted)
- **Automatically** when:
  - A tiling zone becomes empty (window closed, minimized, or moved away).
    Note: By targeting rules in the main spec, this implies that the zone becomes targeted.
    Big picture: Besides allowing the user to quickly choose another window, this behavior also allows the user to press Cmd-M twice to minimize the window and remove its tiling zone.
    (See "Accessibility API Workarounds" section below.)
  - After a zone is added.
  - Exception: Auto-show is suppressed when an unmanaged window has focus on the targeted zone's screen.
- **Zone removal behavior:** When Launcher is open and the zone is removed: If another empty, tiling zone becomes targeted, then keep the Launcher open. Otherwise, dismiss the Launcher.
- **Targeting invariant:** If the Launcher is visible, it is always anchored to the *current* targeted destination. On target changes it re-centers to the new target when it is an empty tiling zone or the temporary target; otherwise it dismisses. (Exception: zone removal applies its own rule above, which takes precedence.)

## Dismissal

The launcher dismisses when user:

- Presses Escape
- Activates an item (Enter on selection or double-click)

Further, we don't want to steal focus from the user's intended key/active window (recall Launcher is floating frontmost and grabs keyboard input).
So the launcher automatically dismisses when:

- User clicks outside the launcher window
- The targeted destination changes to an occupied tiling zone (to avoid showing the Launcher for non-empty zones)
- Focus shifts to a managed window in a tiling or temporary zone (so the user can interact with it)
- An unmanaged window gains focus on the Launcher's screen (to avoid overlapping it)
- A window is placed into a zone (so the user can interact with it)
- A zone is removed (see "Zone removal behavior")

## Positioning

The launcher window should appear:

1. **Centered on the currently targeted zone** - The launcher is positioned at the center of the currently targeted zone's frame. If the zone is too small, the launcher window should extend beyond the zone. The launcher window is user-moveable once it is shown, but it re-centers when the **targeted zone changes** or **the targeted zone's frame changes** (e.g., zone add/remove/resize).
2. If the targeted zone is the temporary zone (which has no visible placeholder), center on the screen containing the temporary zone

## User Interface

### Visual Design

The launcher window should be a floating panel that stays above all other windows. It should have an elegant, professional appearance matching macOS design language:

- **Background:** Vibrancy/blur effect (NSVisualEffectView) for a modern translucent look
- **Shape:** Rounded rectangle with appropriate corner radius
- **Size:** Approximately 500-600px wide, height adjusts based on content (max ~400px with scrolling)
- **No title bar** - borderless window style

### Layout

1. **Search field** at the top - focused immediately when launcher opens
2. **Results list** below showing filtered items
3. Each item row displays:
   - Icon (application icon, window glyph, or file icon)
   - Display name
   - Running indicator (small dot) for running applications
   - Expandable indicator (">") for running applications

### Empty State

When no items match the search query, display a friendly empty state message rather than a blank list.

## Item Types and Sources

### Applications

All applications known to the OS are included, except those listed in `ignoredBundleIdentifiers` (see main spec's Configuration section):

- **Discovery modes:** Directory scanning of standard application locations (default) or Spotlight database (configurable)
- **Explicit apps:** Apps in non-standard locations (e.g., Finder.app in `/System/Library/CoreServices/`) are included via an explicit list in the code
- **Display name:** Uses `FileManager.displayName(atPath:)` which returns the same name shown in Finder/Dock. We strip any ".app" at the end.

### Windows

When a running application is selected, the user can drill down to that application's window list (even when Zonogy currently tracks zero managed windows):

- Uses Zonogy's tracked windows as the source of truth (rather than direct Accessibility API enumeration)
- Only shows windows that Zonogy has captured (i.e., zone-manageable standard windows)
- Displays window title from accessibility API (titles change frequently so cannot be cached)
- **Title cleanup:** Strips redundant app name suffixes (e.g., " - Safari", " — Xcode") since the app is already shown in the header
- Shows a window icon glyph for windows placed in a zone; windows not in any zone have no icon

**Window Ordering:**

Windows not placed in any zone are shown first, then windows in zones. The rationale is that zoned windows are already visible and tiled, so users are more likely to want to select a window that is not currently in a zone.

Within each group, windows are ordered by recency (most recently active first). Zonogy tracks when each managed window becomes active. Windows without recency data fall back to Zonogy ID order (discovery order), which typically places the main window first.

### Files and Directories

Users can extend the searchable list via configuration:

- Configuration file: `~/Library/Application Support/Zonogy/launcher-config.json`
- Each entry specifies a path and optional alias text
- Search matches against both filename and alias

## Search and Filtering

### Fuzzy Matching

Search uses subsequence matching: characters typed must appear in the item name in order, but not necessarily consecutively. Example: "ff" matches "Firefox". Matching is case-insensitive.

### Ranking

For non-empty queries, items are sorted by:

1. **Per-query count** (descending): How many times this item was selected for this exact query in the last 5 selections. If count ≥ 3 (majority), the item is guaranteed to rank first regardless of other factors.
2. **Combined score** (descending): Weighted blend of match quality (70%) and recency (30%):
   - **Match quality** (0.0–1.0): Scored based on how well the query matches the item name or alias:
     - **Exact alias match:** Query exactly matches an item's configured alias (case-insensitive) → 1.0
     - **Word boundary bonus:** Matches at start of string or after whitespace score highest
     - **Delimiter bonus:** Matches after `-`, `_`, `.`, `/` score well
     - **CamelCase bonus:** Matches at uppercase letters following lowercase
     - **Consecutive bonus:** Consecutive matched characters score higher than scattered matches
     - **Gap penalty:** Gaps between matched characters reduce score
   - **Recency score** (0.0–1.0): `1 / (1 + 0.03 × rank)` where rank is position in Zonogy's app recency list. Apps never used are treated as rank 50.
   - **Formula:** `0.7 × matchQuality + 0.3 × recencyScore`
3. **Alphabetical**: case-insensitive name (tiebreaker).

When query is empty, ranking uses recency then alphabetical.

### History Persistence

Persisted to `~/Library/Application Support/Zonogy/launcher-history.json`:

- **Per-query history:** Last 5 selections for each query (recorded on activation or drill-down)
- **Application recency:** Apps ordered by last activation (updated by Zonogy's window management)

## Navigation and Interaction

### Keyboard Navigation

- **Up/Down arrows:** Select item from the filtered list
- **Enter:** Activate selected item (launch app, focus window, open file)
- **Tab:** When a running app is selected, drill into window list
- **Right arrow:** When cursor is at end of search string, same as Tab (drill into window list)
- **Left arrow (in window list):** When cursor is at start of search string, same as Shift-Tab (return to app list)
- **Shift-Tab or Escape (in window list):** Return to main app list
- **Escape (in main list):** Dismiss launcher without action
- **Cmd-M:** Remove the targeted zone (if more than one tiling zone on the screen); simply hides Launcher if last tiling zone on screen

### Mouse Interaction

- **Hover:** Selects item (same visual as keyboard selection)
- **Click:** Activates item immediately (launch app, focus window)
- **Drill-down chevron:** Hover brightens icon; click shows press animation before drilling into window list

### Shortcut Forwarding

Certain keyboard shortcuts are forwarded to the menu bar owner app (the frontmost non-Zonogy application) so users can issue common commands while the Launcher is visible: Cmd-N (new window), Cmd-Shift-N (new private window), Cmd-O (open), Cmd-W (close window), and Cmd-Q (quit).

### Window List Mode

When drilling into an application's windows:

1. The list is replaced with that application's managed windows (which may be empty)
2. Search field is cleared
3. If at least one window exists, the first actual window is selected (not the app header); otherwise the app header (Menu Bar entry) is selected
4. Same fuzzy matching applies to window titles; when searching, windows are ranked by match quality with recency order as the tie-breaker

**App Header Entry:**

- First entry in window list shows app icon and name
- Distinct visual styling from window entries
- Activating it focuses the app without targeting a specific window
- Always visible regardless of search filter

### After Selection

After selecting any item via Enter:

- Search text is cleared
- If in window mode, returns to main app list
- Launcher window closes

## Integration with Zonogy Window Management

### Window Placement

When the user selects a window or launches an application:

1. **If selecting an existing window:**
   - If minimized: resize/position to target zone frame before unminimizing for smooth animation (see "Accessibility API Workarounds" in SPECIFICATION.md). Then place into the targeted zone.
   - If not minimized: move window to the targeted zone (if not already there)
   - The targeted zone receives the window using standard Zonogy placement rules

2. **If selecting a running app with 1+ managed windows:**
   - Selects the preferred window and treats as window selection (zone placement as above)
   - **Main window apps** (`hasMainWindow: true` in config): selects window with lowest `CGWindowID`
   - **Other apps** (default): selects most recently active window
   - Pre-configured main window apps: Mail, Notes, Messages, Calendar, Reminders, Music, Photos

3. **If launching a new application:**
   - The new window will be placed into the targeted zone via normal Zonogy window capture

4. **If activating an app header (not a specific window):**
   - Use `app.activate(options: [.activateIgnoringOtherApps])` without changing window placement

**Note:** When Launcher moves a window out of its source zone, that zone becoming empty does not trigger the normal "target the emptied zone" or auto-show behaviors—the user's intended target is preserved.

## Configuration

### Settings Integration

Launcher settings should integrate with Zonogy's existing configuration system:

- **Activation shortcut:** Control-Command-Space (default), configurable
- **App discovery mode:** Directory scanning or Spotlight

### Configuration Files

- **History:** `~/Library/Application Support/Zonogy/launcher-history.json`
- **Custom items:** `~/Library/Application Support/Zonogy/launcher-config.json`

Custom items config schema:

```json
{
  "items": [
    {
      "path": "/path/to/file/or/directory",
      "alias": "optional alias text"
    },
    {
      "bundleIdentifier": "com.example.app",
      "alias": "optional alias for existing app"
    }
  ]
}
```

## Implementation Notes

### Accessibility API Workarounds

- **Auto-show grace period:** When a window is minimized or closed in a tiling zone, the Launcher auto-shows. However, macOS may automatically focus another window, which would normally trigger the Launcher to dismiss. To prevent this, the Launcher ignores focus-based dismissals for 0.5 seconds after auto-showing.

### Window Configuration

The launcher window should be configured as:

- `styleMask: [.borderless]`
- `level: .floating`
- `backgroundColor: .clear`
- Non-activating where possible to avoid interfering with window focus until selection

### Performance

- **Application caching:** The app list is pre-loaded at Zonogy startup and cached in memory. Launcher opens display the cached list instantly.
- **Lazy icon loading:** Icons are loaded on-demand as rows appear, avoiding upfront I/O overhead.
- **Manual refresh:** The menu bar provides "Reload Launcher Items" to rescan application directories and reload `launcher-config.json` (for alias changes).
- Search filtering should be responsive (< 16ms for 60fps feel)
- Window enumeration on tab-into-app should be fast (uses Zonogy's tracked windows)
