#!/usr/bin/env python3
"""Generates Resources/Tour/finding.svg, the scene on the Welcome chapter's Finding windows page.

One loop, two ways to bring a minimized window back into the empty bottom-right zone, the destination. First
CmdTab opens there: it lists windows, most recent first, starting on the one used before the current one; the
selection steps to the next, a minimized window, which fills the zone when CmdTab closes. The zone then
empties again (a cut, not a behavior). Second, hovering over a Dock icon opens its DockMenu, and the window
clicked there fills the zone. A last cut empties the zone, so the loop restarts where it began.

Usage: python3 scripts/tour-finding-animation.py Resources/Tour/finding.svg
"""
import sys

from animation_common import (DM_ROW_H, EIO, EOUT, LW, ROW_H, ZBLUE, Timeline, bar, dockmenu, dockmenu_origin,
                              icon_center, n, opacity, placeholder, rect)
from tour_common import (LEFT, RIGHT, S, Pointer, arriving, arriving_window, bottom_half, destination_indicator,
                         new_zone_bar, panel, top_half, window, write_scene)

DUR = 10.4  # loop length, seconds
T_STILL = 1.3  # frame shown where CSS animations don't run: CmdTab open in the empty zone
TITLE = (
    "Finding windows in Zonogy. CmdTab lists windows, most recent first, and the one chosen fills the empty "
    "destination zone. Hovering over a Dock icon lists that app's windows, and the one clicked fills the zone."
)
CAPTIONS = (  # (text, shown from, fading out at)
    ("CmdTab switches between windows, most recent first", .5, 4.1),
    ("Or hover over a Dock icon and pick one of its windows", 5.2, 8.8),
)

ZONE = bottom_half(RIGHT)  # the empty zone, the destination
WINDOWS = (("purple", 104, True), ("blue", 122, True), ("teal", 92, False), ("green", 112, False))  # CmdTab's
#   rows, most recent first: (app, title width, in a zone?). The third is chosen.
CT_H = 34 + len(WINDOWS) * ROW_H + 8  # CmdTab: a header over its rows
CT = (ZONE[0] + (ZONE[2] - LW) / 2, ZONE[1] + (ZONE[3] - CT_H) / 2)
DM = dockmenu_origin(S, "pink")
DM_ROWS = (118, 96, 130)  # title widths; the second is the window clicked
OPENED, STEP, CHOSEN, CUT1 = .9, 1.7, 2.6, 4.5  # CmdTab opens, steps, closes on a window; that window goes
PICK, CUT2 = 6.9, 9.2  # the click in the DockMenu; that window goes
REST = (LEFT[0] + 250, LEFT[1] + 280)  # pointer rest point
DOCK_ICON = icon_center(S, "pink")
DM_ROW2 = (DM[0] + 95, DM[1] + 44 + 1.5 * DM_ROW_H)


def row_y(i):
    return CT[1] + 34 + (ROW_H - 4) / 2 + i * ROW_H


def cmdtab():
    """CmdTab: a title over the windows, each with its app's icon, and a window glyph if it is in a zone."""
    x, y = CT
    s = ['<g class="ct">',
         rect(x, y, LW, CT_H, 12, fill="#f5f6f9", fill_opacity=".97", filter="url(#shadow)"),
         rect(x + .5, y + .5, LW - 1, CT_H - 1, 11.5, fill="none", stroke="#fff", stroke_opacity=".8"),
         bar(x + 16, y + 12.5, 92, 6.5, "#3f4757", .75),
         f'<path d="M{n(x + 10)} {n(y + 29.5)}H{n(x + LW - 10)}" stroke="#d5d9e1"/>',
         '<g class="ctsel">' + rect(x + 7, y + 34, LW - 14, ROW_H - 4, 7, fill=ZBLUE, fill_opacity=".2", stroke=ZBLUE,
                                    stroke_opacity=".6") + "</g>"]
    for i, (app, w, zoned) in enumerate(WINDOWS):
        cy = row_y(i)
        s.append(f'<use href="#ic-{app}" x="{n(x + 16)}" y="{n(cy - 10)}" width="20" height="20"/>'
                 + bar(x + 46, cy - 3, w, 6, "#4d5566", .6))
        if zoned:
            s.append(rect(x + LW - 31, cy - 4.5, 12, 9, 2, fill="none", stroke="#8a93a3", stroke_width="1.3")
                     + f'<path d="M{n(x + LW - 31)} {n(cy - 1.5)}h12" stroke="#8a93a3" stroke-width="1.3"/>')
    s.append("</g>")
    return "\n".join(s)


def build(path):
    tl = Timeline(DUR, T_STILL)
    pointer = Pointer(tl, REST)
    pointer.move(5.1, 5.9, DOCK_ICON)
    pointer.move(6.3, 6.65, DM_ROW2)
    pointer.click(PICK)
    pointer.move(9.0, 9.8, REST)
    pointer.tracks()

    # CmdTab opens on the window used before the current one, steps to the next, and closes on it.
    panel(tl, "ct", ZONE, OPENED, CHOSEN)
    on = lambda i: f"transform:translateY({i * ROW_H}px)"
    tl.track("ctsel", [(STEP, on(1), EIO), (STEP + .12, on(2)), (CHOSEN + .3, on(2)), (CHOSEN + .301, on(1))])
    arriving(tl, "chosen", ZONE, (CT[0] + 26, row_y(2)), CHOSEN + .05, CUT1, .25)

    # The DockMenu opens while the pointer rests on the Dock icon, and closes on the click.
    low, up = "transform:translateY(5px)", "transform:translateY(0px)"
    tl.track("dm", [(5.95, opacity(0, low), EOUT), (6.15, opacity(1, up)), (PICK + .05, opacity(1, up)),
                    (PICK + .15, opacity(0, up)), (PICK + .23, opacity(0, low))])
    tl.track("dmrow", [(6.58, opacity(0)), (6.66, opacity(1)), (PICK + .23, opacity(1)), (PICK + .231, opacity(0))])
    arriving(tl, "picked", ZONE, DM_ROW2, PICK + .05, CUT2, .25)

    # The zone is empty, showing its placeholder, except while either window is in it.
    tl.track("empty", [(CHOSEN + .2, opacity(1)), (CHOSEN + .45, opacity(0)), (CUT1 + .1, opacity(0)),
                       (CUT1 + .35, opacity(1)), (PICK + .2, opacity(1)), (PICK + .45, opacity(0)),
                       (CUT2 + .1, opacity(0)), (CUT2 + .35, opacity(1))])

    content = [
        window(LEFT, "purple"), window(top_half(RIGHT), "blue"), new_zone_bar("left"),
        f'<g class="empty">\n{placeholder("ph", ZONE)}\n{destination_indicator(ZONE)}\n</g>',
        arriving_window("chosen", ZONE, "teal"), arriving_window("picked", ZONE, "pink"),
        cmdtab(), dockmenu(DM, "pink", DM_ROWS, 1),
        pointer.svg(),
    ]
    write_scene(path, TITLE, "scripts/tour-finding-animation.py", tl, content, CAPTIONS)


if __name__ == "__main__":
    build(sys.argv[1])
