# DockMenus

DockMenus adds Dock integration to Zonogy, providing an ultra-fast “peek and switch” for an app’s windows directly from the Dock.

- **Hover:** When the mouse moves over an application icon in the macOS Dock, show a DockMenu: a miniature Launcher UI (ie similar to our Launcher feature) pre-filtered (“drilled down”) to that application. Unlike the full Launcher, there is no keyboard navigation, no search field, and no possibility of “drill out” navigation.
- **Click interception:** Clicking an application icon in the Dock (without Shift) does not activate the real Dock item; instead Zonogy performs the same default action as selecting that application in the Launcher (see [SPECIFICATION-LAUNCHER.md](SPECIFICATION-LAUNCHER.md)). In particular, it obeys `hasMainWindow` selection rules.
- **Bypass:** **Shift-click** on a Dock application behaves exactly like a normal Dock click (Zonogy does not intercept).
- For apps that are not running, we don't show the DockMenus, nor do we do click interceptions.

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

**Modifiers:**

- **Shift-click:** Do not intercept; allow the Dock to behave normally.
- Do not intercept right-click / control-click (Dock context menus must keep working).

### Clicking Inside DockMenu

Clicking items inside DockMenu performs the same action as clicking the corresponding item in the Launcher:

- **Click window row:** Select/focus that window using normal Zonogy placement rules for the currently targeted zone (including minimized-window pre-positioning behavior).
- **Click app header entry:** Activate the app without targeting a specific window (matching Launcher semantics).

## Dismissal / Lifetime

DockMenu dismisses when:

- The cursor leaves the Dock and the DockMenu (after a short grace period so the user can move into the menu).
- The user activates an item (Dock click interception or clicking a DockMenu entry).
- The Dock app under the cursor cannot be identified anymore (space switch, Dock hides, etc.).

## Settings

- DockMenus is a distinct feature flag in settings/config.
- Default should be conservative (off by default) until the behavior feels solid, since it changes a core system interaction (Dock clicks).

## Implementation Notes (Non-normative)

- The reliable way to identify the hovered Dock app is expected to use Accessibility APIs against the Dock process (`com.apple.dock`) and/or element-at-position queries, extracting the represented app’s bundle identifier.
- Click interception is expected to be implemented via a global event tap. Intercept only the minimal set of events needed, and only while the cursor is over a Dock app. It is imperative that the code be as efficient as possible!
