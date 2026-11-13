#!/usr/bin/env python3
"""Generates Resources/Tour/destination.svg, the scene on the Welcome chapter's destination page.

One loop: Mail fills the display's left zone, and the right column holds two empty zones, the top one the
destination, marked by its glow and the bar above it. A label names Mail's Reply button, and clicking it opens
the reply in the destination. The destination then moves to the other empty zone, which flashes, and the reply
to the next message opens there. With every zone full there is no destination, so the reply to a third message
floats above the tiles. Finally the whole picture fades out and back in on the opening arrangement, so the loop
restarts where it began.

Usage: python3 scripts/tour-destination-animation.py Resources/Tour/destination.svg
"""
import sys

from animation_common import (MAIL_ROW_H, ZBLUE, Timeline, mail_button, mail_list_width, mail_row_center, n, opacity,
                              placeholder, rect, toolbar_glyph)
from tour_common import (FLOATING, LEFT, RESTART_COVER, RIGHT, Pointer, arriving, arriving_window, bottom_half,
                         destination_indicator, label, new_zone_bar, shown, top_half, window, write_scene)

DUR = 10.6  # loop length, seconds
T_STILL = .8  # frame shown where CSS animations don't run: the opening arrangement, the top zone glowing
TITLE = (
    "The destination zone in Zonogy. One empty zone is the destination, marked by a glow: replying to an email "
    "in Mail opens the reply there. The destination then moves to another empty zone, where the next reply "
    "opens. When every zone is full, a new window floats above the tiles."
)
CAPTIONS = (  # (text, shown from, fading out at)
    ("Any new window, like an email reply, opens in the destination zone", .3, 3.0),
    ("The destination then moves to another empty zone", 3.3, 5.9),
    ("When every zone is full, new windows open in the floating zone", 6.2, 9.3),
)

TOP, BOTTOM = top_half(RIGHT), bottom_half(RIGHT)  # the empty zones; the top one is the destination at first
REPLY = mail_button(LEFT, "reply")
FIRST, SECOND, THIRD = 2.1, 5.35, 7.75  # Reply clicks, each answering the next message in the list
NEXT_MESSAGES = (4.55, 6.95)  # clicks on the second and third messages
GROWN = .65  # from a Reply click until its window has opened
RESTART = 9.7  # the picture is covered from here, and returns to its opening arrangement (see write_scene)
OPENING = RESTART + RESTART_COVER / 2  # when it does, unseen
REST = (LEFT[0] + 300, LEFT[1] + 300)  # pointer rest point, on the open message


def reply_button():
    """Mail's Reply button, drawn over its dimmed toolbar, and lit while the pointer is on it."""
    x, y = REPLY
    lit = '<g class="hover">' + rect(x - 14, y - 10, 28, 20, 6, fill=ZBLUE, fill_opacity=".3") + "</g>"
    return lit + toolbar_glyph("reply", REPLY, "#1f2633", 1.9)


def build(path):
    tl = Timeline(DUR, T_STILL)
    pointer = Pointer(tl, REST)
    pointer.move(1.2, 1.9, REPLY)
    pointer.click(FIRST)
    for i, (message, answer) in enumerate(zip(NEXT_MESSAGES, (SECOND, THIRD)), 1):
        pointer.move(message - .65, message - .15, mail_row_center(LEFT, i))
        pointer.click(message)
        pointer.move(message + .15, answer - .2, REPLY)
        pointer.click(answer)
    pointer.jump(OPENING, REST)
    pointer.tracks()

    # The Reply button lights up under the pointer, and the selection follows the messages clicked.
    hovering = ((1.85, 3.9), (5.1, 6.3), (7.5, OPENING - .1))
    tl.track("hover", [p for on, off in hovering for p in ((on, opacity(0)), (on + .1, opacity(1)), (off, opacity(1)),
                                                            (off + .1, opacity(0)))])
    row = lambda i: f"transform:translateY({n(i * MAIL_ROW_H)}px)"
    tl.track("sel", [(NEXT_MESSAGES[0], row(0)), (NEXT_MESSAGES[0] + .001, row(1)), (NEXT_MESSAGES[1], row(1)),
                     (NEXT_MESSAGES[1] + .001, row(2)), (OPENING, row(2)), (OPENING + .001, row(0))])

    # Each reply grows out of the Reply button into the destination: the top zone, then the bottom one, and
    # with every zone full, the floating zone.
    for cls, z, click in (("r1", TOP, FIRST), ("r2", BOTTOM, SECOND), ("r3", FLOATING, THIRD)):
        arriving(tl, cls, z, REPLY, click + .1, OPENING, .001)

    # Once a reply fills the destination, the destination moves on: to the bottom zone, which flashes, and
    # after that zone is filled too, to no tiling zone at all.
    moved, gone = FIRST + GROWN, SECOND + GROWN
    tl.track("t1", [(moved, opacity(1)), (moved + .2, opacity(0)), (OPENING, opacity(0)), (OPENING + .001, opacity(1))])
    tl.track("t2", [(moved, opacity(0)), (moved + .2, opacity(1)), (gone, opacity(1)), (gone + .2, opacity(0))])
    tl.track("flash", [(moved, opacity(0)), (moved + .1, opacity(1)), (moved + .45, opacity(0))])
    shown(tl, "replyname", .5, 1.5, .3, .3)

    x, y, w, h = BOTTOM
    sel_x, sel_y = LEFT[0] + 8, LEFT[1] + 51
    content = [
        window(LEFT, "mail"),
        '<g class="sel">' + rect(sel_x, sel_y, mail_list_width(LEFT[2]) - 4, MAIL_ROW_H - 2, 5, fill=ZBLUE,
                                 fill_opacity=".3") + "</g>",
        reply_button(),
        new_zone_bar("left"),
        placeholder("ph1", TOP, "t1"), f'<g class="t1">{destination_indicator(TOP)}</g>',
        placeholder("ph2", BOTTOM, "t2"), f'<g class="t2">{destination_indicator(BOTTOM)}</g>',
        '<g class="flash">' + rect(x, y, w, h, 8, fill=ZBLUE, fill_opacity=".3", stroke=ZBLUE, stroke_width="4") + "</g>",
        arriving_window("r1", TOP, "reply"), arriving_window("r2", BOTTOM, "reply"),
        arriving_window("r3", FLOATING, "reply", floating=True),
        label("replyname", "Reply", (REPLY[0] - 90, REPLY[1] + 62), (REPLY[0], REPLY[1] + 11)),
        pointer.svg(),
    ]
    write_scene(path, TITLE, "scripts/tour-destination-animation.py", tl, content, CAPTIONS, restart_at=RESTART)


if __name__ == "__main__":
    build(sys.argv[1])
