#!/usr/bin/env python3
"""Generates Resources/Tour/moving.svg, the scene on the Welcome chapter's Moving and resizing page.

One loop: three windows fill the display's three zones. The top-right window is dragged by its title bar onto
the zone below: every zone gets an overlay, the one under the pointer lights up, and on the drop the two
windows swap. Then the bar between the columns, which shows while the pointer is over the gap, is dragged
right, and the windows follow their zones as they resize, except the bottom-right one, which can't shrink: it
keeps its width and runs off the display's edge. Clicking it slides it fully into view over its neighbor
(ActiveFit), and clicking the left window sends it back. Finally the whole picture fades out and back in on the
opening arrangement, so the loop restarts where it began.

Usage: python3 scripts/tour-moving-animation.py Resources/Tour/moving.svg
"""
import sys

from animation_common import (EIO, EOUT, Timeline, at, n, opacity, overlays, resizable_window, resize_bar,
                              window_content, window_parts)
from tour_common import (BAR_X, CONTENT_OPACITY, LEFT, RESTART_COVER, RIGHT, Pointer, bottom_half, new_zone_bar,
                         shown, top_half, write_scene)

DUR = 11.0  # loop length, seconds, before PAUSES lengthens its still stretches
T_STILL = 3.3  # frame shown where CSS animations don't run: the two windows, swapped
TITLE = (
    "Moving and resizing in Zonogy. Dragging a window onto another zone moves it there, and the window in that "
    "zone takes its place. Dragging the bar between two zones resizes them, and their windows follow. A window "
    "that can't shrink to its zone runs off the display's edge, and slides fully into view while it is in use."
)
CAPTIONS = (  # (text, shown from, fading out at)
    ("Drag a window onto another zone: the two windows swap", .8, 3.6),
    ("Drag the bar between zones to resize them", 3.9, 6.1),
    ("A window too big for its zone slides into view while you use it", 6.4, 9.6),
)

TOP, BOTTOM = top_half(RIGHT), bottom_half(RIGHT)
ZONES = (LEFT, TOP, BOTTOM)
SWAP = BOTTOM[1] - TOP[1]  # how far the two windows move to trade zones
GRAB = (TOP[0] + 190, TOP[1] + 11)  # on the top-right window's title bar
DROP = (GRAB[0] + 14, BOTTOM[1] + 16)  # just inside the zone below, so the carried window stays clear of the Dock
PICKED_UP, CARRIED, DROPPED = 1.45, 2.4, 2.6  # the window drag: the mouse goes down, arrives, and goes up
RESIZE_DX = 110  # the drag of the bar between the columns, narrowing the right column
BAR = (BAR_X, LEFT[1] + LEFT[3] / 2)  # where the pointer grabs that bar
HOVER, RESIZE = 4.45, (4.8, 5.5)  # the bar shows; then its drag starts and ends
REVEAL, REST_AGAIN = 6.75, 8.75  # clicks: the window that ran off the edge, then the left window
RESTART = 9.9  # the picture is covered from here, and returns to its opening arrangement (see write_scene)
OPENING = RESTART + RESTART_COVER / 2  # when it does, unseen
REST = (LEFT[0] + 250, LEFT[1] + 300)  # pointer rest point


def right_window(z, app, move_cls, fit_cls=None):
    """A window of the right column that trades zones (`move_cls`). Given `fit_cls`, it can't shrink: it slides
    whole with its zone's left edge (that class). Otherwise, like resizable_window, it stretches with the column
    while its traffic lights slide along."""
    body, band, lights, outline = window_parts(z, app)
    inner = lambda parts: f'<g class="{move_cls}">\n' + "\n".join(parts) + "\n</g>"
    if fit_cls:
        return f'<g class="{fit_cls}">{inner((body, band, window_content(z, app, CONTENT_OPACITY), lights, outline))}</g>'
    return (f'<g class="rzR">{inner((body, band, window_content(z, app, CONTENT_OPACITY), outline))}</g>\n'
            f'<g class="rzL">{inner((lights,))}</g>')


def crossing(pointer, y):
    """When the dragged pointer passes the height y on its way down."""
    return next(t / 500 for t in range(int(PICKED_UP * 500), int(CARRIED * 500) + 1) if pointer.at(t / 500)[1] >= y)


def build(path):
    tl = Timeline(DUR, T_STILL)
    pointer = Pointer(tl, REST)
    pointer.move(.5, 1.2, GRAB)
    pointer.press(PICKED_UP - .03)
    pointer.move(PICKED_UP, CARRIED, DROP)
    pointer.release(DROPPED)
    pointer.move(3.8, HOVER, BAR)
    pointer.press(RESIZE[0] - .08)
    pointer.move(RESIZE[0], RESIZE[1], (BAR[0] + RESIZE_DX, BAR[1]))
    pointer.release(RESIZE[1] + .1)
    pointer.move(6.0, REVEAL - .15, (BOTTOM[0] + RESIZE_DX + 130, BOTTOM[1] + 110))  # on the overflowing window
    pointer.click(REVEAL)
    pointer.move(7.95, REST_AGAIN - .15, (LEFT[0] + 200, LEFT[1] + 250))  # on the left window, clear of it
    pointer.click(REST_AGAIN)
    pointer.jump(OPENING, REST)
    pointer.tracks()

    # The dragged window follows the pointer, and on the drop settles into the zone under it, while the window
    # that was there moves up into the zone it left.
    carried = at(DROP[0] - GRAB[0], DROP[1] - GRAB[1])
    tl.track("bmv", [(PICKED_UP, at(0, 0), EIO), (CARRIED, carried), (DROPPED, carried, EOUT), (DROPPED + .25, at(0, SWAP)),
                     (OPENING, at(0, SWAP)), (OPENING + .001, at(0, 0))])
    tl.track("omv", [(DROPPED, at(0, 0), EOUT), (DROPPED + .4, at(0, -SWAP)), (OPENING, at(0, -SWAP)),
                     (OPENING + .001, at(0, 0))])

    # Drag feedback: a faint overlay on every zone, and a brighter one on the zone under the pointer.
    shown(tl, "ov", PICKED_UP - .05, DROPPED + .05, .15, .2)
    left_top, entered_bottom = crossing(pointer, TOP[1] + TOP[3]), crossing(pointer, BOTTOM[1])
    shown(tl, "hot1", PICKED_UP - .05, left_top, .08, .08)
    shown(tl, "hot2", entered_bottom, DROPPED + .05, .08, .2)
    tl.track("hot0", [(0, opacity(0))])

    # The resize: the bar shows on hover and follows the drag. The left window stretches from its left edge, and
    # the top-right one shrinks from its right edge, with its traffic lights sliding along.
    def resized(cls, at_k, origin=None):
        tl.track(cls, [(RESIZE[0], at_k(0), EIO), (RESIZE[1], at_k(1)), (OPENING, at_k(1)), (OPENING + .001, at_k(0))],
                 origin=origin)

    resized("rzA", lambda k: f"transform:scaleX({(LEFT[2] + k * RESIZE_DX) / LEFT[2]:.4f})", (LEFT[0], 0))
    resized("rzR", lambda k: f"transform:scaleX({(TOP[2] - k * RESIZE_DX) / TOP[2]:.4f})", (TOP[0] + TOP[2], 0))
    resized("rzL", lambda k: f"transform:translateX({n(k * RESIZE_DX)}px)")
    tl.css.append(".rzA rect,.rzR rect{vector-effect:non-scaling-stroke}")
    slid = lambda o, k: opacity(o, f"transform:translateX({n(k * RESIZE_DX)}px)")
    tl.track("rbar", [(HOVER - .1, slid(0, 0)), (HOVER + .05, slid(1, 0)), (RESIZE[0], slid(1, 0), EIO),
                      (RESIZE[1], slid(1, 1)), (RESIZE[1] + .3, slid(1, 1)), (RESIZE[1] + .5, slid(0, 1)),
                      (OPENING, slid(0, 1)), (OPENING + .001, slid(0, 0))])

    # The bottom-right window can't shrink: it slides with its zone's left edge and runs off the display. While
    # it is the focused window, ActiveFit shifts it back left, over the left window, so all of it shows.
    home, shifted = "transform:translateX(0px)", f"transform:translateX({n(RESIZE_DX)}px)"
    tl.track("fit", [(RESIZE[0], home, EIO), (RESIZE[1], shifted), (REVEAL + .05, shifted, EIO), (REVEAL + .45, home),
                     (REST_AGAIN + .05, home, EIO), (REST_AGAIN + .45, shifted), (OPENING, shifted),
                     (OPENING + .001, home)])

    content = [
        resizable_window(LEFT, "purple", "rzA", "", CONTENT_OPACITY),
        right_window(BOTTOM, "orange", "omv"), overlays(ZONES), right_window(TOP, "blue", "bmv", "fit"),  # carried on top
        new_zone_bar("left"), resize_bar(BAR_X, LEFT[1], LEFT[3]),
        pointer.svg(),
    ]
    write_scene(path, TITLE, "scripts/tour-moving-animation.py", tl, content, CAPTIONS, restart_at=RESTART)


if __name__ == "__main__":
    build(sys.argv[1])
