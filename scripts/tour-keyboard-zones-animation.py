#!/usr/bin/env python3
"""Generates Resources/Tour/keyboard-zones.svg, the scene on the Keyboard chapter's Adding and removing zones page.

One loop, worked from the keyboard (the keys pressed show under the display; those the user can change say what
they do instead of naming a key). Two windows fill the display's two zones, and the right one is focused. The
add-zone shortcut splits the right side: the window there keeps the top, and the new zone under it is empty, so
it is the destination and the Launcher opens in it. Return opens the Launcher's first window there, which takes
the focus. Minimizing that window leaves its zone in place, empty, with the Launcher open again; minimizing once
more removes the zone, and the window above takes back the whole side, where the loop began.

Usage: python3 scripts/tour-keyboard-zones-animation.py Resources/Tour/keyboard-zones.svg
"""
import sys

from animation_common import EIO, Timeline, launcher, launcher_origin, opacity, placeholder, resizable_window, row_center
from tour_common import (CONTENT_OPACITY, LEFT, RIGHT, arriving, arriving_window, bottom_half, destination_indicator,
                         inactive_lights, new_zone_bar, panel, shown, top_half, window, write_scene)

DUR = 10.2  # loop length, seconds
T_STILL = 2.2  # frame shown where CSS animations don't run: the new zone, empty, with the Launcher open in it
TITLE = (
    "Adding and removing zones with the keyboard in Zonogy. A shortcut adds a zone, which opens empty, with the "
    "Launcher in it. Minimizing a window leaves its zone in place, empty, with the Launcher open; minimizing again "
    "removes the zone."
)
CAPTIONS = (  # (text, shown from, fading out at)
    ("Add a zone: it opens empty, with the Launcher in it", .3, 3.7),
    ("Minimize a window: its zone stays, with the Launcher open", 4.0, 6.8),
    ("Minimize again to remove the zone", 7.1, 9.7),
)
KEYS = (("{add zone}", 80, "kadd"), ("↩", 40, "kret"), ("{minimize}", 80, "kmin"))

ADDED = bottom_half(RIGHT)  # the zone the shortcut adds, and the second minimize removes
ROWS = (("orange", 96, 52), ("green", 116, 62), ("amber", 86, 48), ("pink", 104, 56))  # the Launcher's; Return opens the first
ADD, OPEN, MINIMIZE, REMOVE = 1.2, 2.7, 4.6, 7.4  # key presses
TAP = .14


def build(path):
    tl = Timeline(DUR, T_STILL)
    for cls, times in (("kadd", (ADD,)), ("kret", (OPEN,)), ("kmin", (MINIMIZE, REMOVE))):
        tl.key_presses(cls, [(t, t + TAP) for t in times])

    # The right window gives up its lower half to the new zone, and takes it back when the zone is removed. That
    # side holds two zones meanwhile, so its New Zone Bar goes.
    whole, halved = "transform:scaleY(1)", f"transform:scaleY({top_half(RIGHT)[3] / RIGHT[3]:.4f})"
    tl.track("split", [(ADD + .05, whole, EIO), (ADD + .45, halved), (REMOVE + .1, halved, EIO), (REMOVE + .5, whole)],
             origin=(0, RIGHT[1]))
    tl.css.append(".split rect{vector-effect:non-scaling-stroke}")
    tl.track("nzbar", [(ADD + .05, opacity(1)), (ADD + .25, opacity(0)), (REMOVE + .3, opacity(0)),
                       (REMOVE + .5, opacity(1))])

    # The new zone is empty, so it is the destination, with the Launcher open in it, until the window opened there
    # fills it. Minimizing that window empties it again, and the second minimize removes it.
    shown(tl, "empty", ADD + .2, REMOVE + .05)
    tl.track("tgt", [(OPEN + .25, opacity(1)), (OPEN + .4, opacity(0)), (MINIMIZE + .05, opacity(0)),
                     (MINIMIZE + .2, opacity(1))])
    panel(tl, "lc", ADDED, ADD + .4, OPEN)
    panel(tl, "lc2", ADDED, MINIMIZE + .2, REMOVE)
    arriving(tl, "opened", ADDED, (launcher_origin(ADDED)[0] + 26, row_center(ADDED, 0)), OPEN + .05, MINIMIZE)

    # Focus shows in the traffic lights: the right window loses it to the window opened under it, and gets it back
    # once that window's zone is gone.
    tl.track("roff", [(OPEN + .1, opacity(0)), (OPEN + .2, opacity(1)), (REMOVE + .3, opacity(1)), (REMOVE + .4, opacity(0))])

    content = [
        window(LEFT, "purple"), inactive_lights("loff", LEFT),
        resizable_window(RIGHT, "blue", "split", "", CONTENT_OPACITY), inactive_lights("roff", RIGHT),
        new_zone_bar("left"), new_zone_bar("right", "nzbar"),
        f'<g class="empty">\n{placeholder("ph", ADDED, "tgt")}\n<g class="tgt">{destination_indicator(ADDED)}</g>\n</g>',
        launcher("lc", ADDED, ROWS), launcher("lc2", ADDED, ROWS),
        arriving_window("opened", ADDED, "orange"),
    ]
    write_scene(path, TITLE, "scripts/tour-keyboard-zones-animation.py", tl, content, CAPTIONS, keys=KEYS)


if __name__ == "__main__":
    build(sys.argv[1])
