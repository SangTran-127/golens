"""Multicolor Go gopher family (go, go-test, go-generated), called from build.py.

The gopher is filled, flat artwork, not a centre-line glyph, so it lives outside icons.py. Original drawing
after the Go gopher by Renee French (CC BY 4.0), proportions from her model sheet; nothing traced.

Design grid: 32 x 32 units = 16 pt (1 unit = 0.5 px at 1x), y down. Eye holes (4 px, 1 px apart), pupils
(2.4 px, offset toward the nose) and the eye line land on whole pixels at 1x because the whole glyph is shifted half a pixel up-left.

Outputs per icon:
  template/<name>.svg/.pdf                  one-color cut-out silhouette (template image: Colored off, selection)
  template/<name>-color-<variant>.svg/.pdf  multicolor artwork, variant = light, dark, light-hc, dark-hc
  symbols/<name>.svg                        SF Symbols template with the silhouette (one layer, all weights)
Colors come from palette.json ("multicolor" -> "gopher").
"""
import json
import math
import os
import subprocess

import pathops
from fontTools.misc.transform import Transform
from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen
from fontTools.svgLib.path import parse_path

NAMES = ("go", "go-test", "go-generated")
VARIANTS = ("light", "dark", "light-hc", "dark-hc")
GAP = 2.4      # clear gap around a badge: 1.2 px at 1x
STROKE = 3.1   # badge stroke, crisp at 12-16 pt


# ---------------------------------------------------------------- path helpers
def circ(cx, cy, r):
    return f"M{cx - r:g} {cy:g}a{r:g} {r:g} 0 1 0 {2 * r:g} 0a{r:g} {r:g} 0 1 0 {-2 * r:g} 0Z"


def ell(cx, cy, rx, ry):
    return f"M{cx - rx:g} {cy:g}a{rx:g} {ry:g} 0 1 0 {2 * rx:g} 0a{rx:g} {ry:g} 0 1 0 {-2 * rx:g} 0Z"


def rrect(x, y, w, h, r):
    return (f"M{x + r:g} {y:g}H{x + w - r:g}A{r:g} {r:g} 0 0 1 {x + w:g} {y + r:g}V{y + h - r:g}"
            f"A{r:g} {r:g} 0 0 1 {x + w - r:g} {y + h:g}H{x + r:g}A{r:g} {r:g} 0 0 1 {x:g} {y + h - r:g}"
            f"V{y + r:g}A{r:g} {r:g} 0 0 1 {x + r:g} {y:g}Z")


def path(d, t=Transform()):
    p = pathops.Path()
    parse_path(d, TransformPen(p.getPen(), t))
    return p


def union(paths):
    out = pathops.Path()
    for q in paths:
        out = pathops.op(out, q, pathops.PathOp.UNION)
    return out


def minus(a, b):
    return pathops.op(a, b, pathops.PathOp.DIFFERENCE)


def to_d(p, t=Transform()):
    pen = SVGPathPen(None, ntos=lambda v: f"{round(v, 3):g}")
    p.draw(TransformPen(pen, t))
    return pen.getCommands()


def poly(pts, close=True):
    p = pathops.Path()
    pen = p.getPen()
    pen.moveTo(pts[0])
    for q in pts[1:]:
        pen.lineTo(q)
    pen.closePath() if close else pen.endPath()
    return p


def stroked(p, w):
    q = pathops.Path(p)
    q.stroke(w, pathops.LineCap.ROUND_CAP, pathops.LineJoin.ROUND_JOIN, 4)
    q.convertConicsToQuads()
    return pathops.simplify(q)


# ---------------------------------------------------------------- artwork
def gopher():
    """Layers back to front as (role, Path). Clean bust silhouette (no tiny protruding limbs at 12pt),
    top ears, big eyes, tan muzzle with buck teeth."""
    sh = Transform().translate(-1, -1)
    body = ("M16 3C22.6 3 26.2 7.2 26.2 12.6L26.5 24.2C26.5 28.0 22.4 30.0 16 30.0"
            "C9.6 30.0 5.5 28.0 5.5 24.2L5.8 12.6C5.8 7.2 9.4 3 16 3Z")
    return [
        ("ear", union([path(circ(8, 5.6, 2.4), sh), path(circ(24, 5.6, 2.4), sh)])),
        ("body", path(body, sh)),
        ("eye", union([path(circ(11, 11, 4), sh), path(circ(21, 11, 4), sh)])),
        # Pupils look in toward the nose: centred pupils in ring-shaped eyes read as a fixed stare.
        ("pupil", union([path(circ(12, 11.5, 2.4), sh), path(circ(20, 11.5, 2.4), sh)])),
        ("muzzle", path(ell(16, 18.2, 3.6, 2.5), sh)),
        ("teeth", path(rrect(14.3, 18.2, 3.4, 3.4, 0.8), sh)),
        ("nose", path(ell(16, 16.7, 2.3, 1.4), sh)),
    ]


def check():
    return stroked(poly([(19.6, 25.2), (23.2, 28.6), (29.4, 21.4)], close=False), STROKE)


def gear(cx=25.0, cy=25.0):
    teeth = []
    for i in range(8):
        a = math.radians(i * 45)
        ux, uy, vx, vy = math.cos(a), math.sin(a), -math.sin(a), math.cos(a)
        r0, r1, hw = 3.5, 6.0, 1.15
        teeth.append(poly([(cx + ux * r0 + vx * hw, cy + uy * r0 + vy * hw), (cx + ux * r1 + vx * hw, cy + uy * r1 + vy * hw),
                           (cx + ux * r1 - vx * hw, cy + uy * r1 - vy * hw), (cx + ux * r0 - vx * hw, cy + uy * r0 - vy * hw)]))
    return minus(union([path(circ(cx, cy, 4.3))] + teeth), path(circ(cx, cy, 1.8)))


BADGES = {"go": None, "go-test": check, "go-generated": gear}


def snowflake(cx=25.0, cy=25.0):
    arms = []
    for i in range(6):
        a = math.radians(i * 60)
        ux, uy = math.cos(a), math.sin(a)
        arms.append(stroked(poly([(cx - ux * 5.8, cy - uy * 5.8), (cx + ux * 5.8, cy + uy * 5.8)], close=False), 1.9))
    return union(arms + [path(circ(cx, cy, 2.4))])


def blossom(cx=25.0, cy=25.0):
    petals = []
    for i in range(5):
        a = math.radians(i * 72 - 90)
        px = cx + math.cos(a) * 3.1
        py = cy + math.sin(a) * 3.1
        petals.append(path(circ(px, py, 2.25)))
    return minus(union(petals), path(circ(cx, cy, 1.25)))


def base_seasonal_parts(fangs=False, dy=3.2):
    sh = Transform().translate(-1, -1 + dy)
    body = ("M16 4.2C22.4 4.2 26.0 8.0 26.0 13.0L26.5 23.2C26.5 27.1 22.3 29.3 16 29.3"
            "C9.7 29.3 5.5 27.1 5.5 23.2L6.0 13.0C6.0 8.0 9.6 4.2 16 4.2Z")
    rot = lambda a, cx, cy: sh.translate(cx, cy).rotate(math.radians(a)).translate(-cx, -cy)
    if fangs:
        teeth_path = union([
            poly([(12.4, 16.8 + dy), (13.8, 21.3 + dy), (15.0, 17.2 + dy)]),
            poly([(15.0, 17.2 + dy), (16.2, 21.3 + dy), (17.6, 16.8 + dy)]),
        ])
    else:
        teeth_path = path(rrect(14.3, 18.0, 3.4, 3.3, 0.8), sh)
    return [
        ("ear", union([path(circ(7.6, 7.2, 2.2), sh), path(circ(24.4, 7.2, 2.2), sh)])),
        ("body", path(body, sh)),
        ("eye", union([path(circ(11, 11.6, 3.8), sh), path(circ(21, 11.6, 3.8), sh)])),
        ("pupil", union([path(circ(12, 12.1, 2.25), sh), path(circ(20, 12.1, 2.25), sh)])),
        ("muzzle", path(ell(16, 18.2, 3.5, 2.3), sh)),
        ("teeth", teeth_path),
        ("nose", path(ell(16, 16.7, 2.15, 1.3), sh)),
    ]


def halloween_gopher():
    parts = base_seasonal_parts(fangs=True, dy=3.2)
    cone = poly([(9.0, 7.2), (12.2, 0.4), (19.6, -1.8), (17.0, 2.2), (21.2, 7.2)])
    brim = path(ell(15.0, 7.2, 11.4, 1.85), Transform().translate(15, 7.2).rotate(math.radians(-6)).translate(-15, -7.2))
    band = path(rrect(9.5, 5.1, 11.0, 1.6, 0.5), Transform().translate(15, 5.9).rotate(math.radians(-6)).translate(-15, -5.9))
    buckle = minus(
        path(rrect(13.2, 4.5, 3.6, 2.6, 0.5), Transform().translate(15, 5.8).rotate(math.radians(-6)).translate(-15, -5.8)),
        path(rrect(14.1, 5.1, 1.8, 1.4, 0.2), Transform().translate(15, 5.8).rotate(math.radians(-6)).translate(-15, -5.8)),
    )
    return parts + [("hat", union([cone, brim])), ("hat_band", union([band, buckle]))]


def noel_gopher():
    parts = base_seasonal_parts(fangs=False, dy=3.2)
    cheeks = union([path(ell(7.5, 18.6, 1.8, 1.1)), path(ell(22.5, 18.6, 1.8, 1.1))])
    cap = path("M7.2 7.2 C8.5 -0.8 16.5 -2.2 22.8 1.2 C25.6 2.8 27.0 5.8 27.2 9.0 L22.5 7.2 L7.2 7.2 Z")
    brim = union([
        path(rrect(6.2, 5.5, 17.2, 3.1, 1.5), Transform().translate(15, 7.0).rotate(math.radians(-4)).translate(-15, -7.0)),
        path(circ(7.4, 7.2, 1.65)),
        path(circ(14.8, 6.8, 1.65)),
        path(circ(22.2, 6.4, 1.65)),
    ])
    pom = path(circ(27.2, 9.5, 2.6))
    return parts + [("cheek", cheeks), ("santa_cap", cap), ("santa_trim", union([brim, pom]))]


def tet_gopher():
    parts = base_seasonal_parts(fangs=False, dy=3.2)
    cheeks = union([path(ell(7.5, 18.6, 1.8, 1.1)), path(ell(22.5, 18.6, 1.8, 1.1))])
    turban_outer = path(rrect(5.8, 1.2, 18.4, 6.6, 3.1))
    turban_top = path(rrect(8.2, -1.2, 13.6, 4.4, 2.2))
    wings = union([
        path(rrect(2.4, 2.8, 4.4, 2.0, 1.0)),
        path(rrect(23.2, 2.8, 4.4, 2.0, 1.0)),
    ])
    hat = union([turban_outer, turban_top, wings])
    gold_band = path(rrect(6.8, 5.4, 16.4, 1.8, 0.9))
    coin = minus(
        path(circ(15.0, 3.8, 2.5)),
        poly([(15.0, 2.6), (16.2, 3.8), (15.0, 5.0), (13.8, 3.8)]),
    )
    return parts + [("cheek", cheeks), ("tet_hat", hat), ("tet_gold", union([gold_band, coin]))]


def seasonal_family(name, season):
    if season == "halloween":
        layers = halloween_gopher()
        gen_badge = gear
    elif season == "noel":
        layers = noel_gopher()
        gen_badge = snowflake
    else:
        layers = tet_gopher()
        gen_badge = blossom
    make = {"go": None, "go-test": check, "go-generated": gen_badge}[name]
    if not make:
        return layers, None
    badge = make()
    cut = union([stroked(badge, 2 * GAP), badge])
    return [(r, minus(p, cut)) for r, p in layers], badge


def seasonal_colors(season, name, variant, spec):
    c = colors(variant, spec)
    is_dark = "dark" in variant
    is_hc = "hc" in variant
    if season == "halloween":
        if is_dark:
            c["hat"] = "#CE93FF" if is_hc else "#B366FF"
            c["hat_band"] = "#FFD166" if is_hc else "#FF9F43"
            c["badge"] = "#FFD166" if is_hc else "#FF9F43"
        else:
            c["hat"] = "#3B155A" if is_hc else "#4A206D"
            c["hat_band"] = "#B45309" if is_hc else "#D97706"
            c["badge"] = "#9A3412" if is_hc else "#C86400"
    elif season == "noel":
        c["cheek"] = "#FF758F"
        c["santa_cap"] = ("#FF6B78" if is_hc else "#F04754") if is_dark else ("#B91C1C" if is_hc else "#D62828")
        c["santa_trim"] = "#FFFFFF"
        if name == "go-generated":
            c["badge"] = ("#FFE082" if is_hc else "#FFD166") if is_dark else ("#92400E" if is_hc else "#B8860B")
        else:
            c["badge"] = ("#74C69D" if is_hc else "#52B788") if is_dark else ("#1B4332" if is_hc else "#2D6A4F")
    else:
        c["cheek"] = "#FF758F"
        c["tet_hat"] = ("#FF6B78" if is_hc else "#F04754") if is_dark else ("#B91C1C" if is_hc else "#D62828")
        c["tet_gold"] = ("#FFE082" if is_hc else "#FFD166") if is_dark else ("#92400E" if is_hc else "#B8860B")
        if name == "go-generated":
            c["badge"] = ("#FFE082" if is_hc else "#FFD166") if is_dark else ("#92400E" if is_hc else "#B8860B")
        else:
            c["badge"] = ("#74C69D" if is_hc else "#52B788") if is_dark else ("#1B4332" if is_hc else "#2D6A4F")
    return c


def silhouette(layers):
    """One color: eye whites and the nose are holes, pupils are filled inside the eye holes; muzzle and teeth
    merge into the body (a teeth hole reads as a gaping mouth at this size)."""
    pick = lambda roles: union([p for r, p in layers if r in roles])
    return union([minus(pick(("body", "ear")), pick(("eye", "nose"))), pick(("pupil",))])


def family(name):
    """(colored layers, silhouette, badge or None) with the badge's clear gap already cut."""
    layers = gopher()
    mono = silhouette(layers)
    make = BADGES[name]
    if not make:
        return layers, mono, None
    badge = make()
    cut = union([stroked(badge, 2 * GAP), badge])
    return [(r, minus(p, cut)) for r, p in layers], union([minus(mono, cut), badge]), badge


# ---------------------------------------------------------------- writers
def svg(title, inner, viewbox="0 0 32 32"):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="{viewbox}">'
            f"<title>{title}</title>{inner}</svg>\n")


def colors(variant, spec, name="go"):
    body = spec["body"][variant]
    is_dark = "dark" in variant
    is_hc = "hc" in variant
    if name == "go-test":
        badge = ("#6EE7B7" if is_hc else "#34D399") if is_dark else ("#047857" if is_hc else "#059669")
    elif name == "go-generated":
        badge = ("#FDE047" if is_hc else "#FBBF24") if is_dark else ("#92400E" if is_hc else "#D97706")
    else:
        badge = spec["badge"][variant]
    return {"body": body, "ear": body, "arm": spec["tan"][variant], "foot": spec["tan"][variant],
            "muzzle": spec["tan"][variant], "eye": spec["eyeWhite"], "teeth": spec["teeth"],
            "pupil": spec["pupil"], "nose": spec["nose"], "badge": badge}


def symbol(name, label, mono, build):
    """SF Symbols template: the silhouette as one primary layer, identical in all three masters."""
    styles = [(".hierarchical-0:primary", build.STYLE_ROW), (".monochrome-0", build.STYLE_ROW),
              (".multicolor-0:tintColor", build.STYLE_ROW)]
    k = build.VIEW / 32 * build.K_S
    groups, margins = [], []
    for weight in ("Black", "Regular", "Ultralight"):
        x0, _, x1, _ = mono.bounds
        minx = (x0 - 16) * k
        adv = (x1 - x0) * k + 2 * build.BEARING_S
        left = build.COL[weight] - adv / 2
        t = Transform().translate(build.BEARING_S - minx, build.CAP_MID).scale(k).translate(-16, -16)
        margins.append(f'  <line id="left-margin-{weight}-S" {build.MARGIN} x1="{build.fmt(left)}" x2="{build.fmt(left)}" y1="600.785" y2="720.121"/>')
        margins.append(f'  <line id="right-margin-{weight}-S" {build.MARGIN} x1="{build.fmt(left + adv)}" x2="{build.fmt(left + adv)}" y1="600.785" y2="720.121"/>')
        groups.append(f'  <g id="{weight}-S" transform="matrix(1 0 0 1 {build.fmt(left)} 696)">\n'
                      f'   <path class="monochrome-0 multicolor-0:tintColor hierarchical-0:primary SFSymbolsPreviewWireframe" d="{to_d(mono, t)}"/>\n  </g>')
    return build.symbol_doc(name, label, styles, groups, margins)


def write(root, rsvg, labels, build, preview):
    spec = json.load(open(os.path.join(root, "palette.json")))["multicolor"]["gopher"]
    out = []

    def emit(base, text):
        p = os.path.join(root, "template", base + ".svg")
        open(p, "w").write(text)
        if rsvg:
            subprocess.run([rsvg, "-f", "pdf", "-d", "72", "-p", "72", "-o", p[:-3] + "pdf", p], check=True)
        out.append(base)

    to120 = Transform().scale(build.VIEW / 32).translate(-16, -16)
    for name in NAMES:
        layers, mono, badge = family(name)
        emit(name, svg(labels[name], f'<path d="{to_d(mono)}"/>'))
        for v in VARIANTS:
            c = colors(v, spec, name)
            inner = "".join(f'<path id="{r}" fill="{c[r]}" d="{to_d(p)}"/>' for r, p in layers)
            if badge:
                inner += f'<path id="badge" fill="{c["badge"]}" d="{to_d(badge)}"/>'
            emit(f"{name}-color-{v}", svg(labels[name], inner))
        for season in ("halloween", "noel", "tet"):
            s_layers, s_badge = seasonal_family(name, season)
            for v in VARIANTS:
                sc = seasonal_colors(season, name, v, spec)
                s_inner = "".join(f'<path id="{r}" fill="{sc[r]}" d="{to_d(p)}"/>' for r, p in s_layers)
                if s_badge:
                    s_inner += f'<path id="badge" fill="{sc["badge"]}" d="{to_d(s_badge)}"/>'
                emit(f"{name}-{season}-color-{v}", svg(labels[name], s_inner, "0 -3 32 35"))
        open(os.path.join(root, "symbols", f"{name}.svg"), "w").write(symbol(name, labels[name], mono, build))
        b = mono.bounds
        preview[name] = {"label": labels[name], "mono": to_d(mono, to120), "primary": to_d(mono, to120), "secondary": "",
                         "bounds": [round((v - 16) * build.VIEW / 32, 1) for v in b]}
    return out
