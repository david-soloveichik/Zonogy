# Karabiner-Elements: Caps Lock as `Control-Cmd`

Most default Zonogy shortcuts use `Control-Cmd` as the modifier. I like remapping `Caps Lock` to `Control-Cmd`, since I don't normally use `Caps Lock` for other things.

[Karabiner-Elements](https://karabiner-elements.pqrs.org/) is a free macOS keyboard customizer that can do this remapping. The rule below goes one step further: holding `Caps Lock` acts as `Control-Cmd` (a "Hyper" key), and tapping `Caps Lock` alone fires `Control-Cmd-Space` (the default Launcher shortcut).

## Adding the rule

In Karabiner-Elements, open *Settings* → *Complex Modifications* → *Add your own rule*, and paste:

```json
{
    "description": "Caps Lock to Hyper (hold) / Cmd-Ctr-Space (tap)",
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
                    "key_code": "spacebar",
                    "modifiers": ["left_control", "left_command"]
                }
            ],
            "type": "basic"
        }
    ]
}
```

The 200ms timeout determines how quickly you have to release `Caps Lock` for it to count as a tap rather than a hold.
