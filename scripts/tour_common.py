"""Layout, drawing and motion shared by the scenes of the tour's chapters (scripts/tour-*.py): one
display with two columns of zones, Zonogy's edge bars, labels, the pointer, and the file each scene writes.
The drawing itself is in animation_common.py.

A tour plays a scene in a web view above a page's text. A scene's captions and labels name no keys:
shortcuts are the user's to change, so only the page's text, which the app writes, mentions them.
"""
from animation_common import (CURSOR, EIO, EOUT, FONT, FRAME, GAP, ZBLUE, at, bar, captions, center, columns,
                              dock, dock_origin, document, ease_progress, full_window, keycaps, menubar, n, opacity,
                              rect, ripple, scale, wallpapers)

W, H = 920, 600  # kept low: the tour's window is as tall as its tallest page
S = ((W - 860) / 2, 12 + FRAME, 860, 500)  # the display's screen
CAPTION_Y = S[1] + S[3] + FRAME + 38
CONTENT_OPACITY = .5  # window content stays subtle

_top, _h, _cw, (_left, _right) = columns(S, dock_origin(S)[1] - GAP)
LEFT, RIGHT = (_left, _top, _cw, _h), (_right, _top, _cw, _h)  # the two columns, each as one zone


def top_half(z):
    return (z[0], z[1], z[2], (z[3] - GAP) / 2)


def bottom_half(z):
    return (z[0], z[1] + (z[3] + GAP) / 2, z[2], (z[3] - GAP) / 2)


BAR_X = LEFT[0] + LEFT[2] + GAP / 2  # the gap between the columns, where the zone resize bar shows
FLOATING = (center(S)[0] - 220, center(LEFT)[1] - 130, 440, 260)  # a window in the floating zone
NEW_ZONE_BARS = {side: (x, S[1] + S[3] / 3, 5, S[3] / 3)  # on the display's side edges, a third of its height
                 for side, x in (("left", S[0] + 1.5), ("right", S[0] + S[2] - 6.5))}
FLOATING_ZONE_BAR = (S[0] + S[2] / 3, S[1] + S[3] - 5, S[2] / 3, 4)  # on its bottom edge, under the Dock


# ---------------------------------------------------------------- shapes

def window(z, app):
    return full_window(z, app, CONTENT_OPACITY)


def new_zone_bar(side, cls=""):
    """A New Zone Bar. Given a class, it can fade: a side that holds two zones has no bar."""
    x, y, w, h = NEW_ZONE_BARS[side]
    pill = rect(x, y, w, h, w / 2, fill="#fff", fill_opacity=".6", stroke="#fff", stroke_opacity=".75", stroke_width=".8")
    return f'<g class="{cls}">{pill}</g>' if cls else pill


def floating_zone_bar():
    x, y, w, h = FLOATING_ZONE_BAR
    return rect(x, y, w, h, h / 2, fill=ZBLUE, fill_opacity=".45", stroke=ZBLUE, stroke_opacity=".8", stroke_width=".8")


def destination_indicator(z):
    """The slim bar over the destination zone, in the gap above it."""
    return bar(z[0] + z[2] / 3, z[1] - 6, z[2] / 3, 4, ZBLUE, .9)


def label(cls, text, pos, target):
    """A name for a part of the picture: `text` centered at `pos`, with a line to the part at `target`."""
    x, y = pos
    w = 10.6 * len(text) + 26
    return "\n".join([
        f'<g class="{cls}">',
        f'<path d="M{n(x)} {n(y)}L{n(target[0])} {n(target[1])}" stroke="#fff" stroke-opacity=".8" stroke-width="1.6"/>',
        f'<circle cx="{n(target[0])}" cy="{n(target[1])}" r="3.4" fill="#fff"/>',
        rect(x - w / 2, y - 16, w, 32, 16, fill="#0b1020", fill_opacity=".88", stroke="#fff", stroke_opacity=".55"),
        f'<text x="{n(x)}" y="{n(y + 6.5)}" text-anchor="middle" font-family="{FONT}" font-size="19" font-weight="500" '
        f'fill="#fff">{text}</text>',
        "</g>",
    ])


def inactive_lights(cls, z):
    """Gray traffic lights over the colored ones of the window in zone z, shown (class `cls`) while that
    window is not the focused one."""
    return f'<g class="{cls}">' + "".join(
        f'<circle cx="{n(z[0] + 13 + 13 * i)}" cy="{n(z[1] + 11)}" r="4" fill="#8b8f99"/>' for i in range(3)) + "</g>"


def navigation_circle(cls):
    """Zone navigation's circle, drawn at the origin for `circle_runs` to place on a zone."""
    return f'<g class="{cls}"><circle r="52" fill="{ZBLUE}" fill-opacity=".5"/></g>'


# ---------------------------------------------------------------- motion

def circle_runs(tl, cls, runs):
    """Zone navigation's circle through each gesture in `runs`, as ([(time, zone), ...], released): it shows
    on the first zone at its time, steps to each later zone, and goes when the keys are released."""
    on = lambda o, z: opacity(o, at(*center(z)))
    points = []
    for stops, released in runs:
        (start, zone), later = stops[0], stops[1:]
        points += [(start, on(0, zone)), (start + .12, on(1, zone))]
        for t, to in later:
            points += [(t, on(1, zone), EIO), (t + .14, on(1, to))]
            zone = to
        points += [(released, on(1, zone)), (released + .15, on(0, zone))]
    tl.track(cls, points)


def shown(tl, cls, start, end, fade_in=.2, fade_out=.2):
    """Class `cls` is visible from `start` to `end`, fading in and out."""
    tl.track(cls, [(start, opacity(0)), (start + fade_in, opacity(1)), (end, opacity(1)), (end + fade_out, opacity(0))])


def hidden(tl, cls, start, end, fade=.12):
    """Class `cls` is visible except from `start` to `end`: a window minimized, then back for the next loop."""
    tl.track(cls, [(start, opacity(1)), (start + fade, opacity(0)), (end, opacity(0)), (end + .25, opacity(1))])


def arriving(tl, cls, z, source, start, end, leave=.12):
    """The window in zone z, drawn inside `<g class="{cls}mv"><g class="{cls}fd">`, grows out of the point
    `source` at `start`, and is gone again after `end`."""
    grow = at(source[0] - center(z)[0], source[1] - center(z)[1], .05)
    tl.track(cls + "mv", [(start, grow, EOUT), (start + .55, at(0, 0)), (end + leave, at(0, 0)),
                          (end + leave + .001, grow)], origin=center(z))
    tl.track(cls + "fd", [(start, opacity(0)), (start + .13, opacity(1)), (end, opacity(1)), (end + leave, opacity(0))])


def arriving_window(cls, z, app, floating=False):
    """The drawing `arriving` animates. A floating window casts a shadow on the tiles under it."""
    shadow = ' filter="url(#shadow)"' if floating else ""
    return f'<g class="{cls}mv"><g class="{cls}fd"{shadow}>\n{window(z, app)}\n</g></g>'


def panel(tl, cls, z, start, end):
    """A panel (Launcher, CmdTab) centered in zone z opens at `start` and closes at `end`."""
    tl.track(cls, [(start, opacity(0, scale(.96)), EOUT), (start + .25, opacity(1, scale(1))), (end, opacity(1, scale(1))),
                   (end + .2, opacity(0, scale(.98)))], origin=center(z))


class Pointer:
    """The pointer on a scene's timeline: it rests, moves, clicks and drags. `tracks` emits the keyframes once
    the scene has described all of it; `svg` draws it, with the click ripples. While the mouse button is held
    a ring shows around the pointer's tip, so that a drag does not read as a mere move."""

    def __init__(self, tl, start):
        self.tl, self.path, self.presses, self.clicks, self.holds = tl, [(0.0, start, None)], [], [], []

    @property
    def position(self):
        return self.path[-1][1]

    def move(self, start, end, to):
        self.path += [(start, self.position, EIO), (end, to, None)]

    def jump(self, t, to):
        """Be at `to` from time t on, with no move: for a moment when the picture is covered."""
        self.path += [(t, self.position, None), (t + .001, to, None)]

    def click(self, t):
        self.presses += [(t, scale(1)), (t + .07, scale(.86)), (t + .19, scale(1))]
        self.clicks.append((t + .03, self.position))

    def press(self, t):
        """The mouse button goes down at t, and stays down until `release`."""
        self.presses += [(t - .07, scale(1)), (t, scale(.86))]
        self.clicks.append((t - .04, self.position))
        self.holds.append(t)

    def release(self, t):
        self.presses += [(t, scale(.86)), (t + .1, scale(1))]
        self.holds[-1] = (self.holds[-1], t)

    def at(self, t):
        """Where the pointer is at time t."""
        for (t0, p0, e), (t1, p1, _) in zip(self.path, self.path[1:]):
            if t0 <= t <= t1:
                k = ease_progress(e, (t - t0) / (t1 - t0)) if e and t1 > t0 else 0
                return tuple(a + (b - a) * k for a, b in zip(p0, p1))
        return self.position

    def tracks(self):
        self.tl.track("cur", [(t, at(*p), e) for t, p, e in self.path])
        self.tl.track("press", self.presses, origin=(0, 0))
        for i, (t, p) in enumerate(self.clicks):
            self.tl.ripple(f"rp{i}", t, p)
        if self.holds:
            self.tl.track("held", [point for down, up in self.holds for point in (
                (down - .02, opacity(0)), (down + .08, opacity(1)), (up, opacity(1)), (up + .12, opacity(0)))])

    def svg(self, carrying=""):
        """The pointer, with `carrying` (a drag preview, say) drawn so that it travels with it."""
        held = (f'<circle class="held" r="13" fill="{ZBLUE}" fill-opacity=".28" stroke="{ZBLUE}" stroke-width="2.2"/>'
                if self.holds else "")
        return "\n".join([*(ripple(f"rp{i}", p) for i, (_, p) in enumerate(self.clicks)),
                          f'<g class="cur">{carrying}{held}<g class="press">{CURSOR}</g></g>'])


# ---------------------------------------------------------------- file

RESTART_COVER = .15  # how long a restarting scene stays covered (see write_scene)
KEY_ROW = 46  # the height a row of keycaps adds under the display (see write_scene)


def write_scene(path, title, generator, tl, content, caption_texts, restart_at=None, keys=None):
    """Write the scene: `content` over the display's wallpaper, menu bar, Dock and Floating Zone Bar, with
    captions under the display.

    A scene about the keyboard gives `keys`: (label, width, class) caps drawn in a row between the display
    and the captions (see keycaps), on a canvas KEY_ROW taller. Only keys that are not the user's to change
    carry their glyph; the others say what they do.

    A scene that cannot end as it began gives `restart_at`: the whole picture fades to the stage's color, is
    covered from then for RESTART_COVER seconds, and fades back. The scene returns to its opening state while
    covered, so the loop reads as starting over, not as something Zonogy does."""
    tl.captions(caption_texts)
    base = [wallpapers((S,)), menubar(S), dock(S), floating_zone_bar()]
    height = H + (KEY_ROW if keys else 0)
    over = captions(caption_texts, W, CAPTION_Y + (KEY_ROW if keys else 0))
    if keys:
        over = keycaps(keys, W / 2, S[1] + S[3] + FRAME + 14) + "\n" + over
        # A cap the scene never presses stays unlit.
        tl.css += [f".{cls}hi{{opacity:0}}" for _, _, cls in keys if f"@keyframes {cls}hi{{" not in "".join(tl.css)]
    if restart_at is not None:
        tl.track("curtain", [(restart_at - .35, opacity(0)), (restart_at, opacity(1)),
                             (restart_at + RESTART_COVER, opacity(1)), (restart_at + RESTART_COVER + .35, opacity(0))])
        over += "\n" + rect(0, 0, W, height, fill="url(#stage)", **{"class": "curtain"})
    with open(path, "w") as f:
        f.write(document((W, height), title, generator, (S,), tl.style(), base + list(content), over, fluid=True))
