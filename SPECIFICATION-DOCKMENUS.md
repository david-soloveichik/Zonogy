# DockMenus

DockMenus adds Dock integration to Zonogy, providing an ultra-fast “peek and switch” for an app’s windows directly from the Dock.

- **Hover:** When the mouse moves over an application icon in the macOS Dock, show a DockMenu: a miniature Launcher UI (ie similar to our Launcher feature) pre-filtered (“drilled down”) to that application. Unlike the full Launcher, there is no keyboard navigation, no search field, and no possibility of “drill out” navigation.
- **Click interception:** Clicking an application icon in the Dock (without Shift) does not activate the real Dock item; instead Zonogy performs the same default action as selecting that application in the Launcher (see [SPECIFICATION-LAUNCHER.md](SPECIFICATION-LAUNCHER.md)). In particular, it obeys `hasMainWindow` selection rules. For non-running apps or running apps with no managed windows, Zonogy simulates a press on the Dock item (via Accessibility API) to trigger the app's native "clicked in Dock" behavior.
  - When the `DockMenus targets zone with active window` Targeting preference is enabled (default off), DockMenus first retargets to the zone containing the currently active managed window for placement-oriented actions. If the Launcher is visible, DockMenus leaves targeting unchanged because Launcher is always shown on the current target.
  - **Exception compared to Launcher**: While the Launcher allows "moving" a currently open window from one zone to another, DockMenus has different behavior when a currently open (in a zone) window is chosen: it simply activates it in its current zone.
- **Dock-icon drag interception:** Dragging an app icon in the Dock (without Shift/Control) initiates a zone-targeting drag. For running apps with managed windows, this drags the app's preferred managed window. For non-running apps or running apps with no managed windows, dropping on a zone targets that zone and launches/activates the app (window appears in the newly targeted zone).
- **Option-drag (new window):** Holding Option during a Dock-icon drag or a drag of a window entry from a DockMenu hover panel shows a "+" affordance on the drag preview (and replaces the window title with the app name). Pressing or releasing Option updates the preview live. Releasing the mouse with Option held targets the zone under the cursor and opens a new window of the app (for running apps Zonogy activates the app and simulates a Cmd-N keystroke; for non-running apps Zonogy launches the app, which typically produces a new window).
- **Bypass:** **Shift-click** or **Shift-drag** on a Dock application behaves exactly like a normal Dock action (Zonogy does not intercept).
- **DockMenus (hover panels):** Only shown for running apps.

## Hover → DockMenu

**Performance requirements:**

- Do not do heavy Accessibility queries on every mouse-move event.
- Throttle/merge updates so that fast cursor scrubbing across the Dock does not cause flicker or sustained CPU usage.

### DockMenu Presentation

- DockMenu is a small floating panel positioned adjacent to the hovered Dock icon:
  - Dock on bottom: menu appears above the icon.
  - Dock on left/right: menu appears to the inside of the screen (away from the edge).
- DockMenu should visually match the Launcher style (vibrancy/blur, rounded corners) but be more compact.
- DockMenu should not take key focus merely by appearing.

### DockMenu Contents (Mini Launcher “Drilled Down”)

- App header entry (icon + app name), with the same semantics as the Launcher’s app header entry.
- A list of that app’s **managed windows** (as tracked by Zonogy), with the same row styling and title cleanup as the Launcher.

## Actions

### Clicking the Dock App (Interception)

When the user left-clicks a Dock app **without Shift**:

- Zonogy intercepts the click so the Dock does not handle it.
- Zonogy performs the **Default Launcher action for that app** (see [SPECIFICATION-LAUNCHER.md](SPECIFICATION-LAUNCHER.md)), including `hasMainWindow` behavior.
- After the action begins, dismiss the DockMenu.
- Intercept only when the Dock app icon is the **topmost** UI at the cursor. If another menu/panel/window overlaps the Dock at that point, let that frontmost UI handle the click normally. (Using `AXUIElementCopyElementAtPosition()`)

**Modifiers:**

- **Shift-click:** Do not intercept; allow the Dock to behave normally.
- Do not intercept right-click / control-click (Dock context menus must keep working).

### Dragging the Dock App (Interception)

When the user drags a Dock app icon **without Shift/Control**:

- Zonogy intercepts the drag so the Dock does not start rearranging icons or show the native Dock menu.
- **Running apps with windows:** Zonogy resolves the app's preferred managed window using the same selection rules as click interception (including `hasMainWindow`). The resolved window is dragged using the same overlay UI and drop targets as dragging a DockMenu window entry.
- **Non-running apps or running apps with no windows:** Zone overlays appear. Dropping on a zone targets that zone and launches/activates the app; the new window appears in the targeted zone. Dropping outside all zones cancels (app is not launched/activated).
- As with click interception, only intercept when the Dock app icon is the **topmost** UI at the cursor; overlapping menus/panels/windows must win.

**Modifiers:**

- **Shift-drag / control-drag:** Do not intercept; allow normal Dock behavior (rearranging icons / context menus).
- **Option-drag:** Intercepted; see "Option-drag (new window)" above.

### Clicking Inside DockMenu

Clicking items inside DockMenu performs the same action as clicking the corresponding item in the Launcher:

- **Click window row:** Select/focus that window using normal Zonogy placement rules for the currently targeted zone (including minimized-window pre-positioning behavior).
- **Already-zoned window rows:** Keep DockMenus' activate-in-place behavior; they do not move into the active window's zone.
- **Click app header entry:** Activate the app without targeting a specific window (matching Launcher semantics).

### Dragging Window Entries from DockMenu

Window entries in the DockMenu can be dragged directly to zones. This uses the same overlay UI and drop targets as dragging actual windows (see **Dragging Windows Between Zones** in [SPECIFICATION.md](SPECIFICATION.md)).

- **Drag initiation:** When the user drags a window entry (minimum 8px drag distance), the DockMenu dismisses immediately.
- **Minimized windows:** If the dragged window is minimized, it is pre-positioned to the target zone frame before unminimizing for smooth animation.

## Dismissal / Lifetime

DockMenu dismisses when:

- The cursor leaves the Dock and the DockMenu (after a short grace period so the user can move into the menu).
- The user activates an item (Dock click interception or clicking a DockMenu entry).

## Settings

- DockMenus is a distinct feature flag in settings/config.
- `DockMenus targets zone with active window` toggle in Preferences → Targeting (default off).
- Default should be conservative (off by default) until the behavior feels solid, since it changes a core system interaction (Dock clicks).

## Implementation Notes

### Hover Detection

- Observe `AXSelectedChildrenChanged` on the Dock's `AXList` to detect hover events.
  - Fires when mouse begins hovering a Dock item or changes to a different item.
  - **Does not reliably fire when cursor leaves the Dock.** See "Accessibility API Workarounds" below.
- Extract app URL from the `AXApplicationDockItem`'s `kAXURLAttribute`.
- Check if app is running before showing DockMenu.
- Determine Dock orientation via `kAXOrientationAttribute` on the AXList.

### Debouncing

- **Show delay:** 120ms after hover starts on a running app.
- **Hide grace period:** 200ms after cursor leaves Dock/panel area.
- Grace period allows cursor to move from Dock icon into the DockMenu panel.
- Cancel pending show if cursor moves to different app before delay completes.

### Panel Positioning

- Convert accessibility coordinates (y:0 at top) to Cocoa coordinates (y:0 at bottom).
- Panel positioned with 8pt gap from Dock icon.
- **Horizontal Dock (bottom):** Panel centered horizontally on the Dock icon.
- **Vertical Dock (left/right):** Panel vertically aligned so that moving the mouse horizontally from the Dock icon (without vertical movement) places the cursor over the first window in the window list. If the app has no windows, aligns to the app header instead.
- Clamp to screen visible bounds.

### Dock Visibility Tracking

- Track Dock visibility as a boolean alongside the Dock frame.
- The frame represents the last Dock AXList frame that is fully within the primary screen bounds; during autohide animation (off/partially off-screen), keep using the cached in-bounds frame.
- **Visible**: Set when `AXSelectedChildrenChanged` notification fires.
- **Hidden**: Set when click handler clicks in the Dock frame but finds no Dock element.
- Click interception fast-exits when Dock is considered hidden.
- Debug overlay only shows when Dock is considered visible.

### Click Interception

- Global event tap intercepts left-mouse-down events within Dock AXList frame.
- Validates click is on an app (AXApplicationDockItem subrole); intercepts both running and non-running apps.
- Respects Shift modifier (bypass) and Control (context menu).

### Dock Icon Drag Interception

- Use the same CGEventTap as click interception and swallow `leftMouseDown` on eligible app items so the Dock can’t start its own press-and-hold menu or icon drag.
- Cursor-driven drags must not rely on `NSEvent.mouseLocation` (mouse events are swallowed); instead forward `CGEvent.location` (accessibility coordinates) through the drag pipeline for hit-testing and drag-preview positioning.
- Ensure the drag-preview window is frontmost even while other apps are active (e.g., `orderFrontRegardless`).

### Window Selection Semantics

DockMenu differs from Launcher in how window selection works:

- **In-zone windows:** Activated in place without moving to targeted zone.
- **Minimized windows:** Unminimized into the currently targeted zone.

## Accessibility API Workarounds

### AXSelectedChildrenChanged Does Not Signal Cursor Exit

The Dock's `AXSelectedChildrenChanged` notification fires when:

- Cursor begins hovering a Dock item (selectedChildren contains that item)
- Cursor moves to a different Dock item (selectedChildren changes to new item)

However, **when the cursor leaves the Dock entirely**, `AXSelectedChildrenChanged` may fire with the **same selectedChildren as before** (the last hovered item), not an empty selection. Additionally, `AXSelectedChildrenChanged` with empty selection can fire at unpredictable times unrelated to user interaction.

**Consequence:** We cannot rely on AX notifications to detect when the cursor leaves the Dock. DockMenu dismissal must be driven by cursor-in-region checks (Dock ∪ panel), not by AX hover-end.

### Cursor Region Polling

Because the Dock may prevent Zonogy from receiving reliable mouse enter/exit events, dismissal uses a lightweight polling timer while the panel is visible:

- Polls cursor position at ~50ms intervals (using common run loop modes)
- Treats the DockMenu as "safe" while the cursor is in the DockMenu panel, or in the Dock frame while hovering a running app item
- When the cursor remains outside the safe region for 200ms, hides the panel
- Prevents late-show flicker by skipping a debounced show if the cursor is no longer in the Dock when the show fires
