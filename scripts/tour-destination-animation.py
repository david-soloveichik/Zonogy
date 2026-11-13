#!/usr/bin/env python3
"""Generates Resources/Tour/destination.svg, the scene on the Welcome chapter's destination page.

One loop: three windows fill the display's three zones. Minimizing the top-right one leaves its zone in place,
empty: it is now the destination, marked by its glow and the bar above it, with the Launcher open in it, and
the window picked there fills it. With every zone full no zone is the destination, so the next window, opened
from the Dock, floats above the tiles. Clicking a tiled window that the floating one covers minimizes it.
Finally the top-right zone crossfades back to its first window, so the loop restarts where it began.

Usage: python3 scripts/tour-destination-animation.py Resources/Tour/destination.svg
"""
import sys

from animation_common import EIO, ROW_H, Timeline, icon_center, launcher, launcher_origin, placeholder, row_center
from tour_common import (FLOATING, LEFT, RIGHT, S, Pointer, arriving, arriving_window, bottom_half,
                         destination_indicator, hidden, new_zone_bar, panel, shown, top_half, window, write_scene)

DUR = 11.8  # loop length, seconds
T_STILL = 2.2  # frame shown where CSS animations don't run: the emptied zone, with the Launcher open in it
TITLE = (
    "The destination zone in Zonogy. Minimizing a window leaves its zone empty: that zone becomes the "
    "destination, marked by a glow, with the Launcher open in it to pick the window that fills it. When every "
    "zone is full, a new window floats above the tiles, and it is minimized when a window it covers is focused."
)
CAPTIONS = (  # (text, shown from, fading out at)
    ("An emptied zone becomes the destination, with the Launcher open in it", 1.1, 4.3),
    ("When every zone is full, new windows open in the floating zone", 4.8, 7.4),
    ("A floating zone window is minimized when you focus one it covers", 7.7, 10.2),
)

ZONE = top_half(RIGHT)  # the zone that is emptied and filled
ROWS = (("teal", 96, 52), ("green", 116, 62), ("amber", 86, 48), ("pink", 104, 56))  # Launcher; row 2 is picked
MINIMIZE, PICK, OPEN, FOCUS, RESET = 1.35, 3.25, 5.55, 8.45, 10.5  # clicks, then the crossfade back
REST = (LEFT[0] + 260, LEFT[1] + 300)  # pointer rest point
YELLOW = (ZONE[0] + 26, ZONE[1] + 11)  # the minimize button of the zone's window
ROW2 = (launcher_origin(ZONE)[0] + 90, row_center(ZONE, 1) + 2)
ROW2_ICON = (launcher_origin(ZONE)[0] + 26, row_center(ZONE, 1))
DOCK_ICON = icon_center(S, "amber")
TILE = (LEFT[0] + 110, LEFT[1] + 330)  # a spot on the left window that the floating one doesn't cover


def build(path):
    tl = Timeline(DUR, T_STILL)
    pointer = Pointer(tl, REST)
    pointer.move(.5, 1.2, YELLOW)
    pointer.click(MINIMIZE)
    pointer.move(2.35, 2.95, ROW2)
    pointer.click(PICK)
    pointer.move(4.6, 5.4, DOCK_ICON)
    pointer.click(OPEN)
    pointer.move(7.6, 8.3, TILE)
    pointer.click(FOCUS)
    pointer.move(10.4, 11.2, REST)
    pointer.tracks()

    # Minimizing fades the window out in place. Its zone stays, as a placeholder, and the Launcher opens there;
    # the window picked in it grows from its row.
    hidden(tl, "first", MINIMIZE + .1, RESET)
    shown(tl, "empty", MINIMIZE + .15, PICK + .15, .2, .25)
    panel(tl, "lc", ZONE, MINIMIZE + .25, PICK)
    row1, row2 = "transform:translateY(0px)", f"transform:translateY({ROW_H}px)"
    tl.track("lcsel", [(2.9, row1, EIO), (3.02, row2), (PICK + .5, row2), (PICK + .501, row1)])  # follows the pointer
    arriving(tl, "picked", ZONE, ROW2_ICON, PICK + .05, RESET, .4)

    # The window opened from the Dock has no zone to go to, so it floats, until a window under it is focused.
    arriving(tl, "float", FLOATING, DOCK_ICON, OPEN + .05, FOCUS + .05)

    content = [
        window(LEFT, "purple"), window(bottom_half(RIGHT), "orange"), new_zone_bar("left"),
        f'<g class="empty">\n{placeholder("ph", ZONE)}\n{destination_indicator(ZONE)}\n</g>',
        f'<g class="first">\n{window(ZONE, "blue")}\n</g>',
        arriving_window("picked", ZONE, "green"),
        launcher("lc", ZONE, ROWS),
        arriving_window("float", FLOATING, "amber", floating=True),
        pointer.svg(),
    ]
    write_scene(path, TITLE, "scripts/tour-destination-animation.py", tl, content, CAPTIONS)


if __name__ == "__main__":
    build(sys.argv[1])
