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
With Reduce Motion on, browsers show the SVG's still frame; add --ignore-reduced-motion to write a
preview copy that always animates.
"""
import random
import sys

from animation_common import (CURSOR, EIO, EOUT, FONT, FRAME, GAP, MARGIN, ZBLUE, Timeline, at, bar, captions, center,
                              columns, dock, dock_origin, document, menubar, n, opacity, rect, ripple, scale,
                              wallpapers, window_parts)

DUR = 14.0  # loop length, seconds
T_STILL = 7.8  # frame shown when the viewer prefers reduced motion: the chooser open on the older arrangement
W, H = 1000, 740
TITLE = (
    "ActiveFit and WinShot snapshots in Zonogy. A window too wide for its zone slides into view while focused, and "
    "back when another window is focused. Window arrangements are saved automatically. Holding Control-Command and "
    "tapping Tab shows a timeline of saved window arrangements; releasing the keys restores the selected one, zones "
    "and windows. The same window can be part of several window arrangements."
)
CAPTIONS = (  # (text, shown from, fading out at)
    ("A window too wide for its zone slides into view while focused", 0.3, 4.1),
    ("Window arrangements are saved automatically", 4.3, 5.7),
    ("Hold ⌃⌘, tap Tab to choose, release to restore", 5.95, 8.4),
    ("A window can be in several window arrangements", 8.6, 11.0),
)

S = ((W - 860) / 2, 54, 860, 538)  # the display's screen
KEYS_Y = S[1] + S[3] + FRAME + 16  # keycaps, under the display
CAPTION_Y = KEYS_Y + 34 + 46

_top, _h, _cw, (_left, _) = columns(S, dock_origin(S)[1] - GAP)
FULL = (_left, _top, 2 * _cw + GAP, _h)  # the zone area
FLOAT = (center(FULL)[0] - 190, center(FULL)[1] - 125, 380, 250)


def zones(split, left_rows=None, right_rows=None):
    """Zone frames for two columns, left to right and top to bottom: `split` is the left column's share of the
    width, and a column given a share is split into a top and a bottom zone by it (zones can be resized)."""
    x, y, w, h = FULL

    def column(cx, cw, share):
        if share is None:
            return [(cx, y, cw, h)]
        top = (h - GAP) * share
        return [(cx, y, cw, top), (cx, y + top + GAP, cw, h - GAP - top)]

    lw = (w - GAP) * split
    return column(x, lw, left_rows) + column(x + lw + GAP, w - GAP - lw, right_rows)


NOW, EARLIER, OLDER = zones(.64, None, .5), zones(.62), zones(.4, .58, .45)  # zones resized unevenly
# The browser is too wide for its zone now: at rest it is anchored to the zone and runs off the display's edge;
# while focused, ActiveFit shifts it left just enough to show all of it.
B_REST = (NOW[1][0], NOW[1][1], 430, NOW[1][3])
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
TW, TH = 150, 94  # thumbnail
PANEL_H = 18 + TH + 9 + 16 + 4 + 16 + 14
KEYS = (("⌃", 46, "kmod"), ("⌘", 46, "kmod"), ("Tab", 64, "ktab"))


def chooser_layout(order, gaps):
    """The chooser panel (x, y, width) centered on the display, and each thumbnail's x."""
    width = len(order) * TW + sum(gaps) + 40
    px, py = center(S)[0] - width / 2, center(S)[1] - PANEL_H / 2
    return (px, py, width), [px + 20 + i * TW + sum(gaps[:i]) for i in range(len(order))]


# ---------------------------------------------------------------- shapes

def editor_lines(x, y, w, h):
    """Code, one string per line. Line i is the same whatever the window's size; a shorter window shows fewer."""
    rnd, lines, ly = random.Random(1), [], y + 36
    while ly + 6 <= y + h - 10:
        marks = [bar(x + 12, ly, 12, 5, "#fff", .2)]
        if rnd.random() > .12:
            xx = x + 34 + rnd.choice((0, 0, 1, 1, 2, 3)) * 18
            for _ in range(rnd.choice((1, 2, 2, 3))):
                ww = rnd.randint(22, 92)
                if xx + ww > x + 360:
                    break
                marks.append(bar(xx, ly, ww, 6, rnd.choice(("#c4b5fd", "#7dd3c0", "#fcd34d", "#e5e7eb", "#e5e7eb")), .75))
                xx += ww + 8
        lines.append("".join(marks))
        ly += 17
    return lines


def browser(x, y, w, h):
    """A web page: address field, a banner, and cards."""
    bh, count = min(70, (h - 40) * .32), 3 if w > 320 else 2
    cw, cy = (w - 24 - (count - 1) * 10) / count, y + 44 + min(70, (h - 40) * .32)
    ch = y + h - 12 - cy
    s = [rect(x + w * .3, y + 5, w * .4, 12, 6, fill="#fff", fill_opacity=".7"),
         rect(x + 12, y + 32, w - 24, bh, 6, fill="#2d7ff9", fill_opacity=".5"),
         bar(x + 26, y + 32 + bh * .3, min(150, w * .4), 9, "#fff", .9),
         bar(x + 26, y + 32 + bh * .3 + 16, min(100, w * .26), 6, "#fff", .7)]
    for i in range(count):
        cx = x + 12 + i * (cw + 10)
        s += [rect(cx, cy, cw, ch, 5, fill="#fff", fill_opacity=".6"),
              rect(cx + 8, cy + 8, cw - 16, ch * .45, 4, fill="#2d7ff9", fill_opacity=".2"),
              bar(cx + 8, cy + ch * .45 + 18, cw * .7, 6, "#5b6475", .5),
              bar(cx + 8, cy + ch * .45 + 30, cw * .5, 5, "#8b93a2", .45)]
    return s


def notes(x, y, w, h):
    """Notes: a list of notes beside the open one."""
    rnd, lw = random.Random(2), min(150, w * .34)
    s, yy = [rect(x + 6, y + 28, lw - 6, h - 34, 6, fill="#fff", fill_opacity=".25")], y + 36
    while yy + 24 <= y + h - 10:
        if yy == y + 36:
            s.append(rect(x + 10, yy - 5, lw - 14, 30, 5, fill="#f39c1d", fill_opacity=".28"))
        s += [f'<circle cx="{n(x + 20)}" cy="{n(yy + 5)}" r="3.5" fill="#f39c1d"/>',
              bar(x + 30, yy + 1.5, rnd.uniform(.45, .8) * (lw - 36), 6, "#5b6475", .55),
              bar(x + 30, yy + 12, rnd.uniform(.3, .65) * (lw - 36), 4.5, "#8b93a2", .5)]
        yy += 38
    tx, tw = x + lw + 16, w - lw - 32
    s.append(bar(tx, y + 36, min(180, tw * .7), 10, "#4d5566", .6))
    for yy in range(int(y + 60), int(y + h - 17), 13):
        s.append(bar(tx, yy, rnd.uniform(.55, 1) * tw, 5, "#8b93a2", .45))
    return s


def sheet(x, y, w, h):
    """A spreadsheet: toolbar, header row, cells, and a selected range."""
    rnd = random.Random(3)
    cols, rows = max(3, int((w - 16) / 60)), max(3, int((h - 58) / 22))
    gx, gy, gw, gh = x + 8, y + 50, w - 16, h - 58
    cw, rh = gw / cols, gh / rows
    s = [rect(x + 6, y + 27, w - 12, 16, 4, fill="#fff", fill_opacity=".35")]
    s += [rect(x + 12 + i * 20, y + 31, 12, 8, 2, fill="#5b6475", fill_opacity=".3") for i in range(min(8, int((w - 24) / 20)))]
    s.append(rect(gx, gy, gw, rh, fill="#1db45c", fill_opacity=".28"))
    for r in range(rows):
        for c in range(cols):
            if r == 0 or rnd.random() < .6:
                s.append(bar(gx + c * cw + 6, gy + r * rh + rh / 2 - 2.5, rnd.uniform(.3, .7) * cw, 5,
                             "#1db45c" if r == 0 else "#5b6475", .55 if r == 0 else .4))
    grid = "".join(f"M{n(gx)} {n(gy + r * rh)}H{n(gx + gw)}" for r in range(rows + 1))
    grid += "".join(f"M{n(gx + c * cw)} {n(gy)}V{n(gy + gh)}" for c in range(cols + 1))
    s += [f'<path d="{grid}" stroke="#fff" stroke-opacity=".7" stroke-width=".8" fill="none"/>',
          rect(gx + cw, gy + rh, 2 * cw, 2 * rh, fill="#1db45c", fill_opacity=".15", stroke="#1db45c", stroke_width="1.5")]
    return s


def calendar(x, y, w, h):
    """A calendar week: day columns with events."""
    rnd, days, gx, gy = random.Random(4), 5, x + 10, y + 52
    cw, rows = (w - 20) / days, int((h - 62) / 26)
    s = [bar(x + 12, y + 30, min(110, w * .3), 9, "#4d5566", .6)]
    s += [bar(gx + i * cw + 6, gy - 10, cw * .4, 5, "#5b6475", .5) for i in range(days)]
    grid = "".join(f"M{n(gx)} {n(gy + r * 26)}H{n(gx + days * cw)}" for r in range(rows + 1))
    grid += "".join(f"M{n(gx + i * cw)} {n(gy)}V{n(gy + rows * 26)}" for i in range(days + 1))
    s.append(f'<path d="{grid}" stroke="#5b6475" stroke-opacity=".18" fill="none"/>')
    for i in range(days):
        for _ in range(rnd.choice((1, 2))):
            span = rnd.choice((1, 1, 2))
            start = rnd.randint(0, max(0, rows - span))
            s.append(rect(gx + i * cw + 3, gy + start * 26 + 2, cw - 6, span * 26 - 4, 4,
                          fill=rnd.choice(("#e0a800", "#2d7ff9", "#e64590", "#1db45c")), fill_opacity=".45"))
    return s


def chat(x, y, w, h):
    """A conversation: message bubbles on both sides, and a message field."""
    rnd, s, yy, mine = random.Random(5), [], y + 34, False
    while True:
        bh = rnd.choice((22, 22, 34))
        if yy + bh > y + h - 44:
            break
        bw = rnd.uniform(.3, .62) * (w - 24)
        s.append(rect(x + w - 12 - bw if mine else x + 12, yy, bw, bh, 9, fill="#52d6cc" if mine else "#fff",
                      fill_opacity=".5" if mine else ".14"))
        yy += bh + 10
        mine = (not mine) if rnd.random() > .3 else mine
    s.append(rect(x + 10, y + h - 34, w - 20, 24, 12, fill="#fff", fill_opacity=".12"))
    return s


def photos(x, y, w, h):
    """A photo library: a grid of tiles."""
    rnd, size, gap = random.Random(6), 54, 6
    cols, rows = max(2, int((w - 20 + gap) / (size + gap))), max(1, int((h - 40 + gap) / (size + gap)))
    ox = x + (w - cols * size - (cols - 1) * gap) / 2
    return [rect(ox + c * (size + gap), y + 32 + r * (size + gap), size, size, 4, fill_opacity=".8",
                 fill=rnd.choice(("#f8a5c2", "#f7d794", "#a29bfe", "#81ecec", "#fab1a0", "#74b9ff")))
            for r in range(rows) for c in range(cols)]


CONTENT = {"purple": editor_lines, "blue": browser, "orange": notes, "green": sheet, "amber": calendar,
           "teal": chat, "pink": photos}


def full_window(z, app):
    """A window with abstract content for its app, laid out for the window's size."""
    body, band, lights, outline = window_parts(z, app)
    return "\n".join([body, band, *CONTENT[app](*z), lights, outline])


def thumbnail_defs():
    """Each snapshot as the chooser shows it, defined once at the origin: its windows, scaled down onto a plain
    background, with app icons underneath (tiling zones on top, the floating window below)."""
    k = min((TW - 10) / FULL[2], (TH - 10) / FULL[3])
    ox, oy = (TW - FULL[2] * k) / 2 - FULL[0] * k, (TH - FULL[3] * k) / 2 - FULL[1] * k
    s = ["<defs>", f'<clipPath id="thclip">{rect(0, 0, TW, TH, 6)}</clipPath>']
    for key, wins in ARRANGEMENTS.items():
        s += [f'<g id="th-{key}">', rect(0, 0, TW, TH, 6, fill="#dfe3ea"),
              f'<g clip-path="url(#thclip)"><g transform="translate({n(ox)},{n(oy)}) scale({k:.4f})">',
              *(full_window(frame, app) for app, frame, _ in wins), "</g></g>"]
        for row, floating in enumerate((False, True)):
            apps = [app for app, _, f in wins if f == floating]
            left = TW / 2 - (len(apps) * 20 - 4) / 2
            s += [f'<use href="#ic-{app}" x="{n(left + i * 20)}" y="{n(TH + 9 + row * 20)}" width="16" height="16"/>'
                  for i, app in enumerate(apps)]
        s.append("</g>")
    s.append("</defs>")
    return "\n".join(s)


def chooser(i, order, gaps, selected):
    (px, py, width), xs = chooser_layout(order, gaps)
    ty = py + 18
    return "\n".join([
        f'<g class="ch{i}">',
        rect(px, py, width, PANEL_H, 18, fill="#f5f6f9", fill_opacity=".95", filter="url(#shadow)"),
        rect(px + .5, py + .5, width - 1, PANEL_H - 1, 17.5, fill="none", stroke="#fff", stroke_opacity=".8"),
        *(f'<use href="#th-{key}" x="{n(x)}" y="{n(ty)}"/>' for x, key in zip(xs, order)),
        f'<g class="ch{i}sel">' + rect(xs[selected] - 4, ty - 4, TW + 8, TH + 8, 9, fill="none", stroke=ZBLUE,
                                       stroke_width="3") + "</g>",
        "</g>",
    ])


def keycaps():
    """The keys being pressed, drawn under the display: each cap sinks and turns blue while held."""
    total = sum(w for _, w, _ in KEYS) + 10 * (len(KEYS) - 1)
    x, s = W / 2 - total / 2, ['<g class="keys">']
    for label, w, cls in KEYS:
        size = 18 if len(label) == 1 else 14
        s += [rect(x, KEYS_Y + 3, w, 34, 7, fill="#0b0e15"),
              f'<g class="{cls}">' + rect(x, KEYS_Y, w, 34, 7, fill="#20263a", stroke="#3b4357")
              + f'<g class="{cls}hi">' + rect(x, KEYS_Y, w, 34, 7, fill=ZBLUE, fill_opacity=".6") + "</g>"
              + f'<text x="{n(x + w / 2)}" y="{n(KEYS_Y + 23)}" text-anchor="middle" font-family="{FONT}" '
                f'font-size="{size}" font-weight="500" fill="#e6eaf2">{label}</text></g>']
        x += w + 10
    s.append("</g>")
    return "\n".join(s)


# ---------------------------------------------------------------- motion

TL = Timeline(DUR, T_STILL)
REST, CLICK_B = (260, 420), (790, 200)  # pointer: rest point on the editor (below the chooser), and on the browser
CLICKS, FIT = (1.3, 3.6), (1.35, 3.65)  # clicks on the browser, then the editor; the browser slides in, then back
WS = 4.0  # WinShot starts
TAPS = tuple(WS + t for t in (2.1, 3.3, 7.55))  # Tab presses; Control-Command is held around them
HELD = ((WS + 1.9, WS + 4.2), (WS + 7.35, WS + 8.45))
R1, R2 = WS + 4.25, WS + 8.5  # restores: the older arrangement, then back to the opening one
SHARED_FROM, SHARED_TO = NOW[0], OLDER[2]  # the purple window, in both arrangements


def motion():
    # ActiveFit: the pointer clicks the browser, which slides left into full view over the editor; clicking the
    # editor sends it back to rest.
    TL.track("cur", [(.5, at(*REST), EIO), (1.2, at(*CLICK_B)), (2.9, at(*CLICK_B), EIO), (3.5, at(*REST))])
    TL.track("press", sum(([(t, scale(1)), (t + .07, scale(.86)), (t + .19, scale(1))] for t in CLICKS), []),
             origin=(0, 0))
    TL.ripple("rpB", CLICKS[0] + .03, CLICK_B)
    TL.ripple("rpP", CLICKS[1] + .03, REST)
    rest, revealed = "transform:translateX(0px)", f"transform:translateX({n(FIT_SHIFT)}px)"
    TL.track("bfit", [(FIT[0], rest, EIO), (FIT[0] + .4, revealed), (FIT[1], revealed, EIO), (FIT[1] + .4, rest)])

    down, up = "transform:translateY(2px)", "transform:translateY(0px)"
    press = lambda t0, t1, on, off: [(t0, off), (t0 + .06, on), (t1, on), (t1 + .06, off)]
    TL.track("keys", [p for t0, t1 in HELD for p in ((t0 - .15, opacity(0)), (t0, opacity(1)), (t1 + .2, opacity(1)),
                                                     (t1 + .4, opacity(0)))])
    for cls, spans in (("kmod", HELD), ("ktab", [(t, t + .14) for t in TAPS])):
        TL.track(cls, sum((press(t0, t1, down, up) for t0, t1 in spans), []))
        TL.track(cls + "hi", sum((press(t0, t1, opacity(1), opacity(0)) for t0, t1 in spans), []))

    # The chooser opens on the first Tab, starting on the arrangement before the current one, and closes on release.
    hidden, shown = opacity(0, scale(.97)), opacity(1, scale(1))
    for i, (opened, released) in enumerate(((TAPS[0], HELD[0][1]), (TAPS[2], HELD[1][1])), 1):
        TL.track(f"ch{i}", [(opened + .05, hidden, EOUT), (opened + .2, shown), (released, shown),
                            (released + .12, opacity(0, scale(1)))], origin=center(S))
    _, xs = chooser_layout(*SESSIONS[0])
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
        thumbnail_defs(), wallpapers((S,)), menubar(S),
        f'<g class="olderonly">\n{only("older", ("purple",))}\n</g>',
        f'<g class="nowonly">\n{only("now", ("purple", "blue"))}\n</g>',
        f'<g class="pbody">\n{body}\n{outline}\n</g>', f'<g class="pband">\n{band}\n</g>',
        f'<g class="plights">\n{lights}\n' + "\n".join(lines[:kept]) + "\n</g>",
        '<g class="plights"><g class="pmore">\n' + "\n".join(lines[kept:]) + "\n</g></g>",
        f'<g class="bfade"><g class="bfit">\n{full_window(B_REST, "blue")}\n</g></g>',
        dock(S),
        *(chooser(i, order, gaps, 1) for i, (order, gaps) in enumerate(SESSIONS, 1)),
        ripple("rpB", CLICK_B), ripple("rpP", REST),
        f'<g class="cur"><g class="press">{CURSOR}</g></g>',
    ]
    return document((W, H), TITLE, "scripts/activefit-winshot-animation.py", (S,), TL.style(), screen,
                    keycaps() + "\n" + captions(CAPTIONS, W / 2, CAPTION_Y))


if __name__ == "__main__":
    with open(sys.argv[1], "w") as f:
        f.write(build())
