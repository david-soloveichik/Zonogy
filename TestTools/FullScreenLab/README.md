# Full Screen Lab

A disposable AppKit app for comparing Zonogy's native and non-native full-screen behavior. **Full Screen Lab 2** supplies a second independent host for testing both displays at once. A separate **Full Screen Guest** app supplies an ordinary window to open or restore. All three use the same executable.

Build and open from the repository root:

```sh
zsh TestTools/FullScreenLab/build.zsh
open '.build/TestApps/Full Screen Lab.app'
```

This builds only the fixtures. It does not package or launch Zonogy.

## Modes and controls

Choose a display, then use the buttons or Command-2 for native full screen and Command-3 for non-native full screen. Escape or Command-1 returns to a window. Command-N opens or restores the guest on the selected display. The guest has a Minimize button for repeating restore tests.

- Native mode uses `NSWindow.toggleFullScreen`, creating a macOS Space.
- Non-native mode uses a borderless `NSWindow` covering the selected display, at a normal window level. It uses the existing Space; other windows can cover it. The fixture does not fake `AXFullScreen` or Accessibility subroles.

For Zonogy to recognize non-native windows, add **Full Screen Lab** and **Full Screen Lab 2** in Preferences → Exceptions and enable **Treat AXUnknown full-width windows as full-screen**. Their bundle identifiers are `com.dsemeas.zonogy.fullscreenlab` and `com.dsemeas.zonogy.fullscreenlab.second`. This is the same opt-in rule used for presentation apps; leave the guest with ordinary rules.

## Repeatable checks

With two displays, repeat these in each mode:

1. Enter full screen on one display. Check that Zonogy hides its overlays there and targets the other display.
2. Open the guest on the full-screen display. Check that it moves to the other display and the presentation display remains paused.
3. Minimize and restore the guest; repeat the same observation.
4. Focus a window on the other display. Check that full-screen pause remains on the presentation display.
5. Exit full screen. Check that overlays, targeting, and any deferred windows recover.
6. Quit the host while full-screen. Check that the display is no longer paused.

Then run two hosts, one per display, in all four combinations: native/native, native/non-native, non-native/native, and non-native/non-native. Open or restore the guest on each display. Both displays should stay paused and the guest should remain unassigned. Exit full screen on the other display: the deferred guest should move there through normal placement. Repeat with the guest minimized or closed before exit; neither should be resurrected.

Deferral does not hide a window: the guest may cover a non-native presentation while every display is paused. Native displays return to their full-screen Spaces. Focus ending on either app is acceptable.

Commands for an automated driver (open each app once to register its URL scheme):

```sh
open 'zonogy-fullscreen-lab://non-native?screen=0'
open 'zonogy-fullscreen-lab://native?screen=0'
open 'zonogy-fullscreen-lab-2://non-native?screen=1'
open 'zonogy-fullscreen-lab-2://native?screen=1'
open 'zonogy-fullscreen-lab://guest?screen=0'
open -g 'zonogy-fullscreen-guest://minimize'
open 'zonogy-fullscreen-guest://show?screen=0'
open 'zonogy-fullscreen-lab://window'
open 'zonogy-fullscreen-lab-2://window'
open 'zonogy-fullscreen-guest://quit'
open 'zonogy-fullscreen-lab://quit'
open 'zonogy-fullscreen-lab-2://quit'
```

Display numbers are the current `NSScreen.screens` order, beginning at zero. Wait for observed mode/window changes between commands, especially native transitions. Use `-g` for minimize so Launch Services does not reactivate the window being minimized; inspect it without activating its app. Use ordinary `open` when testing activation, and verify the frontmost app and focused window. There is no timer in the fixture. Inspect Accessibility and Space membership independently when verifying the mode. Cold launches through a URL are supported.

The UI shows mode, display, window number, and size. Event logs use subsystem `com.dsemeas.zonogy.fullscreenlab`:

```sh
log show --last 5m --info --predicate 'subsystem == "com.dsemeas.zonogy.fullscreenlab" OR subsystem == "com.dsemeas.zonogy"'
```

## Verification — September 6, 2026

Checked with the updated debug Zonogy, the built-in display, and an AW2725Q. Both hosts had the non-native exception enabled. `swift build` and all `--self-test` guardrails passed.

Each row passed with the guest originating on display 0 and again on display 1. Checks covered cold launch, minimize/restore, both pauses remaining intact, and the deferred guest moving to the other display when that display exited full screen.

| Display 0 | Display 1 | Both arrival directions |
|---|---|---|
| Native | Native | Passed |
| Native | Non-native | Passed |
| Non-native | Native | Passed |
| Non-native | Non-native | Passed |

Additional checks passed:

- With one available display, both full-screen kinds routed cold and restored guests there while preserving the originating display's pause.
- A deferred guest minimized before the other display exited stayed minimized. A guest that quit was not relaunched.
- Quitting a non-native host cleared its display's pause. All fixtures were closed after testing.
- Native windows reported `AXFullScreen = true` and native Space membership. Non-native presentations reported `AXUnknown`, `AXFullScreen = false`, a display-sized frame, and regular Space membership.
- Cold URL launches and switching between modes worked. Commands arriving before application launch completes are retained until the window exists, preventing the guest's startup crash.

Accessibility can omit a guest parked behind a native full-screen Space. WindowServer identity/frame/Space observations and the fixture's minimize/restore delegate logs were used to verify those states without activating the guest.

The checks exposed three Zonogy failures addressed by this change: focus on a guest falsely ending a non-native pause; AppKit's full-width native toolbar replacing the native window's tracking record; and a repeated recovery pass re-placing a displaced window still waiting for minimization. Recovery uses the existing unassigned-window state and minimization queue, with no new timer.

Native traces can still include another full-screen raise after an earlier activation returned. Final placement and Space state were correct; this matrix does not assert an exact activation count.
