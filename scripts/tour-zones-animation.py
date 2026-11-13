#!/usr/bin/env python3
"""Generates Resources/Tour/zones.svg, the scene on the Welcome chapter's Zones page.

One loop: two windows fill the display's two zones, and labels name the New Zone Bar on each side. Clicking
the left New Zone Bar splits that side: the window there keeps the top, and the new zone under
it is empty, so it shows a placeholder, is the destination, and has the Launcher open in it. That side now
holds two zones, so its bar is gone. Clicking the placeholder's × removes the zone again. Then an app is
dragged out of the Dock, slowly enough to read as a drag: the pointer presses on its icon and waits, a preview
follows it, every zone gets an overlay, and the right New Zone Bar lights up under the pointer.
Dropped there, the app's window opens in a new zone on that side, under the window that was there. Finally
the whole picture fades out and back in on the opening arrangement, so the loop restarts where it began.

Usage: python3 scripts/tour-zones-animation.py Resources/Tour/zones.svg
"""
import sys

from animation_common import (EIO, ZBLUE, Timeline, drag_pill, icon_center, launcher, opacity, overlays, placeholder,
                              rect, resizable_window)
from tour_common import (CONTENT_OPACITY, LEFT, NEW_ZONE_BARS, RESTART_COVER, RIGHT, S, Pointer, arriving,
                         arriving_window, bottom_half, destination_indicator, label, new_zone_bar, panel, shown,
                         top_half, write_scene)

DUR = 14.0  # loop length, seconds
T_STILL = 5.3  # frame shown where CSS animations don't run: the new zone, empty, with the Launcher open in it
TITLE = (
    "Zones in Zonogy. A bar on each side edge of the display adds a tiling zone there. A new zone is empty: it "
    "shows a placeholder, with the Launcher open in it to pick a window for it. Clicking the placeholder's close "
    "button removes the zone. Dragging an app from the Dock onto a bar opens its window in a new zone on that side."
)
CAPTIONS = (  # (text, shown from, fading out at)
    ("Click a New Zone Bar to add a zone", 2.8, 5.6),
    ("Click × on an empty zone to remove it", 5.9, 7.7),
    ("Or drag an app from the Dock onto a bar: it opens in a new zone", 8.0, 12.6),
)

ZONES = (LEFT, RIGHT)
NEW = bottom_half(LEFT)  # the empty zone added by a click, and removed
OPENED = bottom_half(RIGHT)  # the zone added by the drop, holding the dragged app's window
ROWS = (("green", 96, 52), ("amber", 116, 62), ("teal", 86, 48), ("pink", 104, 56))  # the Launcher's rows
ADD, REMOVE = 3.55, 6.65  # clicks: the left New Zone Bar, then ×
# The drag out of the Dock: the mouse goes down, sets off, arrives on the bar, and goes up.
PICKED_UP, SET_OFF, CARRIED, DROPPED = 8.35, 8.8, 10.4, 10.9
RESTART = 13.1  # the picture is covered from here, and returns to its opening arrangement (see write_scene)
OPENING = RESTART + RESTART_COVER / 2  # when it does, unseen
REST = (RIGHT[0] + 170, RIGHT[1] + 250)  # pointer rest point
_lx, _ly, _lw, _lh = NEW_ZONE_BARS["left"]
_rx, _ry, _rw, _rh = NEW_ZONE_BARS["right"]
LEFT_BAR = (_lx + _lw / 2, _ly + _lh / 2)
RIGHT_BAR = (_rx - 5, _ry + _rh / 2)  # just inside the bar, which widens under a drag, so the pointer stays in view
BAR_REACH = _rx + _rw - 12  # where a dragged pointer comes onto that widened bar
CLOSE = (NEW[0] + 20, NEW[1] + 20)  # the placeholder's ×
DOCK_ICON = icon_center(S, "green")


def lit_bar():
    """The right New Zone Bar while something is dragged over it: wider, and in the highlight color."""
    return '<g class="lit">' + rect(BAR_REACH, _ry, 12, _rh, 6, fill=ZBLUE, fill_opacity=".6", stroke=ZBLUE,
                                    stroke_width="1.2") + "</g>"


def build(path):
    tl = Timeline(DUR, T_STILL)
    pointer = Pointer(tl, REST)
    pointer.move(2.7, 3.4, LEFT_BAR)
    pointer.click(ADD)
    pointer.move(4.2, 4.8, (NEW[0] + 44, NEW[1] + NEW[3] - 56))  # aside, clear of the new zone's ×
    pointer.move(5.9, 6.5, CLOSE)
    pointer.click(REMOVE)
    pointer.move(7.4, 8.1, DOCK_ICON)
    pointer.press(PICKED_UP)
    pointer.move(SET_OFF, CARRIED, RIGHT_BAR)
    pointer.release(DROPPED)
    pointer.jump(OPENING, REST)
    pointer.tracks()

    # A window gives up its lower half to a new zone under it: the left one for the zone added by the click,
    # and it takes the half back when that zone is removed; the right one for the zone added by the drop,
    # until the picture restarts.
    def halving(cls, z, start, end, restarting=False):
        whole, halved = "transform:scaleY(1)", f"transform:scaleY({top_half(z)[3] / z[3]:.4f})"
        back = [(end, halved), (end + .001, whole)] if restarting else [(end + .1, halved, EIO), (end + .5, whole)]
        tl.track(cls, [(start + .05, whole, EIO), (start + .45, halved)] + back, origin=(0, z[1]))

    # A side holding two zones can take no more, so its New Zone Bar goes while the new zone is there.
    def bar_gone(cls, start, end, restarting=False):
        back = [(end, opacity(0)), (end + .001, opacity(1))] if restarting else [(end + .3, opacity(0)), (end + .5, opacity(1))]
        tl.track(cls, [(start + .05, opacity(1)), (start + .25, opacity(0))] + back)

    halving("split", LEFT, ADD, REMOVE)
    bar_gone("nzbar", ADD, REMOVE)
    shown(tl, "empty", ADD + .2, REMOVE + .05)
    panel(tl, "lc", NEW, ADD + .4, REMOVE + .03)
    shown(tl, "barname", .5, 2.6, .3, .3)
    shown(tl, "emptyname", ADD + 1.0, REMOVE - .9, .3, .3)

    # The drag out of the Dock: a preview follows the pointer, every zone gets a faint overlay, and the zone
    # or the bar under the pointer lights up.
    times = [t / 500 for t in range(int(SET_OFF * 500), int(CARRIED * 500) + 1)]
    over_zone = next(t for t in times if pointer.at(t)[1] <= RIGHT[1] + RIGHT[3])
    over_bar = next(t for t in times if pointer.at(t)[0] >= BAR_REACH)
    shown(tl, "pill", PICKED_UP + .05, DROPPED, .1, .1)
    shown(tl, "ov", PICKED_UP + .05, DROPPED + .05, .15, .2)
    shown(tl, "hot1", over_zone, over_bar, .08, .08)
    tl.track("hot0", [(0, opacity(0))])
    shown(tl, "lit", over_bar, DROPPED + .05, .08, .15)

    # Dropped on the bar, the app's window opens in a new zone on that side.
    halving("splitr", RIGHT, DROPPED, OPENING, restarting=True)
    bar_gone("nzbarr", DROPPED, OPENING, restarting=True)
    arriving(tl, "opened", OPENED, RIGHT_BAR, DROPPED + .05, OPENING, .001)
    tl.css.append(".split rect,.splitr rect{vector-effect:non-scaling-stroke}")

    mid = NEW[1] + NEW[3] / 2
    content = [
        resizable_window(LEFT, "purple", "split", "", CONTENT_OPACITY),
        resizable_window(RIGHT, "blue", "splitr", "", CONTENT_OPACITY),
        arriving_window("opened", OPENED, "green"),
        new_zone_bar("left", "nzbar"), new_zone_bar("right", "nzbarr"),
        f'<g class="empty">\n{placeholder("ph", NEW)}\n{destination_indicator(NEW)}\n</g>',
        launcher("lc", NEW, ROWS),
        overlays(ZONES), lit_bar(),
        label("barname", "New Zone Bar", (LEFT_BAR[0] + 150, LEFT_BAR[1] - 70), LEFT_BAR),
        label("barname", "New Zone Bar", (_rx + _rw / 2 - 150, LEFT_BAR[1] - 70), (_rx + _rw / 2, _ry + _rh / 2)),
        label("emptyname", "Empty zone", (NEW[0] + NEW[2] + 112, mid), (NEW[0] + NEW[2] - 10, mid)),
        # The preview is drawn larger than life, and up and to the left of the pointer, so that it stays in
        # view both at the Dock and at the display's edge.
        pointer.svg(carrying=f'<g transform="translate(-162,-46) scale(1.2)">{drag_pill(92)}</g>'),
    ]
    write_scene(path, TITLE, "scripts/tour-zones-animation.py", tl, content, CAPTIONS, restart_at=RESTART)


if __name__ == "__main__":
    build(sys.argv[1])
