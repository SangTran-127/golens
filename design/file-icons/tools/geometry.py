"""Stroke geometry for the GoLens file-icon set.

Every icon is described once as centre-line specs in "design space": units are
SF Symbols template units at the Medium scale (100 pt type, cap height 70.459),
origin at the optical centre of the glyph, y pointing down. The same spec is
rendered at any scale factor `k` and stroke width `w`, and the number of points
it produces never depends on `w` — that is what keeps the Ultralight, Regular and
Black masters interpolation-compatible in the variable SF Symbols template.

ponytail: curves are emitted as dense polylines (7.5 degree steps), not cubics.
Invisible at sidebar sizes and keeps master compatibility trivial; fit cubics
if someone ever needs these at 100 pt+.
"""
import math

STEP = math.radians(7.5)


# ---------------------------------------------------------------- spec builders
def P(pts, closed=False):
    """Rounded polyline. pts = [(x, y, r)]; r == 0 is a sharp vertex (round join)."""
    return {"t": "path", "pts": [tuple(p) if len(p) == 3 else (p[0], p[1], 0) for p in pts], "closed": closed}


def FILL(pts):
    """Filled rounded polygon whose edge sits half a stroke outside the centre line, like a stroked P."""
    return {"t": "fill", "pts": [tuple(p) for p in pts]}


def E(cx, cy, rx, ry=None, a0=0, a1=360):
    """Stroked ellipse or elliptical arc (degrees, y-down, 0 = east)."""
    return {"t": "ellipse", "c": (cx, cy), "r": (rx, rx if ry is None else ry), "a": (a0, a1)}


def L(x0, y0, x1, y1):
    return P([(x0, y0, 0), (x1, y1, 0)])


def DISC(cx, cy, rx, ry=None):
    return {"t": "disc", "c": (cx, cy), "r": (rx, rx if ry is None else ry)}


def RRECT(x0, y0, x1, y1, r):
    return {"t": "rrect", "box": (x0, y0, x1, y1), "rr": r}


def POLY(pts):
    return {"t": "poly", "pts": [tuple(p) for p in pts]}


def T(specs, dx=0.0, dy=0.0, s=1.0):
    """Translate/scale specs. Stroke width is never scaled: badges keep the set's weight."""
    out = []
    for sp in specs:
        sp = dict(sp)
        if sp["t"] in ("path", "fill"):
            sp["pts"] = [(x * s + dx, y * s + dy, r * s) for x, y, r in sp["pts"]]
        elif sp["t"] in ("ellipse", "disc"):
            sp["c"] = (sp["c"][0] * s + dx, sp["c"][1] * s + dy)
            sp["r"] = (sp["r"][0] * s, sp["r"][1] * s)
        elif sp["t"] == "rrect":
            x0, y0, x1, y1 = sp["box"]
            sp["box"] = (x0 * s + dx, y0 * s + dy, x1 * s + dx, y1 * s + dy)
            sp["rr"] = sp["rr"] * s
        elif sp["t"] == "poly":
            sp["pts"] = [(x * s + dx, y * s + dy) for x, y in sp["pts"]]
        out.append(sp)
    return out


# ---------------------------------------------------------------- sampling
def _norm(x, y):
    d = math.hypot(x, y) or 1.0
    return x / d, y / d


def _sample_rounded(pts, closed, warn):
    """Samples (x, y, tx, ty) along a rounded polyline with no sharp vertices."""
    n = len(pts)
    out = []
    idx = range(n) if closed else range(1, n - 1)
    if not closed:
        x0, y0, _ = pts[0]
        tx, ty = _norm(pts[1][0] - x0, pts[1][1] - y0)
        out.append((x0, y0, tx, ty))
    for i in idx:
        ax, ay, _ = pts[i - 1]
        bx, by, r = pts[i]
        cx, cy, _ = pts[(i + 1) % n]
        u1 = _norm(bx - ax, by - ay)
        u2 = _norm(cx - bx, cy - by)
        cross = u1[0] * u2[1] - u1[1] * u2[0]
        dot = u1[0] * u2[0] + u1[1] * u2[1]
        turn = math.atan2(cross, dot)
        d = r * math.tan(abs(turn) / 2)
        if warn is not None:
            la, lc = math.hypot(bx - ax, by - ay), math.hypot(cx - bx, cy - by)
            # an edge ending at an open-path endpoint can give its full length to one corner
            fa = 1.0 if (not closed and i - 1 == 0) else 0.5
            fc = 1.0 if (not closed and i + 1 == n - 1) else 0.5
            if d > la * fa + 0.01 or d > lc * fc + 0.01:
                warn.append(f"corner ({bx},{by}) r={r} needs {d:.1f} > half edge {min(la, lc) / 2:.1f}")
        t1 = (bx - u1[0] * d, by - u1[1] * d)
        perp = (-u1[1], u1[0]) if cross >= 0 else (u1[1], -u1[0])
        c = (t1[0] + perp[0] * r, t1[1] + perp[1] * r)
        a1 = math.atan2(t1[1] - c[1], t1[0] - c[0])
        m = max(2, math.ceil(abs(turn) / STEP))
        sgn = 1 if turn >= 0 else -1
        for j in range(m + 1):
            a = a1 + turn * j / m
            out.append((c[0] + r * math.cos(a), c[1] + r * math.sin(a), -sgn * math.sin(a), sgn * math.cos(a)))
    if not closed:
        x1, y1, _ = pts[-1]
        tx, ty = _norm(x1 - pts[-2][0], y1 - pts[-2][1])
        out.append((x1, y1, tx, ty))
    return out


def _sample_ellipse(c, r, a0, a1):
    cx, cy = c
    rx, ry = r
    t0, t1 = math.radians(a0), math.radians(a1)
    m = max(4, math.ceil(abs(t1 - t0) / STEP))
    full = abs(abs(a1 - a0) - 360) < 1e-6
    out = []
    for j in range(m if full else m + 1):
        t = t0 + (t1 - t0) * j / m
        tx, ty = _norm(-rx * math.sin(t), ry * math.cos(t))
        out.append((cx + rx * math.cos(t), cy + ry * math.sin(t), tx, ty))
    return out, full


def _area(c):
    return 0.5 * sum(c[i][0] * c[(i + 1) % len(c)][1] - c[(i + 1) % len(c)][0] * c[i][1] for i in range(len(c)))


def _orient(c, positive=True):
    return c if (_area(c) > 0) == positive else c[::-1]


def _offset(samples, h, k):
    left = [(x * k + ty * h, y * k - tx * h) for x, y, tx, ty in samples]
    right = [(x * k - ty * h, y * k + tx * h) for x, y, tx, ty in samples]
    return left, right


def _cap(cx, cy, fx, fy, tx, ty, h):
    """Semicircle from point (fx, fy) around (cx, cy), bulging toward direction (tx, ty)."""
    a0 = math.atan2(fy - cy, fx - cx)
    # pick rotation sense whose midpoint lies along (tx, ty)
    mid = a0 + math.pi / 2
    s = 1 if (math.cos(mid) * tx + math.sin(mid) * ty) > 0 else -1
    return [(cx + h * math.cos(a0 + s * math.pi * j / 12), cy + h * math.sin(a0 + s * math.pi * j / 12)) for j in range(1, 12)]


def _stroke_open(samples, k, h):
    left, right = _offset(samples, h, k)
    ex, ey, etx, ety = samples[-1]
    sx, sy, stx, sty = samples[0]
    c = list(left)
    c += _cap(ex * k, ey * k, left[-1][0], left[-1][1], etx, ety, h)
    c += right[::-1]
    c += _cap(sx * k, sy * k, right[0][0], right[0][1], -stx, -sty, h)
    return [_orient(c)]


def _stroke_closed(samples, k, h):
    left, right = _offset(samples, h, k)
    outer, inner = (left, right) if abs(_area(left)) > abs(_area(right)) else (right, left)
    return [_orient(outer, True), _orient(inner, False)]


def _fill_outline(samples, k, g):
    """Closed fill outline grown by g (negative shrinks)."""
    left, right = _offset(samples, abs(g), k)
    big, small = (left, right) if abs(_area(left)) > abs(_area(right)) else (right, left)
    return [_orient(big if g >= 0 else small)]


def contours(sp, k, w, w_ref, warn=None):
    """Closed polygons (lists of (x, y)) for one spec at scale k and stroke w."""
    h = w / 2
    g = (w - w_ref) * 0.35  # fills grow/shrink a little with weight, like SF glyph counters
    t = sp["t"]
    if t == "path":
        pts = sp["pts"]
        sharp = [i for i, p in enumerate(pts) if p[2] == 0 and (sp["closed"] or 0 < i < len(pts) - 1)]
        if not sharp:
            s = _sample_rounded(pts, sp["closed"], warn)
            return _stroke_closed(s, k, h) if sp["closed"] else _stroke_open(s, k, h)
        if sp["closed"]:
            i0 = sharp[0]
            pts = pts[i0:] + pts[:i0] + [pts[i0]]
            sharp = [i for i, p in enumerate(pts) if p[2] == 0]
        else:
            sharp = [0] + sharp + [len(pts) - 1]
        out = []
        for a, b in zip(sharp, sharp[1:]):
            seg = pts[a:b + 1]
            out += _stroke_open(_sample_rounded(seg, False, warn), k, h)
        return out
    if t == "ellipse":
        s, full = _sample_ellipse(sp["c"], sp["r"], *sp["a"])
        return _stroke_closed(s, k, h) if full else _stroke_open(s, k, h)
    if t == "disc":
        cx, cy = sp["c"]
        rx, ry = sp["r"]
        m = 48
        return [_orient([(cx * k + (rx * k + g) * math.cos(2 * math.pi * j / m),
                          cy * k + (ry * k + g) * math.sin(2 * math.pi * j / m)) for j in range(m)])]
    if t == "fill":
        return _fill_outline(_sample_rounded(sp["pts"], True, warn), k, h + g)
    if t == "rrect":
        x0, y0, x1, y1 = sp["box"]
        r = sp["rr"]
        s = _sample_rounded([(x0, y0, r), (x1, y0, r), (x1, y1, r), (x0, y1, r)], True, None)
        return _fill_outline(s, k, g)
    if t == "poly":
        pts = [(x * k, y * k) for x, y in sp["pts"]]
        pts = _orient(pts)
        n = len(pts)
        out = []
        for i in range(n):
            ax, ay = pts[i - 1]
            bx, by = pts[i]
            cx, cy = pts[(i + 1) % n]
            n1 = _norm(by - ay, -(bx - ax))
            n2 = _norm(cy - by, -(cx - bx))
            bis = _norm(n1[0] + n2[0], n1[1] + n2[1])
            cosh = max(0.3, bis[0] * n1[0] + bis[1] * n1[1])
            # outward normal for a positive (counter-clockwise in y-down = clockwise visually) polygon
            out.append((bx - bis[0] * g / cosh, by - bis[1] * g / cosh))
        return [_orient(out)]
    raise ValueError(t)
