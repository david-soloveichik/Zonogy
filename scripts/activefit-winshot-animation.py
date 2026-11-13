#!/usr/bin/env python3
"""Generates docs/images/activefit-winshot-animation.svg, the README's ActiveFit and WinShot animation: one
display, with captions.

One loop. ActiveFit first: the top-right browser can't shrink to its narrow zone, so at rest it runs off the
display's edge; clicking it slides it into view over its neighbor, and clicking the editor sends it back.
Then WinShot, with snapshots saved automatically: Control-Command-Tab opens the chooser, a timeline of
saved arrangements that starts on the previous one; a second Tab moves to an older arrangement, and
releasing the keys restores it, zones and windows. A window that the current arrangement shares with it
moves to its zone there. Control-Command-Tab and release then switch back, like Command-Tab, ending on
the opening frame.

Usage: python3 scripts/activefit-winshot-animation.py docs/images/activefit-winshot-animation.svg
       python3 scripts/activefit-winshot-animation.py Resources/Tour/winshot-switching.svg --tour
The second writes the WinShot tour's first scene: the WinShot half alone, on the tour's canvas. It shows no
keys, because the tour's own text names them by their current bindings.
"""
import sys

import tour_common

from animation_common import (CURSOR, EIO, EOUT, FRAME, GAP, MARGIN, Timeline, at, captions, center,
                              chooser, chooser_layout, columns, dock, dock_origin, document, editor_lines,
                              full_window, keycaps, menubar, n, opacity, ripple, scale, thumbnail_defs, wallpapers,
                              window_parts, zone_frames)

TOUR = "--tour" in sys.argv
DUR = 9.2 if TOUR else 14.0  # loop length, seconds
T_STILL = 2.8 if TOUR else 7.8  # frame shown where CSS animations don't run: the chooser open on the older arrangement
# The README fits its canvas to the page's width: 1333 rather than 1000 shows it at three quarters.
W, H = (tour_common.W, tour_common.H) if TOUR else (1333, 746)
TITLE = (
    "WinShot snapshots in Zonogy. The chooser shows a timeline of saved window arrangements, most recent first. "
    "Restoring one brings back its zones and its windows. The same window can be part of several arrangements."
) if TOUR else (
    "ActiveFit and WinShot snapshots in Zonogy. A window too wide for its zone slides into view while focused, and "
    "back when another window is focused. Window arrangements are saved automatically. Holding Control-Command and "
    "tapping Tab shows a timeline of saved window arrangements; releasing the keys restores the selected one, zones "
    "and windows. The same window can be part of several window arrangements."
)
CAPTIONS = (  # (text, shown from, fading out at)
    ("The chooser shows saved arrangements, most recent first", 0.9, 3.1),
    ("Restoring one brings back its zones and its windows", 3.4, 5.3),
    ("A window can be part of several arrangements", 5.5, 8.3),
) if TOUR else (
    ("A window too wide for its zone slides into view while focused", 0.3, 4.1),
    ("Window arrangements are saved automatically", 4.3, 5.7),
    ("Hold ⌃⌘, tap Tab to choose, release to restore", 5.95, 8.4),
    ("A window can be in several window arrangements", 8.6, 11.0),
)

S = tour_common.S if TOUR else ((W - 860) / 2, 54, 860, 538)  # the display's screen
KEYS_Y = S[1] + S[3] + FRAME + 16  # keycaps, under the display
CAPTION_Y = tour_common.CAPTION_Y if TOUR else KEYS_Y + 34 + 50

_top, _h, _cw, (_left, _) = columns(S, dock_origin(S)[1] - GAP)
FULL = (_left, _top, 2 * _cw + GAP, _h)  # the zone area
FLOAT = (center(FULL)[0] - 190, center(FULL)[1] - 125, 380, 250)

NOW, EARLIER, OLDER = (zone_frames(FULL, .64, None, .5), zone_frames(FULL, .62),
                       zone_frames(FULL, .4, .58, .45))  # zones resized unevenly
# The browser is too wide for its zone now: at rest it is anchored to the zone and runs off the display's edge;
# while focused, ActiveFit shifts it left just enough to show all of it. (In the tour's scene it fits.)
B_REST = NOW[1] if TOUR else (NOW[1][0], NOW[1][1], 430, NOW[1][3])
FIT_SHIFT = S[0] + S[2] - MARGIN - B_REST[2] - B_REST[0]
ARRANGEMENTS = {  # windows in zone order: (app, frame, floating?)
    "now": (("purple", NOW[0], False), ("blue", B_REST, False), ("orange", NOW[2], False)),
    "earlier": (("green", EARLIER[0], False), ("pink", EARLIER[1], False)),
    "older": (("teal", OLDER[0], False), ("amber", OLDER[1], False), ("purple", OLDER[2], False),
              ("green", OLDER[3], False)),
    "oldest": (("blue", FULL, False), ("pink", FLOAT, True)),
}
SESSIONS = (  # each ⌃⌘Tab: the chooser's arrangements, newest first, and the timeline gaps between them
    (("now", "earlier", "older", "oldest"), (22, 56, 86)),
    (("older", "now", "earlier", "oldest"), (16, 56, 86)),
)
KEYS = (("⌃", 46, "kmod"), ("⌘", 46, "kmod"), ("Tab", 64, "ktab"))


# ---------------------------------------------------------------- motion

TL = Timeline(DUR, T_STILL)
REST, CLICK_B = (S[0] + 190, 420), (S[0] + 720, 200)  # pointer: rest point on the editor (below the chooser), and on the browser
CLICKS, FIT = (1.3, 3.6), (1.35, 3.65)  # clicks on the browser, then the editor; the browser slides in, then back
WS = -1.0 if TOUR else 4.0  # WinShot starts (its first second and a half are idle)
TAPS = tuple(WS + t for t in (2.1, 3.3, 7.55))  # Tab presses; Control-Command is held around them
HELD = ((WS + 1.9, WS + 4.2), (WS + 7.35, WS + 8.45))
R1, R2 = WS + 4.25, WS + 8.5  # restores: the older arrangement, then back to the opening one
SHARED_FROM, SHARED_TO = NOW[0], OLDER[2]  # the purple window, in both arrangements


def motion():
    if not TOUR:
        # ActiveFit: the pointer clicks the browser, which slides left into full view over the editor; clicking the
        # editor sends it back to rest.
        TL.track("cur", [(.5, at(*REST), EIO), (1.2, at(*CLICK_B)), (2.9, at(*CLICK_B), EIO), (3.5, at(*REST))])
        TL.track("press", sum(([(t, scale(1)), (t + .07, scale(.86)), (t + .19, scale(1))] for t in CLICKS), []),
                 origin=(0, 0))
        TL.ripple("rpB", CLICKS[0] + .03, CLICK_B)
        TL.ripple("rpP", CLICKS[1] + .03, REST)
        rest, revealed = "transform:translateX(0px)", f"transform:translateX({n(FIT_SHIFT)}px)"
        TL.track("bfit", [(FIT[0], rest, EIO), (FIT[0] + .4, revealed), (FIT[1], revealed, EIO), (FIT[1] + .4, rest)])

        TL.track("keys", [p for t0, t1 in HELD for p in ((t0 - .15, opacity(0)), (t0, opacity(1)), (t1 + .2, opacity(1)),
                                                         (t1 + .4, opacity(0)))])
        TL.key_presses("kmod", HELD)
        TL.key_presses("ktab", [(t, t + .14) for t in TAPS])

    # The chooser opens on the first Tab, starting on the arrangement before the current one, and closes on release.
    hidden, shown = opacity(0, scale(.97)), opacity(1, scale(1))
    for i, (opened, released) in enumerate(((TAPS[0], HELD[0][1]), (TAPS[2], HELD[1][1])), 1):
        TL.track(f"ch{i}", [(opened + .05, hidden, EOUT), (opened + .2, shown), (released, shown),
                            (released + .12, opacity(0, scale(1)))], origin=center(S))
    _, xs = chooser_layout(S, *SESSIONS[0])
    TL.track("ch1sel", [(TAPS[1] + .02, "transform:translateX(0px)", EIO),
                        (TAPS[1] + .15, f"transform:translateX({n(xs[2] - xs[1])}px)"),
                        (HELD[0][1] + .3, f"transform:translateX({n(xs[2] - xs[1])}px)"),
                        (HELD[0][1] + .301, "transform:translateX(0px)")])

    # Restoring swaps in the arrangement's zones and windows with a quick crossfade (lingering, the outgoing
    # windows would show through the gaps between the new zones). The shared window instead moves into its
    # zone there: its body stretches to the zone, its title bar only widens, and its traffic lights slide along.
    TL.track("nowonly", [(R1, opacity(1)), (R1 + .12, opacity(0)), (R2, opacity(0)), (R2 + .12, opacity(1))])
    # The browser returns once the shared window has left its zone, so the window doesn't slide under it.
    TL.track("bfade", [(R1, opacity(1)), (R1 + .12, opacity(0)), (R2 + .3, opacity(0)), (R2 + .42, opacity(1))])
    TL.track("olderonly", [(R1, opacity(0)), (R1 + .12, opacity(1)), (R2, opacity(1)), (R2 + .12, opacity(0))])
    dx, sx, sy = SHARED_TO[0] - SHARED_FROM[0], SHARED_TO[2] / SHARED_FROM[2], SHARED_TO[3] / SHARED_FROM[3]
    for cls, moved in (("pbody", f"transform:translate({n(dx)}px,0px) scale({sx:.4f},{sy:.4f})"),
                       ("pband", f"transform:translate({n(dx)}px,0px) scale({sx:.4f},1)"),
                       ("plights", f"transform:translate({n(dx)}px,0px) scale(1,1)")):
        home = "transform:translate(0px,0px) scale(1,1)"
        TL.track(cls, [(R1, home, EIO), (R1 + .45, moved), (R2, moved, EIO), (R2 + .45, home)],
                 origin=SHARED_FROM[:2])
    TL.css.append(".pbody rect{vector-effect:non-scaling-stroke}")
    # Its content doesn't stretch: code lines that won't fit the shorter zone fade out as it shrinks, and back in.
    TL.track("pmore", [(R1, opacity(1)), (R1 + .15, opacity(0)), (R2 + .3, opacity(0)), (R2 + .45, opacity(1))])

    TL.captions(CAPTIONS)


def build():
    motion()
    body, band, lights, outline = window_parts(SHARED_FROM, "purple")
    lines, kept = editor_lines(*SHARED_FROM), len(editor_lines(*SHARED_TO))
    only = lambda key, skip: "\n".join(full_window(z, app) for app, z, _ in ARRANGEMENTS[key] if app not in skip)
    screen = [
        thumbnail_defs(ARRANGEMENTS, FULL), wallpapers((S,)), menubar(S),
        f'<g class="olderonly">\n{only("older", ("purple",))}\n</g>',
        f'<g class="nowonly">\n{only("now", ("purple", "blue"))}\n</g>',
        f'<g class="pbody">\n{body}\n{outline}\n</g>', f'<g class="pband">\n{band}\n</g>',
        f'<g class="plights">\n{lights}\n' + "\n".join(lines[:kept]) + "\n</g>",
        '<g class="plights"><g class="pmore">\n' + "\n".join(lines[kept:]) + "\n</g></g>",
        f'<g class="bfade"><g class="bfit">\n{full_window(B_REST, "blue")}\n</g></g>',
        dock(S),
        *([tour_common.floating_zone_bar()] if TOUR else []),
        *(chooser(f"ch{i}", S, order, gaps, 1) for i, (order, gaps) in enumerate(SESSIONS, 1)),
    ]
    if TOUR:  # no pointer and no keys: the chooser is worked from the keyboard, and the tour's text names the keys
        return document((W, H), TITLE, "scripts/activefit-winshot-animation.py", (S,), TL.style(), screen,
                        captions(CAPTIONS, W, CAPTION_Y), fluid=True)
    screen += [ripple("rpB", CLICK_B), ripple("rpP", REST), f'<g class="cur"><g class="press">{CURSOR}</g></g>']
    return document((W, H), TITLE, "scripts/activefit-winshot-animation.py", (S,), TL.style(), screen,
                    keycaps(KEYS, W / 2, KEYS_Y) + "\n" + captions(CAPTIONS, W, CAPTION_Y))


if __name__ == "__main__":
    with open(sys.argv[1], "w") as f:
        f.write(build())
