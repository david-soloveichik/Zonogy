#!/usr/bin/env python3
"""Generates Resources/Tour/keyboard-one-zone.svg, the scene on the Keyboard chapter's One zone page.

One loop, worked from the keyboard (the key pressed shows under the display; it says what it does instead of
naming a key, since the user can change it). Three windows fill the display's three zones, and the top-right one
is focused. The one-zone shortcut minimizes the other two, and the focused window grows to fill the display,
its zone now the only one; both sides can take a zone again, so both New Zone Bars show. Finally the whole
picture fades out and back in on the opening arrangement, so the loop restarts where it began.

Usage: python3 scripts/tour-keyboard-one-zone-animation.py Resources/Tour/keyboard-one-zone.svg
"""
import sys

from animation_common import EIO, Timeline, n, opacity
from tour_common import (FULL, LEFT, RESTART_COVER, RIGHT, bottom_half, inactive_lights, new_zone_bar, top_half,
                         window, write_scene)

DUR = 7.0  # loop length, seconds
T_STILL = 4.2  # frame shown where CSS animations don't run: the focused window filling the display
TITLE = (
    "Keeping one zone with the keyboard in Zonogy. A shortcut keeps only the focused window's zone: the window "
    "fills the display, and the other windows are minimized."
)
CAPTIONS = (  # (text, shown from, fading out at)
    ("Keep only the focused window's zone", .3, 2.6),
    ("It fills the display, and the other windows are minimized", 2.9, 5.6),
)
KEYS = (("one zone", 96, "kone"),)

TOP, BOTTOM = top_half(RIGHT), bottom_half(RIGHT)
PRESS = 1.6  # the one-zone shortcut
GROW = PRESS + .2  # the focused window starts growing, once the others are gone
RESTART = 6.0  # the picture is covered from here, and returns to its opening arrangement (see write_scene)
OPENING = RESTART + RESTART_COVER / 2  # when it does, unseen


def build(path):
    tl = Timeline(DUR, T_STILL)
    tl.key_presses("kone", [(PRESS, PRESS + .14)])

    # The other windows are minimized: they fade out in place.
    tl.track("others", [(PRESS + .05, opacity(1)), (PRESS + .2, opacity(0)), (OPENING, opacity(0)),
                        (OPENING + .001, opacity(1))])

    # The focused window grows from its zone to the whole display. It is drawn at its final size, so its content
    # is laid out for it, and starts out scaled down onto the zone it had.
    sx, sy = TOP[2] / FULL[2], TOP[3] / FULL[3]
    small = f"transform:translate({n(TOP[0] - FULL[0])}px,{n(TOP[1] - FULL[1])}px) scale({sx:.4f},{sy:.4f})"
    large = "transform:translate(0px,0px) scale(1,1)"
    tl.track("grow", [(GROW, small, EIO), (GROW + .45, large), (OPENING, large), (OPENING + .001, small)], origin=FULL[:2])
    swap = lambda before, after: [(GROW, opacity(before)), (GROW + .001, opacity(after)), (OPENING, opacity(after)),
                                  (OPENING + .001, opacity(before))]
    tl.track("large", swap(0, 1))
    tl.track("small", swap(1, 0))
    # With one zone, both sides can take another, so the right side's New Zone Bar shows too.
    tl.track("nzbar", [(GROW + .3, opacity(0)), (GROW + .5, opacity(1)), (OPENING, opacity(1)), (OPENING + .001, opacity(0))])

    content = [
        '<g class="others">', window(LEFT, "purple"), inactive_lights("off", LEFT), window(BOTTOM, "orange"),
        inactive_lights("off", BOTTOM), "</g>",
        f'<g class="small">\n{window(TOP, "blue")}\n</g>',
        f'<g class="grow"><g class="large">\n{window(FULL, "blue")}\n</g></g>',
        new_zone_bar("left"), new_zone_bar("right", "nzbar"),
    ]
    write_scene(path, TITLE, "scripts/tour-keyboard-one-zone-animation.py", tl, content, CAPTIONS,
                restart_at=RESTART, keys=KEYS)


if __name__ == "__main__":
    build(sys.argv[1])
