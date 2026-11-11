#!/usr/bin/env python3
"""Generates Resources/Tour/zones.svg, the scene on the Welcome tour's Zones page.

One loop: two windows fill the display's two zones, and labels name the New Zone Bar and the Floating Zone
Bar. Clicking the left New Zone Bar splits that side: the window there keeps the top, and the new zone under
it is empty, so it shows a placeholder, is the destination, and has the Launcher open in it. That side now
holds two zones, so its bar is gone. Clicking the placeholder's × removes the zone again.

Usage: python3 scripts/tour-zones-animation.py Resources/Tour/zones.svg
"""
import sys

from animation_common import EIO, Timeline, launcher, opacity, placeholder, resizable_window
from tour_common import (CONTENT_OPACITY, FLOATING_ZONE_BAR, LEFT, NEW_ZONE_BARS, RIGHT, Pointer, bottom_half,
                         destination_indicator, label, new_zone_bar, panel, shown, top_half, window, write_scene)

DUR = 10.2  # loop length, seconds
T_STILL = 5.8  # frame shown where CSS animations don't run: the new zone, empty, with the Launcher open in it
TITLE = (
    "Zones in Zonogy. A bar on each side edge of the display adds a tiling zone there, and a bar on the bottom "
    "edge floats a window. A new zone is empty: it shows a placeholder, with the Launcher open in it to pick a "
    "window for it. Clicking the placeholder's close button removes the zone."
)
CAPTIONS = (  # (text, shown from, fading out at)
    ("Click a New Zone Bar to add a zone", 3.2, 6.3),
    ("Click × on an empty zone to remove it", 6.6, 9.2),
)

NEW = bottom_half(LEFT)  # the zone added and removed
ROWS = (("green", 96, 52), ("amber", 116, 62), ("teal", 86, 48), ("pink", 104, 56))  # the Launcher's rows
ADD, REMOVE = 4.1, 7.5  # clicks: the New Zone Bar, then ×
REST = (RIGHT[0] + 170, RIGHT[1] + 250)  # pointer rest point
_bx, _by, _bw, _bh = NEW_ZONE_BARS["left"]
BAR_POINT = (_bx + _bw / 2, _by + _bh / 2)
CLOSE = (NEW[0] + 20, NEW[1] + 20)  # the placeholder's ×


def build(path):
    tl = Timeline(DUR, T_STILL)
    pointer = Pointer(tl, REST)
    pointer.move(3.2, 3.95, BAR_POINT)
    pointer.click(ADD)
    pointer.move(4.75, 5.35, (NEW[0] + 44, NEW[1] + NEW[3] - 56))  # aside, clear of the new zone's ×
    pointer.move(6.7, 7.35, CLOSE)
    pointer.click(REMOVE)
    pointer.move(8.5, 9.3, REST)
    pointer.tracks()

    # The window on the left gives up its lower half to the new zone, and takes it back.
    whole, halved = "transform:scaleY(1)", f"transform:scaleY({top_half(LEFT)[3] / LEFT[3]:.4f})"
    tl.track("split", [(ADD + .05, whole, EIO), (ADD + .45, halved), (REMOVE + .1, halved, EIO), (REMOVE + .5, whole)],
             origin=(0, LEFT[1]))
    tl.css.append(".split rect{vector-effect:non-scaling-stroke}")
    shown(tl, "empty", ADD + .2, REMOVE + .05)
    panel(tl, "lc", NEW, ADD + .4, REMOVE + .03)
    # A side holding two zones can take no more, so its New Zone Bar goes while the new zone is there.
    tl.track("nzbar", [(ADD + .05, opacity(1)), (ADD + .25, opacity(0)), (REMOVE + .3, opacity(0)), (REMOVE + .5, opacity(1))])

    shown(tl, "names", .6, 2.9, .3, .3)
    shown(tl, "emptyname", ADD + 1.0, REMOVE - .9, .3, .3)

    fx, fy, _, _ = FLOATING_ZONE_BAR
    mid = NEW[1] + NEW[3] / 2
    content = [
        resizable_window(LEFT, "purple", "split", "", CONTENT_OPACITY),
        window(RIGHT, "blue"),
        new_zone_bar("left", "nzbar"), new_zone_bar("right"),
        f'<g class="empty">\n{placeholder("ph", NEW)}\n{destination_indicator(NEW)}\n</g>',
        launcher("lc", NEW, ROWS),
        '<g class="names">',
        label("n1", "New Zone Bar", (BAR_POINT[0] + 150, BAR_POINT[1] - 70), BAR_POINT),
        label("n2", "Floating Zone Bar", (fx - 130, fy - 34), (fx + 6, fy + 2)),
        "</g>",
        label("emptyname", "Empty zone", (NEW[0] + NEW[2] + 112, mid), (NEW[0] + NEW[2] - 10, mid)),
        pointer.svg(),
    ]
    write_scene(path, TITLE, "scripts/tour-zones-animation.py", tl, content, CAPTIONS)


if __name__ == "__main__":
    build(sys.argv[1])
