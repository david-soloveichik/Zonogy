"""Shared drawing and keyframe helpers for the README animations (scripts/hero-animation.py and
scripts/activefit-winshot-animation.py).

Both draw an abstract macOS desktop as SVG and animate it with CSS keyframes only (no script), so they play
wherever the README renders. Like the README's animated WebP images, they play even with Reduce Motion on.
"""

ZBLUE = "#4a9eff"  # Zonogy's highlight blue
FONT = "-apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif"

APPS = {  # Dock order: (icon, icon highlight)
    "purple": ("#7a5af5", "#a58dff"),
    "blue": ("#2d7ff9", "#66a8ff"),
    "orange": ("#f39c1d", "#ffc566"),
    "green": ("#1db45c", "#62da91"),
    "amber": ("#e0a800", "#ffd23f"),
    "pink": ("#e64590", "#ff8cc0"),
    "teal": ("#0fa39b", "#52d6cc"),
}
TINTS = {  # window body colors, deliberately uneven in hue and lightness
    "purple": "#3b3458",
    "blue": "#c9dcf8",
    "orange": "#f3cf9f",
    "green": "#b9e0c3",
    "amber": "#f1e19a",
    "pink": "#f5cadc",
    "teal": "#2f5d5a",
}
GLYPHS = {
    "purple": '<path d="M20 17l-8 8 8 8M30 17l8 8-8 8"/>',
    "blue": '<circle cx="25" cy="25" r="12"/><path d="M13 25h24M25 13c-6 5-6 19 0 24M25 13c6 5 6 19 0 24"/>',
    "orange": '<path d="M16 18h18M16 25h18M16 32h11"/>',
    "green": '<rect x="14" y="14" width="22" height="22" rx="3"/><path d="M14 25h22M25 14v22"/>',
    "amber": '<path d="M27 12l-10 15h8l-2 11 10-15h-8z" fill="#fff"/>',
    "pink": '<path d="M20 16l14 9-14 9z" fill="#fff"/>',
    "teal": '<path d="M15 19a4 4 0 0 1 4-4h12a4 4 0 0 1 4 4v9a4 4 0 0 1-4 4h-7l-6 5v-5a3 3 0 0 1-3-3z"/>',
}
WALLPAPERS = (  # gradient stops, one wallpaper per display
    '<stop offset="0" stop-color="#151b33"/><stop offset=".6" stop-color="#232a52"/><stop offset="1" stop-color="#3b2a5e"/>',
    '<stop offset="0" stop-color="#132335"/><stop offset=".6" stop-color="#1b3550"/><stop offset="1" stop-color="#2a3a68"/>',
)

# A display is its screen rectangle (x, y, w, h) inside a black glass bezel and an aluminum rim.
BEZEL, RIM = 10, 4
FRAME = BEZEL + RIM
MENU_H, MARGIN, GAP = 18, 10, 8  # menu bar height, zone margin at the display edges, gap between zones
ICON, ICON_GAP, DOCK_PAD = 36, 8, 7
DOCK_W = len(APPS) * ICON + (len(APPS) - 1) * ICON_GAP + 2 * DOCK_PAD
DOCK_H = ICON + 2 * DOCK_PAD


def n(v):
    s = f"{v:.2f}".rstrip("0").rstrip(".")
    return "0" if s == "-0" else s


def center(z):
    return (z[0] + z[2] / 2, z[1] + z[3] / 2)


def is_dark(color):
    r, g, b = (int(color[i:i + 2], 16) for i in (1, 3, 5))
    return .299 * r + .587 * g + .114 * b < 128


def dock_origin(screen):
    x, y, w, h = screen
    return (x + (w - DOCK_W) / 2, y + h - DOCK_H - 6)


def icon_center(screen, app):
    dx, dy = dock_origin(screen)
    i = list(APPS).index(app)
    return (dx + DOCK_PAD + i * (ICON + ICON_GAP) + ICON / 2, dy + DOCK_PAD + ICON / 2)


def columns(screen, bottom):
    """Top, height, column width, and the two column lefts of a display's zone area."""
    x, y, w, _ = screen
    top = y + MENU_H + GAP
    cw = (w - 2 * MARGIN - GAP) / 2
    return top, bottom - top, cw, (x + MARGIN, x + MARGIN + cw + GAP)


# ---------------------------------------------------------------- shapes

def rect(x, y, w, h, r=0, **attrs):
    extra = "".join(f' {k.replace("_", "-")}="{v}"' for k, v in attrs.items())
    rx = f' rx="{n(r)}"' if r else ""
    return f'<rect x="{n(x)}" y="{n(y)}" width="{n(w)}" height="{n(h)}"{rx}{extra}/>'


def bar(x, y, w, h, fill, op=1.0):
    o = f' fill-opacity="{n(op)}"' if op != 1 else ""
    return f'<rect x="{n(x)}" y="{n(y)}" width="{n(w)}" height="{n(h)}" rx="{n(h / 2)}" fill="{fill}"{o}/>'


def defs(screens):
    s = ["<defs>",
         '<linearGradient id="rim" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#7d828d"/>'
         '<stop offset=".5" stop-color="#4c5059"/><stop offset="1" stop-color="#2f3239"/></linearGradient>',
         '<linearGradient id="rimEdge" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#fff" stop-opacity=".45"/>'
         '<stop offset=".35" stop-color="#fff" stop-opacity="0"/></linearGradient>',
         '<filter id="dshadow" x="-10%" y="-10%" width="120%" height="135%">'
         '<feDropShadow dx="0" dy="10" stdDeviation="12" flood-color="#000" flood-opacity=".6"/></filter>',
         '<linearGradient id="stage" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#121729"/>'
         '<stop offset="1" stop-color="#0b0f1c"/></linearGradient>']
    s += [f'<linearGradient id="wall{i + 1}" x1="0" y1="0" x2="1" y2="1">{stops}</linearGradient>'
          for i, stops in enumerate(WALLPAPERS[:len(screens)])]
    s.append('<radialGradient id="wallGlow" cx=".78" cy=".1" r=".7"><stop offset="0" stop-color="#5b7fe0" stop-opacity=".3"/>'
             '<stop offset="1" stop-color="#5b7fe0" stop-opacity="0"/></radialGradient>')
    for app, (base, light) in APPS.items():
        s.append(f'<linearGradient id="g-{app}" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="{light}"/>'
                 f'<stop offset="1" stop-color="{base}"/></linearGradient>')
    for app, glyph in GLYPHS.items():
        s.append(f'<symbol id="ic-{app}" viewBox="0 0 50 50"><rect width="50" height="50" rx="12" fill="url(#g-{app})"/>'
                 f'<g fill="none" stroke="#fff" stroke-width="3.4" stroke-linecap="round" stroke-linejoin="round">{glyph}</g></symbol>')
    s += ['<filter id="glow" x="-10%" y="-15%" width="120%" height="130%"><feGaussianBlur stdDeviation="3.5"/></filter>',
          '<filter id="shadow" x="-20%" y="-20%" width="140%" height="150%">'
          '<feDropShadow dx="0" dy="7" stdDeviation="9" flood-color="#000" flood-opacity=".45"/></filter>',
          '<filter id="cshadow" x="-60%" y="-60%" width="220%" height="220%">'
          '<feDropShadow dx="0" dy="1.2" stdDeviation="1.1" flood-color="#000" flood-opacity=".5"/></filter>',
          '<clipPath id="screens">' + "".join(rect(*sc, 8) for sc in screens) + "</clipPath>",
          "</defs>"]
    return "\n".join(s)


def hardware(screens):
    """Each display's body: a space-gray aluminum rim, lit from above, around a black glass bezel with a camera."""
    s = []
    for x, y, w, h in screens:
        s += [rect(x - FRAME, y - FRAME, w + 2 * FRAME, h + 2 * FRAME, 20, fill="url(#rim)", filter="url(#dshadow)"),
              rect(x - FRAME + .75, y - FRAME + .75, w + 2 * FRAME - 1.5, h + 2 * FRAME - 1.5, 19.25, fill="none",
                   stroke="url(#rimEdge)", stroke_width="1.5"),
              rect(x - BEZEL, y - BEZEL, w + 2 * BEZEL, h + 2 * BEZEL, 15, fill="#040507"),
              f'<circle cx="{n(x + w / 2)}" cy="{n(y - BEZEL / 2)}" r="2" fill="#1c2029" stroke="#2c313c" stroke-width=".8"/>']
    return "\n".join(s)


def wallpapers(screens):
    return "\n".join(rect(*sc, fill=f"url(#wall{i + 1})") + rect(*sc, fill="url(#wallGlow)")
                     for i, sc in enumerate(screens))


def menubar(screen):
    x, y, w, _ = screen
    s = [rect(x, y, w, MENU_H, fill="#05070d", fill_opacity=".28"),
         f'<circle cx="{n(x + 15)}" cy="{n(y + 9)}" r="4.2" fill="#fff" fill-opacity=".9"/>']
    xx = x + 29
    for i, bw in enumerate((30, 20, 20, 26, 30)):
        s.append(bar(xx, y + 6.25, bw, 5.5, "#fff", .85 if i == 0 else .55))
        xx += bw + 11
    xx = x + w - 14
    for bw in (36, 11, 11, 11, 15):
        xx -= bw
        s.append(bar(xx, y + 6.25, bw, 5.5, "#fff", .55))
        xx -= 8
    return "\n".join(s)


def window_parts(z, app):
    """A window reduced to its frame, as (body in the app's tint, title bar band, traffic lights, outline)."""
    x, y, w, h = z
    r, tb = 8, 22
    tint = TINTS[app]
    shade = 'fill="#fff" fill-opacity=".08"' if is_dark(tint) else 'fill="#0b1020" fill-opacity=".06"'
    band = (f'<path d="M{n(x)} {n(y + tb)}V{n(y + r)}a{r} {r} 0 0 1 {r}-{r}H{n(x + w - r)}a{r} {r} 0 0 1 {r} {r}'
            f'V{n(y + tb)}z" {shade}/>')
    lights = "\n".join(f'<circle cx="{n(x + 13 + 13 * i)}" cy="{n(y + 11)}" r="4" fill="{c}"/>'
                       for i, c in enumerate(("#ff5f57", "#febc2e", "#28c840")))
    return (rect(x, y, w, h, r, fill=tint), band, lights,
            rect(x + .5, y + .5, w - 1, h - 1, r - .5, fill="none", stroke="#070a14", stroke_opacity=".45"))


def window(z, app):
    return "\n".join(window_parts(z, app))


def dock(screen):
    dx, dy = dock_origin(screen)
    s = [rect(dx, dy, DOCK_W, DOCK_H, 14, fill="#fff", fill_opacity=".16", stroke="#fff", stroke_opacity=".28")]
    for app in APPS:
        cx, cy = icon_center(screen, app)
        s.append(f'<use href="#ic-{app}" x="{n(cx - ICON / 2)}" y="{n(cy - ICON / 2)}" width="{ICON}" height="{ICON}"/>')
        s.append(f'<circle cx="{n(cx)}" cy="{n(dy + DOCK_H - 3.5)}" r="1.6" fill="#fff" fill-opacity=".85"/>')
    return "\n".join(s)


def ripple(cls, p):
    """A ring that marks a click or key press at p (see Timeline.ripple)."""
    return f'<circle class="{cls}" cx="{n(p[0])}" cy="{n(p[1])}" r="11" fill="none" stroke="{ZBLUE}" stroke-width="2.2"/>'


def captions(texts, x, y):
    return "\n".join(f'<text class="cap{i}" x="{n(x)}" y="{n(y)}" text-anchor="middle" font-family="{FONT}" '
                     f'font-size="25" font-weight="500" fill="#e6eaf2">{text}</text>'
                     for i, (text, _, _) in enumerate(texts))


CURSOR = ('<path d="M0 0V20l4.8-4.4 3.6 8 3.2-1.4-3.5-7.8h6.3z" fill="#111" stroke="#fff" stroke-width="1.3" '
          'stroke-linejoin="round" filter="url(#cshadow)"/>')


def document(size, title, generator, screens, style, content, caption_svg):
    """The SVG file: stage, display hardware, everything on the screens (clipped to them), then the captions."""
    w, h = size
    return "\n".join([
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}" role="img" aria-labelledby="title">',
        f'<title id="title">{title}</title>',
        f"<!-- Generated by {generator} -->",
        defs(screens),
        style,
        rect(0, 0, w, h, 28, fill="url(#stage)"),
        hardware(screens),
        '<g clip-path="url(#screens)">',
        *content,
        "</g>",
        caption_svg,
        "</svg>",
        "",
    ])


# ---------------------------------------------------------------- motion

EIO = (.45, 0, .25, 1)  # pointer moves
EOUT = (.2, .8, .25, 1)  # things arriving


def ease_progress(e, x):
    """Progress of cubic-bezier easing `e` at time fraction `x`, as a browser computes it."""
    x1, y1, x2, y2 = e
    bez = lambda a, b, s: 3 * (1 - s) ** 2 * s * a + 3 * (1 - s) * s ** 2 * b + s ** 3
    lo, hi = 0.0, 1.0
    for _ in range(50):
        mid = (lo + hi) / 2
        lo, hi = (mid, hi) if bez(x1, x2, mid) < x else (lo, mid)
    return bez(y1, y2, (lo + hi) / 2)


def at(x, y, s=1):
    return f"transform:translate({n(x)}px,{n(y)}px) scale({n(s)})"


def scale(s):
    return f"transform:scale({n(s)})"


def opacity(o, extra=""):
    return f"opacity:{n(o)}" + (f";{extra}" if extra else "")


class Timeline:
    """CSS animations sharing one loop of `dur` seconds. `still` is the moment shown where CSS animations don't
    run, so every track must hold steady then."""

    def __init__(self, dur, still):
        self.dur, self.still, self.css = dur, still, []

    def track(self, cls, points, origin=None):
        """Animate class `cls` through [(time, declarations[, easing to the next point])], holding the ends."""
        pts = [p if len(p) == 3 else (*p, None) for p in points]
        if pts[0][0] > 0:
            pts.insert(0, (0.0, pts[0][1], None))
        if pts[-1][0] < self.dur:
            pts.append((self.dur, pts[-1][1], None))
        timing = lambda e: f";animation-timing-function:cubic-bezier({','.join(n(v) for v in e)})" if e else ""
        frames = "".join(f"{100 * t / self.dur:.3f}%{{{d}{timing(e)}}}" for t, d, e in pts)
        self.css.append(f"@keyframes {cls}{{{frames}}}")
        for (t0, d0, _), (t1, d1, _) in zip(pts, pts[1:]):
            if t0 <= self.still < t1:
                assert d0 == d1, f"{cls} is moving at the still frame"
                still = d0
        rule = f"animation:{cls} {n(self.dur)}s linear infinite;{still}"
        if origin:
            rule += f";transform-origin:{n(origin[0])}px {n(origin[1])}px"
        self.css.append(f".{cls}{{{rule}}}")

    def ripple(self, cls, t, p):
        self.track(cls, [(t, opacity(0, scale(.3))), (t + .001, opacity(.9, scale(.3)), EOUT),
                         (t + .45, opacity(0, scale(1.5))), (t + .451, opacity(0, scale(.3)))], origin=p)

    def captions(self, texts):
        for i, (_, shown, fading) in enumerate(texts):
            self.track(f"cap{i}", [(shown, opacity(0)), (shown + .2, opacity(1)), (fading, opacity(1)),
                                   (fading + .2, opacity(0))])

    def style(self):
        return "<style>\n" + "\n".join(self.css) + "\n</style>"
