#!/usr/bin/env python3
"""Generates Resources/Tour/keyboard-stepping.svg, the scene on the Keyboard chapter's Stepping between
zones page.

One loop, worked from the keyboard (the keys pressed show under the display). The left window is focused, and
the bottom-right zone is empty. With the modifier keys held, the right arrow puts the circle on the zone to the
right, and the down arrow steps it onto the empty zone below. Releasing there makes that zone the destination
(it flashes), and the Launcher opens in it. Holding again, the up arrow steps the circle onto the window above;
releasing focuses that window, which closes the Launcher. The loop then starts over with the left window
focused again.

Usage: python3 scripts/tour-keyboard-stepping-animation.py Resources/Tour/keyboard-stepping.svg
"""
import sys

from animation_common import ZBLUE, Timeline, launcher, opacity, placeholder, rect
from tour_common import (LEFT, RIGHT, TAP, bottom_half, circle_runs, destination_indicator, inactive_lights,
                         navigation_circle, new_zone_bar, panel, top_half, window, write_scene)

DUR = 10.0  # loop length, seconds
T_STILL = 2.8  # frame shown where CSS animations don't run: the keys held, the circle on the empty zone
TITLE = (
    "Stepping between zones with the keyboard in Zonogy. While the modifier keys are held, each arrow key moves "
    "a circle to the next zone in that direction. Releasing over an empty zone makes it the destination and "
    "opens the Launcher there. Releasing over a window's zone focuses that window."
)
CAPTIONS = (  # (text, shown from, fading out at)
    ("Hold the modifier keys and press arrows: a circle steps between zones", .5, 3.1),
    ("Release on an empty zone to make it the destination, with the Launcher", 3.4, 5.8),
    ("Release on a window's zone to focus that window", 6.0, 9.2),
)
KEYS = (("{navigation keys}", 80, "khold"), ("←", 40, "kleft"), ("↑", 40, "kup"), ("↓", 40, "kdown"), ("→", 40, "kright"))

WINDOW, EMPTY = top_half(RIGHT), bottom_half(RIGHT)  # the right column: a window over the empty zone
ROWS = (("green", 96, 52), ("amber", 116, 62), ("teal", 86, 48), ("pink", 104, 56))  # the Launcher's rows
HELD = ((.9, 3.3), (6.2, 7.9))  # the modifier keys, held for each gesture
RIGHT_KEY, DOWN_KEY, UP_KEY = 1.3, 2.2, 6.6  # arrow presses


def build(path):
    tl = Timeline(DUR, T_STILL)
    tl.key_presses("khold", HELD)
    for cls, t in (("kright", RIGHT_KEY), ("kdown", DOWN_KEY), ("kup", UP_KEY)):
        tl.key_presses(cls, [(t, t + TAP)])

    # The first gesture starts from the focused window on the left; the second from the Launcher's zone.
    circle_runs(tl, "dot", [([(RIGHT_KEY, WINDOW), (DOWN_KEY, EMPTY)], HELD[0][1]), ([(UP_KEY, WINDOW)], HELD[1][1])])

    # Released over the empty zone: it flashes as the destination, and the Launcher opens in it, until the
    # second gesture focuses a window.
    released, focused = HELD[0][1], HELD[1][1]
    tl.track("flash", [(released, opacity(0)), (released + .1, opacity(1)), (released + .45, opacity(0))])
    panel(tl, "lc", EMPTY, released + .1, focused)
    # Focus shows in the traffic lights: gray on every window but the focused one.
    tl.track("leftoff", [(focused, opacity(0)), (focused + .12, opacity(1))])
    tl.track("rightoff", [(focused, opacity(1)), (focused + .12, opacity(0))])

    x, y, w, h = EMPTY
    content = [
        window(LEFT, "purple"), window(WINDOW, "blue"),
        inactive_lights("leftoff", LEFT), inactive_lights("rightoff", WINDOW),
        new_zone_bar("left"),
        placeholder("ph", EMPTY), destination_indicator(EMPTY),
        '<g class="flash">' + rect(x, y, w, h, 8, fill=ZBLUE, fill_opacity=".3", stroke=ZBLUE, stroke_width="4") + "</g>",
        launcher("lc", EMPTY, ROWS),
        navigation_circle("dot"),
    ]
    write_scene(path, TITLE, "scripts/tour-keyboard-stepping-animation.py", tl, content, CAPTIONS, keys=KEYS)


if __name__ == "__main__":
    build(sys.argv[1])
