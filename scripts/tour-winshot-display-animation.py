#!/usr/bin/env python3
"""Generates Resources/Tour/winshot-display.svg, the scene on the WinShot tour's Switching snapshots page.

One loop, on two displays. The chooser is open on the main display, showing its saved arrangements. One of
their thumbnails is dragged onto the smaller display: the thumbnail follows the pointer, and the display under
it is highlighted. On the drop the chooser closes and that arrangement opens on the smaller display, fitted to
it, in place of the window that was there. The main display keeps its own arrangement. Finally the smaller
display crossfades back to its first window (a cut, not a behavior), so the loop restarts where it began.

Usage: python3 scripts/tour-winshot-display-animation.py Resources/Tour/winshot-display.svg
"""
import sys

from animation_common import (EIO, EOUT, GAP, MAIN_DISPLAY, MARGIN, SIDE_DISPLAY, SIDE_STAND_FLOOR, TH, TW, WIDE,
                              WIDE_CAPTION_Y, ZBLUE, Timeline, at, captions, center, chooser, chooser_layout,
                              columns, dock, dock_origin, document, full_window, menubar, n, opacity, rect, scale,
                              thumbnail_defs, wallpapers, zone_frames)
from tour_common import CONTENT_OPACITY, Pointer, shown

DUR = 8.6  # loop length, seconds
T_STILL = 2.5  # frame shown where CSS animations don't run: the chooser open, the pointer on a thumbnail
TITLE = (
    "Opening a WinShot snapshot on another display. Dragging a snapshot's thumbnail from the chooser onto another "
    "display opens that arrangement there, fitted to that display."
)
CAPTIONS = (("Drag a snapshot to another display to open its arrangement there", 1.4, 6.6),)

S1, S2 = MAIN_DISPLAY, SIDE_DISPLAY
_t1, _h1, _w1, (_l1, _) = columns(S1, dock_origin(S1)[1] - GAP)
_t2, _h2, _w2, (_l2, _) = columns(S2, S2[1] + S2[3] - MARGIN)
FULL1, FULL2 = (_l1, _t1, 2 * _w1 + GAP, _h1), (_l2, _t2, 2 * _w2 + GAP, _h2)  # each display's zone area

NOW, EARLIER, OLDER = zone_frames(FULL1, .5, None, .5), zone_frames(FULL1, .56), zone_frames(FULL1, .4)
ARRANGEMENTS = {  # the main display's snapshots, windows in zone order: (app, frame, floating?)
    "now": (("purple", NOW[0], False), ("blue", NOW[1], False), ("orange", NOW[2], False)),
    "earlier": (("green", EARLIER[0], False), ("pink", EARLIER[1], False)),
    "older": (("amber", OLDER[0], False), ("purple", OLDER[1], False)),
}
ORDER, GAPS = ("now", "earlier", "older"), (24, 64)  # the chooser's timeline; "earlier" is dragged
FITTED = zone_frames(FULL2, .56)  # that arrangement's zones on the smaller display

(_px, _py, _), _xs = chooser_layout(S1, ORDER, GAPS)
THUMBNAIL = (_xs[1], _py + 18)  # the dragged thumbnail's corner in the chooser
GRAB = (THUMBNAIL[0] + TW / 2, THUMBNAIL[1] + TH / 2)
REST = (S1[0] + 210, S1[1] + 430)  # pointer rest point
OPENED, PRESSED, CARRIED, DROPPED, RESET = .8, 2.6, 4.0, 4.2, 7.2


def display_highlight(cls, screen):
    x, y, w, h = screen
    return f'<g class="{cls}">' + rect(x + 3, y + 3, w - 6, h - 6, 6, fill=ZBLUE, fill_opacity=".16", stroke=ZBLUE,
                                       stroke_width="4") + "</g>"


def build(path):
    tl = Timeline(DUR, T_STILL)
    pointer = Pointer(tl, REST)
    pointer.move(1.7, 2.4, GRAB)
    pointer.press(PRESSED)
    pointer.move(PRESSED + .1, CARRIED, center(S2))
    pointer.release(DROPPED)
    pointer.move(6.9, 7.7, REST)
    pointer.tracks()

    # The chooser stays open through the drag, and closes on the drop.
    tl.track("ch", [(OPENED, opacity(0, scale(.97)), EOUT), (OPENED + .15, opacity(1, scale(1))), (DROPPED, opacity(1, scale(1))),
                    (DROPPED + .12, opacity(0, scale(1)))], origin=center(S1))

    # The dragged thumbnail follows the pointer, and the display under the pointer is highlighted.
    carried = at(center(S2)[0] - GRAB[0], center(S2)[1] - GRAB[1])
    tl.track("carrymv", [(PRESSED + .1, at(0, 0), EIO), (CARRIED, carried), (DROPPED + .15, carried), (DROPPED + .151, at(0, 0))])
    shown(tl, "carry", PRESSED, DROPPED, .08, .12)
    crossed = next(t / 500 for t in range(int(PRESSED * 500), int(CARRIED * 500) + 1) if pointer.at(t / 500)[0] >= S2[0])
    shown(tl, "hot1", PRESSED + .05, crossed - .12, .1, .1)
    shown(tl, "hot2", crossed, DROPPED + .05, .1, .2)

    # On the drop the arrangement opens on the smaller display, in place of the window there.
    tl.track("was", [(DROPPED + .05, opacity(1)), (DROPPED + .2, opacity(0)), (RESET, opacity(0)), (RESET + .4, opacity(1))])
    tl.track("opened", [(DROPPED + .1, opacity(0)), (DROPPED + .4, opacity(1)), (RESET, opacity(1)), (RESET + .4, opacity(0))])

    tl.captions(CAPTIONS)
    window = lambda z, app: full_window(z, app, CONTENT_OPACITY)
    screens = [
        thumbnail_defs(ARRANGEMENTS, FULL1), wallpapers((S1, S2)), menubar(S1), menubar(S2),
        *(window(frame, app) for app, frame, _ in ARRANGEMENTS["now"]), dock(S1),
        f'<g class="was">\n{window(FULL2, "teal")}\n</g>',
        '<g class="opened">', window(FITTED[0], "green"), window(FITTED[1], "pink"), "</g>",
        display_highlight("hot1", S1), display_highlight("hot2", S2),
        chooser("ch", S1, ORDER, GAPS, 1),
        f'<g class="carrymv"><g class="carry" filter="url(#shadow)"><use href="#th-earlier" x="{n(THUMBNAIL[0])}" '
        f'y="{n(THUMBNAIL[1])}"/></g></g>',
        pointer.svg(),
    ]
    with open(path, "w") as f:
        f.write(document(WIDE, TITLE, "scripts/tour-winshot-display-animation.py", (S1, S2), tl.style(), screens,
                         captions(CAPTIONS, WIDE[0], WIDE_CAPTION_Y), stands=((S2, SIDE_STAND_FLOOR),), fluid=True))


if __name__ == "__main__":
    build(sys.argv[1])
