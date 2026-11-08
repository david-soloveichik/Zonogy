#!/usr/bin/env python3
"""Generates docs/images/hero-animation.svg, the README hero animation: two displays, with captions.

One loop: each display tiles its own zones. First the bar between the main display's columns is dragged
left and back, and the windows follow their zones as they resize. Minimizing a window leaves its zone in place, empty, with the
Launcher open there, first on the main display and then on the secondary one; picking a window fills the
zone. Then a specific window is dragged out of a Dock icon's DockMenu, across both displays (each zone
lights up under the pointer), onto the secondary display's zone, replacing the window there. Finally the
main display's zone crossfades back to its first window, so the loop restarts where it began.

Usage: python3 scripts/hero-animation.py docs/images/hero-animation.svg
"""
import sys

from animation_common import (CURSOR, EIO, EOUT, FRAME, GAP, MARGIN, ZBLUE, Timeline, at, bar, captions, center,
                              columns, dock, dock_origin, document, ease_progress, full_window, icon_center, menubar,
                              n, opacity, rect, ripple, scale, wallpapers, window_content, window_parts)

DUR = 14.6  # loop length, seconds
T_STILL = 5.3  # frame shown where CSS animations don't run: the Launcher open in the main display's emptied zone
W, H = 1600, 712
TITLE = (
    "Zonogy on two displays. Each display keeps its own tiling zones. Minimizing a window, on either display, "
    "leaves its zone empty with the Launcher open there to pick a window for it. Dragging a specific window "
    "from the menu over its Dock icon onto any zone, on either display, replaces the window there."
)
CAPTIONS = (  # (text, shown from, fading out at)
    ("Minimizing a window opens the Launcher in that zone to fill it", 2.9, 9.3),
    ("Or hover over a Dock icon and drag a specific window", 9.7, 13.3),
)

# Displays: screen rectangles (x, y, w, h), side by side with their tops (and menu bars) aligned. The left one
# has the Dock. The pointer crosses between them only where their edges meet, so above the smaller one's bottom.
DISPLAY_GAP = 36  # space between the displays
SW1, SH1, SW2, SH2 = 860, 538, 576, 360
S1 = ((W - SW1 - SW2 - 4 * FRAME - DISPLAY_GAP) / 2 + FRAME, 54, SW1, SH1)
S2 = (S1[0] + SW1 + 2 * FRAME + DISPLAY_GAP, S1[1], SW2, SH2)
CAPTION_Y = S1[1] + SH1 + FRAME + 58
DOCK_Y = dock_origin(S1)[1]

_t1, _h1, _w1, (_l1, _r1) = columns(S1, DOCK_Y - GAP)
_t2, _h2, _w2, (_l2, _r2) = columns(S2, S2[1] + SH2 - MARGIN)
Z1 = (_l1, _t1, _w1, _h1)
Z2 = (_r1, _t1, _w1, (_h1 - GAP) / 2)
Z3 = (_r1, _t1 + (_h1 + GAP) / 2, _w1, (_h1 - GAP) / 2)
Z4 = (_l2, _t2, _w2, _h2)
Z5 = (_r2, _t2, _w2, _h2)
ZONES = (Z1, Z2, Z3, Z4, Z5)
# Windows that stay put (Z2 and Z5 change hands): (app, zone, resize class of the body, of the traffic lights).
STATIC = (("purple", Z1, "rzA", ""), ("orange", Z3, "rzR", "rzL"), ("teal", Z4, "", ""))
RESIZE_DX = -112  # the opening drag of the bar between the main display's columns, out and back
CONTENT_OPACITY = .5  # window content stays subtle here
BAR = (Z1[0] + Z1[2] + GAP / 2, Z1[1] + Z1[3] / 2)  # where the pointer grabs that bar

LW, LH, ROW_H = 232, 178, 30  # Launcher, centered in the zone it opens in
LAUNCHER_ROWS = {  # (app, title width, subtitle width); row 2 is the window picked
    Z2: (("blue", 96, 52), ("green", 116, 62), ("amber", 86, 48), ("teal", 104, 56)),
    Z5: (("pink", 96, 52), ("amber", 116, 62), ("blue", 86, 48), ("green", 104, 56)),
}


def launcher_origin(z):
    return (z[0] + (z[2] - LW) / 2, z[1] + (z[3] - LH) / 2)


def row_center(z, i):
    return launcher_origin(z)[1] + 44 + ROW_H / 2 + i * ROW_H


def row2(z):
    """Where the pointer picks the Launcher's second row in zone z, and where that row's icon sits."""
    lx = launcher_origin(z)[0]
    return (lx + 90, row_center(z, 1) + 2), (lx + 26, row_center(z, 1))


DB = icon_center(S1, "pink")
DM_W, DM_H = 200, 124  # the pink app's DockMenu, above its Dock icon
DM_X, DM_Y = DB[0] - DM_W / 2, DOCK_Y - 8 - DM_H
DM_ROW0, DM_ROW_H = DM_Y + 44, 24
DM_ROWS = (118, 96, 130)  # title widths; the second row is the window that gets dragged
P0 = (center(Z5)[0] + 13, center(Z5)[1] - 31)  # pointer rest point, also where the DockMenu drag drops
YB1, YB2 = (Z2[0] + 26, Z2[1] + 11), (Z5[0] + 26, Z5[1] + 11)  # minimize buttons of the Z2 and Z5 windows
(R2A, ICON2A), (R2B, ICON2B) = row2(Z2), row2(Z5)
M2 = (DM_X + 95, DM_ROW0 + 1.5 * DM_ROW_H)  # DockMenu row 2


# ---------------------------------------------------------------- shapes

def resizable_window(z, app, body_cls, lights_cls):
    """A window whose body (title bar band and content included) can stretch with a zone resize while its
    traffic lights only slide along with its left edge."""
    body, band, lights, outline = window_parts(z, app)
    content = window_content(z, app, CONTENT_OPACITY)
    wrap = lambda cls, parts: f'<g class="{cls}">\n' + "\n".join(parts) + "\n</g>" if cls else "\n".join(parts)
    return wrap(body_cls, (body, band, content, outline)) + "\n" + wrap(lights_cls, (lights,))


def resize_bar():
    """The zone resize bar between the main display's columns, as tall as the zones (menu bar to Dock), shown
    while the pointer hovers and drags it."""
    return '<g class="rbar">' + rect(BAR[0] - 2, Z1[1], 4, Z1[3], 2, fill="#fff", fill_opacity=".92") + "</g>"


def placeholder(cls, z):
    x, y, w, h = z
    cx = x + w / 2
    return "\n".join([
        f'<g class="{cls}">',
        rect(x, y, w, h, 8, fill="#9cc8ff", fill_opacity=".06"),
        rect(x, y, w, h, 8, fill="none", stroke=ZBLUE, stroke_width="4", filter="url(#glow)"),
        rect(x + 1, y + 1, w - 2, h - 2, 7, fill="none", stroke=ZBLUE, stroke_width="2"),
        f'<circle cx="{n(x + 20)}" cy="{n(y + 20)}" r="10" fill="{ZBLUE}" fill-opacity=".6"/>',
        f'<path d="M{n(x + 16.5)} {n(y + 16.5)}l7 7m0-7l-7 7" stroke="#fff" stroke-width="2" stroke-linecap="round"/>',
        rect(cx - 31, y + 8, 62, 17, 8.5, fill="#fff", fill_opacity=".18"),
        f'<circle cx="{n(cx - 1.5)}" cy="{n(y + 15.5)}" r="3.5" fill="none" stroke="#fff" stroke-width="1.5"/>',
        f'<path d="M{n(cx + 1.2)} {n(y + 18.2)}l3 3" stroke="#fff" stroke-width="1.5" stroke-linecap="round"/>',
        "</g>",
    ])


def launcher(cls, z):
    lx, ly = launcher_origin(z)
    s = [f'<g class="{cls}">',
         rect(lx, ly, LW, LH, 12, fill="#f5f6f9", fill_opacity=".97", filter="url(#shadow)"),
         rect(lx + .5, ly + .5, LW - 1, LH - 1, 11.5, fill="none", stroke="#fff", stroke_opacity=".8"),
         rect(lx + 10, ly + 10, LW - 20, 26, 7, fill="#fff", stroke="#d8dce4"),
         f'<circle cx="{n(lx + 24)}" cy="{n(ly + 22)}" r="4.5" fill="none" stroke="#8b93a2" stroke-width="1.6"/>',
         f'<path d="M{n(lx + 27.3)} {n(ly + 25.3)}l3.3 3.3" stroke="#8b93a2" stroke-width="1.6" stroke-linecap="round"/>',
         f'<rect class="caret" x="{n(lx + 36)}" y="{n(ly + 16.5)}" width="1.6" height="13" rx=".8" fill="{ZBLUE}"/>',
         bar(lx + 42, ly + 20, 90, 6, "#c9ced8"),
         f'<g class="{cls}sel">' + rect(lx + 7, ly + 46, LW - 14, ROW_H - 4, 7, fill=ZBLUE, fill_opacity=".2",
                                        stroke=ZBLUE, stroke_opacity=".6") + "</g>"]
    for i, (app, w1, w2) in enumerate(LAUNCHER_ROWS[z]):
        cy = row_center(z, i)
        s.append(f'<use href="#ic-{app}" x="{n(lx + 16)}" y="{n(cy - 10)}" width="20" height="20"/>')
        s.append(bar(lx + 46, cy - 6.5, w1, 6, "#4d5566", .6))
        s.append(bar(lx + 46, cy + 3, w2, 4.5, "#8a93a3", .5))
    s.append("</g>")
    return "\n".join(s)


def dockmenu():
    s = ['<g class="dm">',
         rect(DM_X, DM_Y, DM_W, DM_H, 10, fill="#f5f6f9", fill_opacity=".97", filter="url(#shadow)"),
         rect(DM_X + .5, DM_Y + .5, DM_W - 1, DM_H - 1, 9.5, fill="none", stroke="#fff", stroke_opacity=".8"),
         f'<use href="#ic-pink" x="{n(DM_X + 11)}" y="{n(DM_Y + 10)}" width="18" height="18"/>',
         bar(DM_X + 37, DM_Y + 15.5, 70, 6.5, "#3f4757", .75),
         bar(DM_X + DM_W - 47, DM_Y + 16.5, 36, 5, "#8a93a3", .5),
         f'<path d="M{n(DM_X + 10)} {n(DM_Y + 36.5)}H{n(DM_X + DM_W - 10)}" stroke="#d5d9e1"/>',
         '<g class="dmrow">' + rect(DM_X + 7, DM_ROW0 + DM_ROW_H + 1.5, DM_W - 14, DM_ROW_H - 3, 6, fill=ZBLUE,
                                    fill_opacity=".2", stroke=ZBLUE, stroke_opacity=".6") + "</g>"]
    for i, w in enumerate(DM_ROWS):
        s.append(bar(DM_X + 37, DM_ROW0 + (i + .5) * DM_ROW_H - 3, w, 6, "#4d5566", .6))
    s.append("</g>")
    return "\n".join(s)


def overlays():
    """Zone overlays: a faint one on every zone, plus a highlight per zone for when the pointer is over it."""
    zone = lambda z, **a: rect(z[0] + 3, z[1] + 3, z[2] - 6, z[3] - 6, 7, fill=ZBLUE, **a)
    return "\n".join(['<g class="ov">'] + [zone(z, fill_opacity=".1", stroke=ZBLUE, stroke_opacity=".55", stroke_width="1.5")
                                           for z in ZONES] + ["</g>"] +
                     [f'<g class="hot{i}">' + zone(z, fill_opacity=".28", stroke=ZBLUE, stroke_width="2.2") + "</g>"
                      for i, z in enumerate(ZONES)])


# Drag preview for a DockMenu window row: a dark pill with a window glyph and the title, below-right of the pointer.
PILL = ('<g class="pill">' + rect(9, 14, 112, 20, 6, fill="#262a33", fill_opacity=".92", filter="url(#cshadow)")
        + rect(16, 20, 10, 8, 2, fill="none", stroke="#c3c8d2", stroke_width="1.3")
        + '<path d="M16 23h10" stroke="#c3c8d2" stroke-width="1.3"/>'
        + bar(31, 21, DM_ROWS[1] * .75, 6, "#e6e9ef", .85) + "</g>")


# ---------------------------------------------------------------- motion

TL = Timeline(DUR, T_STILL)
track = TL.track

# Pointer path: (time, point, easing of the move that starts there; None holds still). An easing
# pair eases x and y separately, which curves the move.
POINTER = [
    (0.4, P0, EIO), (1.0, BAR, None),  # onto the bar between the main display's columns
    (1.15, BAR, EIO), (1.8, (BAR[0] + RESIZE_DX, BAR[1]), None),  # drag it left: the zones and their windows follow
    (2.05, (BAR[0] + RESIZE_DX, BAR[1]), EIO), (2.65, BAR, None),  # and back
    (3.0, BAR, EIO), (3.8, YB1, None),  # to the minimize button of the main display's top-right window
    (4.5, YB1, EIO), (5.1, R2A, None),  # into the Launcher there, onto row 2
    (6.3, R2A, EIO), (7.0, YB2, None),  # to the minimize button of the secondary display's right window
    (7.7, YB2, EIO), (8.3, R2B, None),  # into the Launcher there, onto row 2
    (9.4, R2B, ((.3, 0, .3, 1), (.6, 0, .35, 1))), (10.3, DB, None),  # left onto the main display, down to the pink Dock icon
    (10.65, DB, EIO), (11.0, M2, None),  # up onto the DockMenu's second window
    (11.2, M2, ((.6, 0, .35, 1), (.3, 0, .3, 1))), (12.8, P0, None),  # drag it up, then across to the secondary display
]
RESIZE = (1.15, 1.8, 2.05, 2.65)  # bar drag: out, held, back, released
DRAG = (11.2, 12.8)
DROP = 12.95  # mouse up: the dragged window replaces the zone's window
OV_OUT = DROP + .05  # drag overlays start fading
RESET = 13.8  # Z2 crossfades back to its first window, with no caption showing


def axis_easings(e):
    return (e, e) if e is None or isinstance(e[0], (int, float)) else e


def pointer_at(t):
    pts = [(0.0, POINTER[0][1], None)] + POINTER + [(DUR, POINTER[-1][1], None)]
    for (t0, p0, e), (t1, p1, _) in zip(pts, pts[1:]):
        if t0 <= t <= t1:
            assert e or p0 == p1, "a move needs an easing"
            u = (t - t0) / (t1 - t0)
            return tuple(a + (b - a) * (ease_progress(ea, u) if ea else 0)
                         for a, b, ea in zip(p0, p1, axis_easings(e)))


def zone_visits(t0, t1, step=.002):
    """[(zone index, enter, leave)] for each stretch the pointer spends over a zone between t0 and t1."""
    runs = []
    for k in range(int((t1 - t0) / step) + 1):
        t = t0 + k * step
        x, y = pointer_at(t)
        zone = next((i for i, (zx, zy, zw, zh) in enumerate(ZONES)
                     if zx <= x <= zx + zw and zy <= y <= zy + zh), None)
        if runs and runs[-1][0] == zone:
            runs[-1][2] = t
        else:
            runs.append([zone, t, t])
    return [tuple(r) for r in runs if r[0] is not None]


def motion():
    track("curx", [(t, f"transform:translateX({n(p[0])}px)", axis_easings(e)[0]) for t, p, e in POINTER])
    track("cury", [(t, f"transform:translateY({n(p[1])}px)", axis_easings(e)[1]) for t, p, e in POINTER])
    press = [(RESIZE[0] - .07, scale(1)), (RESIZE[0], scale(.86)), (RESIZE[3], scale(.86)), (RESIZE[3] + .1, scale(1))]
    for t in (3.9, 5.5, 7.1, 8.7):
        press += [(t, scale(1)), (t + .07, scale(.86)), (t + .19, scale(1))]
    press += [(11.15, scale(1)), (11.22, scale(.86)), (DROP, scale(.86)), (DROP + .12, scale(1))]
    track("press", press, origin=(0, 0))

    for cls, t, p in (("rpY1", 3.93, YB1), ("rpR1", 5.53, R2A), ("rpY2", 7.13, YB2), ("rpR2", 8.73, R2B),
                      ("rpM", 11.18, M2), ("rpP", DROP + .03, P0)):
        TL.ripple(cls, t, p)

    # Opening resize: the bar shows on hover and follows the drag. The left window stretches from its left edge,
    # the right column's windows from their right edge, with their traffic lights sliding along.
    def resized(cls, at_k, origin=None):
        track(cls, [(RESIZE[0], at_k(0), EIO), (RESIZE[1], at_k(1)), (RESIZE[2], at_k(1), EIO), (RESIZE[3], at_k(0))],
              origin=origin)

    resized("rzA", lambda k: f"transform:scaleX({(Z1[2] + k * RESIZE_DX) / Z1[2]:.4f})", (Z1[0], 0))
    resized("rzR", lambda k: f"transform:scaleX({(Z2[2] - k * RESIZE_DX) / Z2[2]:.4f})", (Z2[0] + Z2[2], 0))
    resized("rzL", lambda k: f"transform:translateX({n(k * RESIZE_DX)}px)")
    TL.css.append(".rzA rect,.rzR rect{vector-effect:non-scaling-stroke}")
    slid = lambda o, k: opacity(o, f"transform:translateX({n(k * RESIZE_DX)}px)")
    track("rbar", [(.9, slid(0, 0)), (1.05, slid(1, 0)), (RESIZE[0], slid(1, 0), EIO), (RESIZE[1], slid(1, 1)),
                   (RESIZE[2], slid(1, 1), EIO), (RESIZE[3], slid(1, 0)), (RESIZE[3] + .1, slid(1, 0)),
                   (RESIZE[3] + .3, slid(0, 0))])

    # Windows. Minimizing fades a window out in place; a window picked in the Launcher grows from its row.
    # At the drop, Z5's window disappears at once and the dragged one grows from the drop point.
    ident = at(0, 0)
    grow_from = lambda p, z, s: at(p[0] - center(z)[0], p[1] - center(z)[1], s)
    track("bfd", [(4.0, opacity(1)), (4.12, opacity(0)), (RESET, opacity(0)), (RESET + .001, opacity(1))])  # under G
    track("gmv", [(5.6, grow_from(ICON2A, Z2, .05), EOUT), (6.15, ident)], origin=center(Z2))
    track("gfd", [(5.6, opacity(0)), (5.73, opacity(1)), (RESET, opacity(1)), (RESET + .4, opacity(0))])
    track("fmv", [(DROP - .2, ident), (DROP - .199, grow_from(P0, Z5, .06)), (DROP, grow_from(P0, Z5, .06), EOUT),
                  (DROP + .55, ident)], origin=center(Z5))
    track("ffd", [(7.2, opacity(1)), (7.32, opacity(0)), (DROP, opacity(0)), (DROP + .15, opacity(1))])
    track("hmv", [(8.8, grow_from(ICON2B, Z5, .05), EOUT), (9.35, ident)], origin=center(Z5))
    track("hfd", [(8.8, opacity(0)), (8.93, opacity(1)), (DROP, opacity(1)), (DROP + .001, opacity(0))])

    # Each emptied zone stays as a placeholder, and the Launcher opens there.
    hid, shown, gone = opacity(0, scale(.96)), opacity(1, scale(1)), opacity(0, scale(.98))
    row1, row2 = "transform:translateY(0px)", f"transform:translateY({ROW_H}px)"
    for i, (z, empty, hover, pick) in enumerate(((Z2, 4.05, 5.1, 5.6), (Z5, 7.25, 8.3, 8.8)), 1):
        lx, ly = launcher_origin(z)
        track(f"ph{i}", [(empty, opacity(0)), (empty + .2, opacity(1)), (pick + .15, opacity(1)), (pick + .4, opacity(0))])
        track(f"lc{i}", [(empty + .1, hid, EOUT), (empty + .35, shown), (pick, shown), (pick + .2, gone)],
              origin=(lx + LW / 2, ly + LH / 2))
        track(f"lc{i}sel", [(hover - .05, row1, EIO), (hover + .07, row2), (pick + .55, row2), (pick + .551, row1)])

    # DockMenu: opens while the pointer rests on the Dock icon and closes once the row drag starts,
    # leaving the drag pill under the pointer.
    low, up = "transform:translateY(5px)", "transform:translateY(0px)"
    track("dm", [(10.35, opacity(0, low), EOUT), (10.55, opacity(1, up)), (11.22, opacity(1, up)),
                 (11.32, opacity(0, up)), (11.4, opacity(0, low))])
    track("dmrow", [(10.92, opacity(0)), (11.0, opacity(1)), (11.4, opacity(1)), (11.401, opacity(0))])
    track("pill", [(11.22, opacity(0)), (11.32, opacity(1)), (DROP, opacity(1)), (DROP + .1, opacity(0))])

    # Drag feedback: every zone gets a faint overlay, the zone under the pointer lights up, and the drop
    # zone stays lit until the overlays go.
    track("ov", [(11.25, opacity(0)), (11.4, opacity(1)), (OV_OUT, opacity(1)), (OV_OUT + .2, opacity(0))])
    visits = zone_visits(*DRAG)
    for i in range(len(ZONES)):
        pts = [(0.0, opacity(0))]
        for zone, enter, leave in visits:
            if zone == i:
                end, fade = (OV_OUT, .2) if leave >= DRAG[1] - .01 else (max(leave, enter + .08), .08)
                pts += [(enter, opacity(0)), (enter + .08, opacity(1)), (end, opacity(1)), (end + fade, opacity(0))]
        track(f"hot{i}", pts)

    TL.captions(CAPTIONS)
    TL.css.append("@keyframes blink{0%,100%{opacity:1}50%{opacity:0}}.caret{animation:blink 1s step-end infinite}")


def build():
    motion()
    screens = [
        wallpapers((S1, S2)), menubar(S1), menubar(S2),
        *(resizable_window(z, app, body, lights) for app, z, body, lights in STATIC),
        placeholder("ph1", Z2), placeholder("ph2", Z5), launcher("lc1", Z2), launcher("lc2", Z5), dock(S1),
        f'<g class="bfd">\n{resizable_window(Z2, "blue", "rzR", "rzL")}\n</g>', resize_bar(),
        f'<g class="gmv"><g class="gfd">\n{full_window(Z2, "green", CONTENT_OPACITY)}\n</g></g>',
        f'<g class="hmv"><g class="hfd">\n{full_window(Z5, "amber", CONTENT_OPACITY)}\n</g></g>',
        f'<g class="fmv"><g class="ffd">\n{full_window(Z5, "pink", CONTENT_OPACITY)}\n</g></g>',
        dockmenu(), overlays(),
        ripple("rpY1", YB1), ripple("rpR1", R2A), ripple("rpY2", YB2), ripple("rpR2", R2B),
        ripple("rpM", M2), ripple("rpP", P0),
        f'<g class="curx"><g class="cury">{PILL}<g class="press">{CURSOR}</g></g></g>',
    ]
    return document((W, H), TITLE, "scripts/hero-animation.py", (S1, S2), TL.style(), screens,
                    captions(CAPTIONS, W, CAPTION_Y))


if __name__ == "__main__":
    with open(sys.argv[1], "w") as f:
        f.write(build())
