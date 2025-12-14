# Zonogy Launcher

This specification describes the Launcher feature for Zonogy - a window switcher and application launcher that integrates with Zonogy's zone-based window management.

## Overview

The Launcher provides a quick way to switch between windows or launch applications, with the launched/selected window being placed into the targeted zone. It appears as a floating overlay, styled to match macOS aesthetics, and dismisses when an action is taken or the user cancels.

## Activation

### Keyboard Shortcut

- **Default shortcut:** Control-Space (configurable in settings alongside other Zonogy shortcuts)
- Pressing the shortcut toggles the launcher: if closed, opens it; if already open, closes it

### Placeholder Double-Click

Double-clicking a placeholder window shows the Launcher, targeting that zone.

### Positioning

The launcher window should appear:

1. **Centered on the targeted zone** - The launcher is positioned at the center of the currently targeted zone's frame. If the zone is too small, the launcher window should extend beyond the zone. The launcher window is user-moveable once it is shown.
2. If the targeted zone is the temporary zone (which has no visible placeholder), center on the screen containing the temporary zone
3. The launcher window should be a floating panel that stays above all other windows

## User Interface

### Visual Design

The launcher window should have an elegant, professional appearance matching macOS design language:

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

All applications known to the OS are included:

- **Discovery modes:** Directory scanning of standard application locations (default) or Spotlight database (configurable)
- **Display name:** Uses `FileManager.displayName(atPath:)` which returns the same name shown in Finder/Dock. We strip any ".app" at the end.

### Windows

When an application with multiple windows is selected, the user can drill down to see individual windows:

- Uses Zonogy's tracked windows as the source of truth (rather than direct Accessibility API enumeration)
- Only shows windows that Zonogy has captured (i.e., zone-manageable standard windows)
- Displays window title from accessibility API (titles change frequently so cannot be cached)
- **Title cleanup:** Strips redundant app name suffixes (e.g., " - Safari", " — Xcode") since the app is already shown in the header
- Shows a window icon glyph for unminimized windows; minimized windows have no icon
- **Ordering:** Windows are listed by recency (most recently active first). Zonogy tracks when each managed window becomes active, and this order is used for the window list. Windows without recency data are ordered by their Zonogy ID (discovery order), which typically places the main window first.

### Files and Directories (Optional Extension)

Users can extend the searchable list via configuration:

- Configuration file: `~/Library/Application Support/Zonogy/launcher-config.json`
- Each entry specifies a path and optional alias text
- Search matches against both filename and alias

## Search and Filtering

### Fuzzy Matching

Search uses subsequence matching (like LaunchBar):

- Characters typed must appear in the item name in order, but not necessarily consecutively
- Example: typing "ff" matches "Firefox" (F-ire-F-ox)
- Matching is case-insensitive

### Ranking

Ranking combines **match quality** (how well the query matches the item name) with **frecency** (frequency + recency of use). This allows the launcher to learn user preferences like LaunchBar - after selecting Mail a few times for "m", it will rank above Chrome even if Chrome is used more often globally.

#### Match Quality Scoring

Match quality (0.0 to 1.0) is based on position and density of matched characters:

- **Word boundary bonus:** Matches at start of string or after whitespace score highest (+10)
- **Delimiter bonus:** Matches after `-`, `_`, `.`, `/` score well (+8)
- **CamelCase bonus:** Matches at uppercase letters following lowercase (+7)
- **Consecutive bonus:** Each consecutive matched character adds bonus (+4)
- **Gap penalties:** Gaps between matches reduce score (-3 to start, -1 per char)
- **First character multiplier:** Bonuses on first query character are doubled (2x)

Example: Query "m" scores ~0.85 for "Mail" (word start) but ~0.35 for "Chrome" (mid-word).

#### Frecency Scoring

Base frecency formula:

```text
frecency = log(1 + count) + exp(-ageSeconds / tauSeconds)
```

Where `tauSeconds` ≈ 10 days.

**Global vs Per-Query Frecency:**

- **Global:** How often/recently an item has been launched overall
- **Per-query:** How often/recently an item has been launched for the current query (and prefixes)

**Query Dominance Mode:** When per-query frecency exceeds a threshold (~0.5), it dominates completely:

```text
if queryFrecency > 0.5:
    frecencyScore = 8.0 * queryFrecency  // Query history dominates
else:
    frecencyScore = globalFrecency + 5.0 * queryFrecency
```

This means after selecting an item 2-3 times for a specific query, that preference overrides global usage patterns.

#### Combined Formula

```text
finalScore = matchQuality * (1.0 + 2.0 * frecencyScore)
```

Match quality acts as a multiplier - poor matches cannot be rescued by high frecency. Items are ordered by descending `finalScore`, with case-insensitive alphabetical tie-breaker.

When query is empty, all items have matchQuality = 1.0 and ranking uses pure frecency.

### History Persistence

Launch history is persisted to `~/Library/Application Support/Zonogy/launcher-history.json`.

Per-query memory is recorded when:

- User launches with non-empty query
- Launched item is not the current top-ranked result
- Recorded for full normalized query and its prefixes (up to 32 characters)

## Navigation and Interaction

### Keyboard Navigation

- **Up/Down arrows:** Select item from the filtered list
- **Enter:** Activate selected item (launch app, focus window, open file)
- **Tab:** When a running app is selected, drill into window list
- **Shift-Tab or Escape (in window list):** Return to main app list
- **Escape (in main list):** Dismiss launcher without action

### Window List Mode

When drilling into an application's windows:

1. The list is replaced with that application's windows
2. Search field is cleared
3. First actual window is selected (not the app header)
4. Same fuzzy matching applies to window titles

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
   - If minimized: resize/position to target zone frame BEFORE unminimizing (so the unminimize animation shows the window restoring to the correct position), then place into the targeted zone
   - If not minimized: move window to the targeted zone (if not already there)
   - The targeted zone receives the window using standard Zonogy placement rules

2. **If launching/selecting a running app with exactly 1 window:**
   - Treat as window selection (applies pre-positioning and zone placement as above)

3. **If launching a new application:**
   - The new window will be placed into the targeted zone via normal Zonogy window capture

4. **If activating an app header (not a specific window):**
   - Use `app.activate(options: [.activateIgnoringOtherApps])` without changing window placement

### Dismissal

The launcher dismisses when:

- User presses Escape
- User activates an item (Enter on selection)
- User clicks outside the launcher window
- User presses the activation shortcut again (toggle behavior)

## Configuration

### Settings Integration

Launcher settings should integrate with Zonogy's existing configuration system:

- **Activation shortcut:** Control-Space (default), configurable
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

## Accessibility

### Permissions

Window enumeration requires accessibility permissions. If not granted:

- The ">" indicator should not appear on any app entries
- Attempting to drill into windows prompts user to grant accessibility in System Preferences

Since Zonogy already requires accessibility permissions for window management, the launcher should leverage those existing permissions.

## Implementation Notes

### Code Reuse

The implementation can be adapted from Test-Launchbar:

- **SubsequenceMatcher:** Fuzzy matching algorithm
- **LaunchItem/WindowItem models:** Data structures for items
- **LauncherModel:** Core logic for filtering and ranking
- **LaunchItemUsageStore:** Frecency tracking and persistence
- **UI components:** LauncherView, LaunchItemListView, WindowItemListView, etc.

Note: Unlike Test-Launchbar, Zonogy's launcher uses `WindowController.allWindows` as the source of truth for window enumeration rather than a separate WindowEnumerationService. This ensures consistency with Zonogy's window management and uses cached state (e.g., `isMinimized`) where available.

### Window Configuration

The launcher window should be configured as:

- `styleMask: [.borderless]`
- `level: .floating`
- `backgroundColor: .clear`
- Non-activating where possible to avoid interfering with window focus until selection

### Performance

- **Application caching:** The app list is pre-loaded at Zonogy startup and cached in memory. Launcher opens display the cached list instantly.
- **Lazy icon loading:** Icons are loaded on-demand as rows appear, avoiding upfront I/O overhead.
- **Manual refresh:** The menu bar provides "Reload Launcher List" to rescan application directories and reload `launcher-config.json` (for alias changes).
- Search filtering should be responsive (< 16ms for 60fps feel)
- Window enumeration on tab-into-app should be fast (uses Zonogy's tracked windows)
