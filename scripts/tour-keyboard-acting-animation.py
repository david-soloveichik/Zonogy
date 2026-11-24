#!/usr/bin/env python3
"""Generates Resources/Tour/keyboard-acting.svg, the scene on the Keyboard chapter's Acting on this zone
page.

One loop, worked from the keyboard (the keys pressed show under the display, as the user's current keys).
Three windows fill three zones, and the left one is focused. With the
modifier keys held, the right arrow puts the circle on the top-right zone, and the move key brings the focused
window into that zone: the two windows swap. Holding again, the left arrow puts the circle on the left zone,
and the add key adds a zone under it: the window there keeps the top, the new zone is empty and the
destination, the Launcher opens in it, and the circle moves onto it. Finally the whole picture fades out and
back in on the opening arrangement, so the loop restarts where it began.

Usage: python3 scripts/tour-keyboard-acting-animation.py Resources/Tour/keyboard-acting.svg
"""
import sys

from animation_common import EIO, Timeline, launcher, opacity, placeholder, resizable_window
from tour_common import (CONTENT_OPACITY, LEFT, RESTART_COVER, RIGHT, TAP, bottom_half, circle_runs,
                         destination_indicator, inactive_lights, navigation_circle, new_zone_bar, panel, shown,
                         top_half, window, write_scene)

DUR = 10.6  # loop length, seconds
T_STILL = 1.9  # frame shown where CSS animations don't run: the keys held, the circle on the top-right zone
TITLE = (
    "Acting on a zone with the keyboard in Zonogy. While the modifier keys are held and the circle is on a zone, "
    "one key moves the focused window into that zone, swapping with the window there, and another adds a zone "
    "under it, where the Launcher opens."
)
CAPTIONS = (  # (text, shown from, fading out at)
    ("With the circle on a zone, the move key brings your window into it", .5, 4.0),
    ("The add key adds a zone there, ready to fill", 4.4, 9.0),
)
KEYS = (("{navigation keys}", 80, "khold"), ("←", 40, "kleft"), ("↑", 40, "kup"), ("↓", 40, "kdown"), ("→", 40, "kright"),
        ("{move key}", 56, "kmove"), ("{add key}", 56, "kadd"))

TOP, BOTTOM = top_half(RIGHT), bottom_half(RIGHT)
ADDED = bottom_half(LEFT)  # the zone the add key creates
ROWS = (("green", 96, 52), ("amber", 116, 62), ("teal", 86, 48), ("pink", 104, 56))  # the Launcher's rows
HELD = ((.9, 2.7), (4.6, 7.8))  # the modifier keys, held for each gesture
RIGHT_KEY, MOVE_KEY, LEFT_KEY, ADD_KEY = 1.3, 2.3, 5.0, 6.0
RESTART = 9.6  # the picture is covered from here, and returns to its opening arrangement (see write_scene)
OPENING = RESTART + RESTART_COVER / 2  # when it does, unseen


def build(path):
    tl = Timeline(DUR, T_STILL)
    tl.key_presses("khold", HELD)
    for cls, t in (("kright", RIGHT_KEY), ("kmove", MOVE_KEY), ("kleft", LEFT_KEY), ("kadd", ADD_KEY)):
        tl.key_presses(cls, [(t, t + TAP)])

    # The move key ends its gesture at once; the add key leaves the circle on the new zone until release.
    circle_runs(tl, "dot", [([(RIGHT_KEY, TOP)], MOVE_KEY + .05), ([(LEFT_KEY, LEFT), (ADD_KEY + .1, ADDED)], HELD[1][1])])

    # The move: the focused window and the one in the circle's zone trade places.
    tl.track("before", [(MOVE_KEY + .05, opacity(1)), (MOVE_KEY + .35, opacity(0)), (OPENING, opacity(0)), (OPENING + .001, opacity(1))])
    tl.track("after", [(MOVE_KEY + .05, opacity(0)), (MOVE_KEY + .35, opacity(1)), (OPENING, opacity(1)), (OPENING + .001, opacity(0))])

    # The add: the window on the left gives up its lower half to the new zone, which is empty, so it is the
    # destination and the Launcher opens in it. That side now holds two zones, so its New Zone Bar goes.
    whole, halved = "transform:scaleY(1)", f"transform:scaleY({top_half(LEFT)[3] / LEFT[3]:.4f})"
    tl.track("split", [(ADD_KEY + .05, whole, EIO), (ADD_KEY + .45, halved), (OPENING, halved), (OPENING + .001, whole)],
             origin=(0, LEFT[1]))
    tl.css.append(".split rect{vector-effect:non-scaling-stroke}")
    shown(tl, "empty", ADD_KEY + .2, OPENING, .2, .001)
    panel(tl, "lc", ADDED, ADD_KEY + .4, OPENING)
    tl.track("nzbar", [(ADD_KEY + .05, opacity(1)), (ADD_KEY + .25, opacity(0)), (OPENING, opacity(0)), (OPENING + .001, opacity(1))])

    content = [
        window(BOTTOM, "orange"), inactive_lights("off", BOTTOM),
        # Before the move: the focused window on the left, the other in the top-right zone.
        '<g class="before">', window(LEFT, "purple"), window(TOP, "blue"), inactive_lights("off", TOP), "</g>",
        # After it: they have traded places, and the focused window is still the focused one.
        '<g class="after">', resizable_window(LEFT, "blue", "split", "", CONTENT_OPACITY), inactive_lights("off", LEFT),
        window(TOP, "purple"), "</g>",
        new_zone_bar("left", "nzbar"),
        f'<g class="empty">\n{placeholder("ph", ADDED)}\n{destination_indicator(ADDED)}\n</g>',
        launcher("lc", ADDED, ROWS),
        navigation_circle("dot"),
    ]
    write_scene(path, TITLE, "scripts/tour-keyboard-acting-animation.py", tl, content, CAPTIONS,
                restart_at=RESTART, keys=KEYS)


if __name__ == "__main__":
    build(sys.argv[1])
