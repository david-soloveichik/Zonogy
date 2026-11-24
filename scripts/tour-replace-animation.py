#!/usr/bin/env python3
"""Generates Resources/Tour/replace.svg, the scene on the Welcome chapter's page about making an occupied zone the
destination.

One loop: Mail fills the display's left zone and two windows fill the right column, so no zone is empty. With the
modifier keys held, a click on the bottom-right window (the cap under the display shows it as, say, ⌃⌘-click)
makes its zone the destination: the zone flashes, then keeps its glow and the bar above it. Clicking Mail's Reply
button then opens the reply in that zone, and the window it replaces is minimized: it fades out in place, as in
the other scenes. Then the same on Mail itself: its zone becomes the destination, and the next reply takes Mail's
place. Finally the whole picture fades out and back in on the opening arrangement, so the loop restarts where it
began.

Usage: python3 scripts/tour-replace-animation.py Resources/Tour/replace.svg
"""
import sys

from animation_common import ZBLUE, Timeline, center, destination_glow, opacity, rect
from tour_common import (LEFT, REPLY, RESTART_COVER, RIGHT, Pointer, arriving, arriving_window, bottom_half,
                         destination_indicator, hidden, mail_selection, new_zone_bar, reply_button, shown, top_half,
                         window, write_scene)

DUR = 10.9  # loop length, seconds, before PAUSES lengthens its still stretches
T_STILL = 2.7  # frame shown where CSS animations don't run: the bottom-right zone, occupied, as the destination
TITLE = (
    "Making an occupied zone the destination in Zonogy. With every zone full, holding the modifier keys and "
    "clicking a window makes its zone the destination, marked by a glow. Replying to an email in Mail then opens "
    "the reply there, and the window it replaces is minimized. Doing the same on Mail itself makes the next reply "
    "take Mail's place."
)
CAPTIONS = (  # (text, shown from, fading out at)
    ("Hold the modifier keys and click a zone to make it the destination", .3, 3.4),
    ("The next window opens there, and the one it replaces is minimized", 3.7, 5.6),
    ("Do the same on Mail itself, and the reply takes Mail's place", 5.9, 9.6),
)
KEYS = (("{gesture click}", 88, "kclick"),)

OTHER = bottom_half(RIGHT)  # the first zone made the destination: another app's window
FIRST, SECOND = (2.1, 4.1), (6.4, 8.0)  # each example's modifier-click on a zone, then its click on Reply
GROWN = .65  # from a Reply click until the reply has opened
RESTART = 9.9  # the picture is covered from here, and returns to its opening arrangement (see write_scene)
OPENING = RESTART + RESTART_COVER / 2  # when it does, unseen
REST = (LEFT[0] + 300, LEFT[1] + 300)  # pointer rest point, on the open message


def replacing(tl, n, zone, occupant, times):
    """Example n: a modifier-click makes `zone` the destination (it flashes, then glows), and the reply opened by
    the click on Reply grows into it as the window there, of class `occupant`, is minimized."""
    click, answer = times
    tl.track(f"flash{n}", [(click, opacity(0)), (click + .1, opacity(1)), (click + .45, opacity(0))])
    shown(tl, f"tgt{n}", click + .05, answer + GROWN)
    arriving(tl, f"reply{n}", zone, REPLY, answer + .1, OPENING, .001)
    hidden(tl, occupant, answer + .15, OPENING, .3)


def destination_marks(n, zone):
    """Example n's glow and flash on `zone`, drawn over the window there."""
    x, y, w, h = zone
    glow = "\n".join([*destination_glow(zone), destination_indicator(zone)])
    flash = rect(x, y, w, h, 8, fill=ZBLUE, fill_opacity=".3", stroke=ZBLUE, stroke_width="4")
    return f'<g class="tgt{n}">\n{glow}\n</g>\n<g class="flash{n}">{flash}</g>'


def build(path):
    tl = Timeline(DUR, T_STILL)
    tl.key_presses("kclick", [(click - .12, click + .3) for click, _ in (FIRST, SECOND)])
    pointer = Pointer(tl, REST)
    for (click, answer), on in ((FIRST, center(OTHER)), (SECOND, REST)):
        pointer.move(click - 1.3, click - .6, on)
        pointer.click(click)
        pointer.move(answer - 1.2, answer - .4, REPLY)
        pointer.click(answer)
    pointer.jump(OPENING, REST)
    pointer.tracks()
    hovering = ((FIRST[1] - .45, SECOND[0] - 1.25), (SECOND[1] - .45, OPENING - .1))
    tl.track("hover", [p for on, off in hovering for p in ((on, opacity(0)), (on + .1, opacity(1)), (off, opacity(1)),
                                                            (off + .1, opacity(0)))])
    replacing(tl, 1, OTHER, "other", FIRST)
    replacing(tl, 2, LEFT, "mail", SECOND)

    content = [
        '<g class="mail">\n' + "\n".join([window(LEFT, "mail"), mail_selection(), reply_button()]) + "\n</g>",
        window(top_half(RIGHT), "blue"),
        f'<g class="other">\n{window(OTHER, "green")}\n</g>',
        new_zone_bar("left"),
        arriving_window("reply1", OTHER, "reply"), arriving_window("reply2", LEFT, "reply"),
        destination_marks(1, OTHER), destination_marks(2, LEFT),
        pointer.svg(),
    ]
    write_scene(path, TITLE, "scripts/tour-replace-animation.py", tl, content, CAPTIONS, restart_at=RESTART,
                keys=KEYS)


if __name__ == "__main__":
    build(sys.argv[1])
