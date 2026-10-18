# Karabiner-Elements Configuration

Most default Zonogy shortcuts use `Control-Cmd` as the modifier. [Karabiner-Elements](https://karabiner-elements.pqrs.org/) is a free macOS keyboard customizer, and I use it to turn `Caps Lock` into `Control-Cmd` and to put three frequent Zonogy shortcuts on single keys:

| Key | Sends | Zonogy action |
| --- | --- | --- |
| Hold `Caps Lock` | `Control-Cmd` | Modifier for most Zonogy shortcuts |
| Tap `Caps Lock` | `Control-Cmd-\` | Toggle destination with the focused window's tiling zone |
| `F3` | `Control-Cmd-Escape` | Clear zones on the active display; hold to also reset to one zone |
| `F4` | `Control-Cmd-Space` | Open the Launcher |

A fourth rule turns off the macOS Lock Screen shortcut, `Control-Cmd-Q`, which the `Caps Lock` remapping makes easy to hit by accident.

## Adding the rules

In Karabiner-Elements, open *Settings* > *Complex Modifications* > *Add your own rule*, replace the sample rule in the editor with one of the rules below, and press *Save*. Repeat for each rule.

The rules send Zonogy's default shortcuts. If you change one of these in Zonogy's *Preferences* > *Shortcuts*, edit the matching rule to send the new shortcut.

## Caps Lock: `Control-Cmd` when held, `Control-Cmd-\` when tapped

```json
{
    "description": "Caps Lock to Hyper (hold) / Cmd-Ctr-Backslash (tap)",
    "manipulators": [
        {
            "from": {
                "key_code": "caps_lock",
                "modifiers": { "optional": ["any"] }
            },
            "parameters": { "basic.to_if_alone_timeout_milliseconds": 200 },
            "to": [
                {
                    "key_code": "left_control",
                    "modifiers": ["left_command"]
                }
            ],
            "to_if_alone": [
                {
                    "key_code": "backslash",
                    "modifiers": ["left_control", "left_command"]
                }
            ],
            "type": "basic"
        }
    ]
}
```

**Hold.** Holding `Caps Lock` holds `Control` and `Cmd` (the "Hyper" in the rule's description), so every `Control-Cmd` shortcut becomes `Caps Lock` plus one key. I don't normally use `Caps Lock` for anything else. It works especially well for the gestures that keep `Control-Cmd` down: zone navigation (hold `Caps Lock`, press arrows or jump keys, and release to commit), `Control-Cmd`-click to choose the destination, and holding `Control-Cmd` during a drag.

**Tap.** Pressing and releasing `Caps Lock` by itself sends `Control-Cmd-\`, which makes the focused window's zone the destination (a second tap moves the destination on, as if that zone had just been filled). For example, to replace the focused window, tap `Caps Lock`, press `F4`, and pick the replacement in the Launcher; it takes over the zone, and the old window is minimized. Typed out, `Control-Cmd-\` takes two hands, since `\` is at the far right of the keyboard.

The 200 ms `basic.to_if_alone_timeout_milliseconds` is how quickly you have to release `Caps Lock` for it to count as a tap rather than a hold.

## F3: clear and reset zones

```json
{
    "description": "Map F3 to Control-Command-Escape",
    "manipulators": [
        {
            "from": {
                "key_code": "f3",
                "modifiers": { "optional": ["any"] }
            },
            "to": [
                {
                    "key_code": "escape",
                    "modifiers": ["left_control", "left_command"]
                }
            ],
            "type": "basic"
        }
    ]
}
```

`F3` sends `Control-Cmd-Escape`, which clears the zones on the active display. Karabiner holds `Control-Cmd-Escape` down for as long as you hold `F3`, so Zonogy's hold gesture works too: holding `F3` for half a second also resets the display to one zone. On Mac keyboards, `F3` is the Mission Control key, which I don't need since Zonogy replaces Spaces.

## F4: open the Launcher

```json
{
    "description": "Map F4 to Control-Command-Space",
    "manipulators": [
        {
            "from": {
                "key_code": "f4",
                "modifiers": { "optional": ["any"] }
            },
            "to": [
                {
                    "key_code": "spacebar",
                    "modifiers": ["left_control", "left_command"]
                }
            ],
            "type": "basic"
        }
    ]
}
```

`F4` sends `Control-Cmd-Space`, which opens the Launcher in the destination zone. On recent Mac keyboards, `F4` is the Spotlight key (Launchpad on older ones), so the key for finding and opening apps opens the Launcher instead, which can also switch to a specific window.

## Control-Cmd-Q: disabled

```json
{
    "description": "Disable Control-Command-Q lock screen shortcut",
    "manipulators": [
        {
            "from": {
                "key_code": "q",
                "modifiers": { "mandatory": ["control", "command"] }
            },
            "type": "basic"
        }
    ]
}
```

macOS uses `Control-Cmd-Q` to lock the screen. With `Caps Lock` as `Control-Cmd`, that is `Caps Lock`-`Q`, one slip away from `Caps Lock`-`Tab` (browse WinShot snapshots) or `Caps Lock`-`A` (zone navigation's top-left jump key). The rule has no `to`, so Karabiner swallows `Control-Cmd-Q` and nothing happens. Lock Screen is still in the Apple menu.

## Other details

- `"optional": ["any"]` lets the `Caps Lock`, `F3`, and `F4` rules fire while other modifiers are held, and Karabiner keeps those modifiers in what it sends. For example, `Shift`-`F3` sends `Shift-Control-Cmd-Escape`, which clears the display under the pointer instead of the active one.
- Karabiner applies these rules before its own function key settings, so `F3` and `F4` work whether or not the top row acts as standard function keys.
