#!/usr/bin/env python3
"""Generates Resources/Tour/keyboard-clear.svg, the scene on the Keyboard chapter's Clearing the display page.

One loop, worked from the keyboard (the key pressed shows under the display; it says what it does instead of
naming a key, since the user can change it). Three windows fill the display's three zones. The clear shortcut
minimizes all of them: the zones stay, empty, the left one becomes the destination, and the Launcher opens in it,
listing the windows just minimized. Pressed again, the shortcut resets the display to one zone, empty, the
destination, with the Launcher in it; both sides can take a zone again, so both New Zone Bars show. Finally the
whole picture fades out and back in on the opening arrangement, so the loop restarts where it began.

Usage: python3 scripts/tour-keyboard-clear-animation.py Resources/Tour/keyboard-clear.svg
"""
import sys

from animation_common import Timeline, launcher, opacity, placeholder
from tour_common import (FULL, LEFT, RESTART_COVER, RIGHT, TAP, bottom_half, destination_indicator, new_zone_bar,
                         panel, shown, top_half, window, write_scene)

DUR = 9.4  # loop length, seconds
T_STILL = 3.0  # frame shown where CSS animations don't run: the zones cleared, the Launcher open in the left one
TITLE = (
    "Clearing a display with the keyboard in Zonogy. A shortcut minimizes every window on the display, and its zones "
    "stay, empty, with the Launcher open in one. Pressed again, it resets the display to one zone."
)
CAPTIONS = (  # (text, shown from, fading out at)
    ("Clear the display: every window is minimized, and the zones stay", .3, 4.0),
    ("Clear it again to go back to one zone", 4.3, 7.9),
)
KEYS = (("{clear}", 80, "kclear"),)

TOP, BOTTOM = top_half(RIGHT), bottom_half(RIGHT)
ROWS = (("purple", 96, 52), ("blue", 116, 62), ("orange", 86, 48), ("green", 104, 56))  # the Launcher's: the windows just minimized first
CLEAR, RESET = 1.5, 4.9  # the two presses
RESTART = 8.3  # the picture is covered from here, and returns to its opening arrangement (see write_scene)
OPENING = RESTART + RESTART_COVER / 2  # when it does, unseen


def build(path):
    tl = Timeline(DUR, T_STILL)
    tl.key_presses("kclear", [(CLEAR, CLEAR + TAP), (RESET, RESET + TAP)])
    tl.track("wins", [(CLEAR + .05, opacity(1)), (CLEAR + .2, opacity(0)), (OPENING, opacity(0)),
                      (OPENING + .001, opacity(1))])

    # Cleared, the zones stay, empty. The left one is the destination, so the Launcher opens there; the others
    # never glow.
    shown(tl, "three", CLEAR + .15, RESET + .05)
    tl.track("never", [(0, opacity(0))])
    panel(tl, "lc", LEFT, CLEAR + .3, RESET)

    # Reset, one empty zone fills the display, and the Launcher moves to its middle. Both sides can take another
    # zone, so the right side's New Zone Bar shows too.
    shown(tl, "one", RESET + .1, OPENING, .2, .001)
    panel(tl, "lc2", FULL, RESET + .2, OPENING)
    tl.track("nzbar", [(RESET + .2, opacity(0)), (RESET + .4, opacity(1)), (OPENING, opacity(1)), (OPENING + .001, opacity(0))])

    content = [
        '<g class="wins">', window(LEFT, "purple"), window(TOP, "blue"), window(BOTTOM, "orange"), "</g>",
        new_zone_bar("left"), new_zone_bar("right", "nzbar"),
        '<g class="three">', placeholder("ph1", LEFT), destination_indicator(LEFT), placeholder("ph2", TOP, "never"),
        placeholder("ph3", BOTTOM, "never"), "</g>",
        f'<g class="one">\n{placeholder("ph4", FULL)}\n{destination_indicator(FULL)}\n</g>',
        launcher("lc", LEFT, ROWS), launcher("lc2", FULL, ROWS),
    ]
    write_scene(path, TITLE, "scripts/tour-keyboard-clear-animation.py", tl, content, CAPTIONS,
                restart_at=RESTART, keys=KEYS)


if __name__ == "__main__":
    build(sys.argv[1])
