"""Generate symbols/, template/ and preview data for the GoLens file-icon set.

Run:  python3 tools/build.py      (needs `pip install skia-pathops`; PDFs need rsvg-convert)
"""
import json
import os
import shutil
import subprocess
import sys

import pathops

sys.path.insert(0, os.path.dirname(__file__))
from geometry import contours  # noqa: E402
from icons import LABELS, build  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
K_S = 0.783            # Small scale relative to Medium (measured from system `doc`)
W_S = {"Ultralight": 1.8, "Regular": 7.4, "Black": 12.0}   # stroke at Small scale
COL = {"Ultralight": 559.711, "Regular": 1449.84, "Black": 2933.4}
W_M = 8.4              # Regular stroke at Medium scale (fallback artwork)
BEARING_S = 10.5
CAP_MID = -35.2295     # optical centre = half cap height above baseline
VIEW = 120             # fallback artboard: 120 template units == 16 pt


def fmt(v):
    s = f"{v:.3f}".rstrip("0").rstrip(".")
    return "0" if s in ("-0", "") else s


def d_of(cs, dx=0.0, dy=0.0):
    return "".join("M" + "L".join(f"{fmt(x + dx)} {fmt(y + dy)}" for x, y in c) + "Z" for c in cs)


def layer_contours(layers, k, w, w_ref, warn=None):
    return [(role, [c for sp in specs for c in contours(sp, k, w, w_ref, warn)]) for role, specs in layers]


# ---------------------------------------------------------------- pathops flattening
def to_path(cs):
    p = pathops.Path()
    for c in cs:
        p.moveTo(*c[0])
        for pt in c[1:]:
            p.lineTo(*pt)
        p.close()
    return p


def path_d(p):
    out = []
    for verb, pts in p.segments:
        if verb == "moveTo":
            out.append(f"M{fmt(pts[0][0])} {fmt(pts[0][1])}")
        elif verb == "lineTo":
            out.append(f"L{fmt(pts[0][0])} {fmt(pts[0][1])}")
        elif verb == "qCurveTo":
            out.append("Q" + " ".join(f"{fmt(x)} {fmt(y)}" for x, y in pts))
        elif verb == "curveTo":
            out.append("C" + " ".join(f"{fmt(x)} {fmt(y)}" for x, y in pts))
        elif verb in ("closePath", "endPath"):
            out.append("Z")
    return "".join(out)


def flatten(lc):
    """Apply erase layers geometrically; return {'primary': Path, 'secondary': Path}."""
    acc = {"primary": pathops.Path(), "secondary": pathops.Path()}
    for role, cs in lc:
        p = to_path(cs)
        if role == "erase":
            for key in acc:
                acc[key] = pathops.op(acc[key], p, pathops.PathOp.DIFFERENCE)
        else:
            acc[role] = pathops.op(acc[role], p, pathops.PathOp.UNION)
    return acc


# ---------------------------------------------------------------- SF Symbols template
STYLE_ROW = "{-sfsymbols-motion-group:0}"
ERASE_ROW = "{opacity:0.0;-sfsymbols-clear-behind:true;-sfsymbols-motion-group:0}"
H_REF = ('<path d="M0.993654 0L3.63775 0L29.3281-67.1323L30.0303-67.1323L30.0303-70.459L28.1226-70.459Z'
         'M11.6885-24.4799L46.9815-24.4799L46.2315-26.7285L12.4385-26.7285ZM55.1196 0L57.7637 0L30.6382-70.459'
         'L29.4326-70.459L29.4326-67.1323Z"/>')
GUIDE = 'style="fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;"'
MARGIN = 'style="fill:none;stroke:#00AEEF;stroke-width:0.5;opacity:1.0;"'
TEXT = 'style="stroke:none;fill:black;font-family:sans-serif;font-size:13;'


def symbol_svg(name, layers, warn):
    roles = [r for r, _ in layers]
    styles = []
    for i, role in enumerate(roles):
        level = "secondary" if role == "secondary" else "primary"
        row = ERASE_ROW if role == "erase" else STYLE_ROW
        styles.append((f".monochrome-{i}", row))
        styles.append((f".multicolor-{i}:tintColor", row))
        styles.append((f".hierarchical-{i}:{level}", row))
    styles.sort(key=lambda s: (s[0].split("-")[0], s[0]))
    groups, margins = [], []
    for weight in ("Black", "Regular", "Ultralight"):
        lc = layer_contours(layers, K_S, W_S[weight], W_S["Regular"], warn if weight == "Regular" else None)
        ink = [pt for role, cs in lc if role != "erase" for c in cs for pt in c]
        minx, maxx = min(p[0] for p in ink), max(p[0] for p in ink)
        adv = maxx - minx + 2 * BEARING_S
        left = COL[weight] - adv / 2
        margins.append(f'  <line id="left-margin-{weight}-S" {MARGIN} x1="{fmt(left)}" x2="{fmt(left)}" y1="600.785" y2="720.121"/>')
        margins.append(f'  <line id="right-margin-{weight}-S" {MARGIN} x1="{fmt(left + adv)}" x2="{fmt(left + adv)}" y1="600.785" y2="720.121"/>')
        paths = []
        for i, (role, cs) in enumerate(lc):
            level = "secondary" if role == "secondary" else "primary"
            cls = f"monochrome-{i} multicolor-{i}:tintColor hierarchical-{i}:{level} SFSymbolsPreviewWireframe"
            paths.append(f'   <path class="{cls}" d="{d_of(cs, BEARING_S - minx, CAP_MID)}"/>')
        groups.append(f'  <g id="{weight}-S" transform="matrix(1 0 0 1 {fmt(left)} 696)">\n' + "\n".join(paths) + "\n  </g>")
    return symbol_doc(name, LABELS[name], styles, groups, margins)


def symbol_doc(name, label, styles, groups, margins):
    labels = "\n".join(
        f'  <text {TEXT}text-anchor:middle;" transform="matrix(1 0 0 1 {x} 322)">{n}</text>'
        for n, x in (("Ultralight", 559.711), ("Thin", 856.422), ("Light", 1153.13), ("Regular", 1449.84), ("Medium", 1746.56),
                     ("Semibold", 2043.27), ("Bold", 2339.98), ("Heavy", 2636.69), ("Black", 2933.4)))
    guides = []
    for scale, base in (("S", 696), ("M", 1126), ("L", 1556)):
        guides.append(f'  <g id="H-reference" style="fill:#27AAE1;stroke:none;" transform="matrix(1 0 0 1 339 {base})">\n   {H_REF}\n  </g>')
        guides.append(f'  <line id="Baseline-{scale}" {GUIDE} x1="263" x2="3036" y1="{base}" y2="{base}"/>')
        guides.append(f'  <line id="Capline-{scale}" {GUIDE} x1="263" x2="3036" y1="{fmt(base - 70.459)}" y2="{fmt(base - 70.459)}"/>')
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd">
<svg version="1.1" xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="3300" height="2200">
 <!--glyph: "", point size: 100.0, template writer version: "golens-file-icons 1"-->
 <!--golens.{name}: {label}. Original artwork for GoLens; see design/file-icons/README.md (Attribution).-->
 <style>.defaults {{-sfsymbols-variable-value-mode:color;-sfsymbols-draw-reverses-motion-groups:true}}
{chr(10).join(f"{k} {v}" for k, v in styles)}
.SFSymbolsPreviewWireframe {{fill:none;opacity:1.0;stroke:black;stroke-width:0.5}}
</style>
 <g id="Notes">
  <rect height="2200" id="artboard" style="fill:white;opacity:1" width="3300" x="0" y="0"/>
  <line style="fill:none;stroke:black;opacity:1;stroke-width:0.5;" x1="263" x2="3036" y1="292" y2="292"/>
  <text {TEXT}font-weight:bold;" transform="matrix(1 0 0 1 263 322)">Weight/Scale Variations</text>
{labels}
  <line style="fill:none;stroke:black;opacity:1;stroke-width:0.5;" x1="263" x2="3036" y1="1903" y2="1903"/>
  <text {TEXT}font-weight:bold;" transform="matrix(1 0 0 1 263 1953)">golens.{name}</text>
  <text {TEXT}" transform="matrix(1 0 0 1 263 1971)">{label}</text>
  <text id="template-version" {TEXT}text-anchor:end;" transform="matrix(1 0 0 1 3036 1933)">Template v.6.0</text>
  <text {TEXT}text-anchor:end;" transform="matrix(1 0 0 1 3036 1951)">Requires Xcode 16 or greater</text>
  <text id="descriptive-name" {TEXT}text-anchor:end;" transform="matrix(1 0 0 1 3036 1969)">golens.{name}</text>
  <text {TEXT}text-anchor:end;" transform="matrix(1 0 0 1 3036 1987)">Typeset at 100 points</text>
  <text {TEXT}" transform="matrix(1 0 0 1 263 726)">Small</text>
  <text {TEXT}" transform="matrix(1 0 0 1 263 1156)">Medium</text>
  <text {TEXT}" transform="matrix(1 0 0 1 263 1586)">Large</text>
 </g>
 <g id="Guides">
{chr(10).join(guides)}
{chr(10).join(margins)}
 </g>
 <g id="Symbols">
{chr(10).join(groups)}
 </g>
</svg>
"""


def template_svg(name, d):
    h = VIEW / 2
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="{-h} {-h} {VIEW} {VIEW}">'
            f"<title>{LABELS[name]}</title><path d=\"{d}\"/></svg>\n")


def main():
    icons = build()
    rsvg = shutil.which("rsvg-convert")
    preview = {}
    problems = {}
    for name, layers in icons.items():
        warn = []
        open(os.path.join(ROOT, "symbols", f"{name}.svg"), "w").write(symbol_svg(name, layers, warn))
        flat = flatten(layer_contours(layers, 1.0, W_M, W_M))
        mono = pathops.op(flat["primary"], flat["secondary"], pathops.PathOp.UNION)
        b = mono.bounds
        if max(abs(v) for v in b) > VIEW / 2 - 1:
            warn.append(f"ink {tuple(round(v) for v in b)} exceeds artboard")
        svg_path = os.path.join(ROOT, "template", f"{name}.svg")
        open(svg_path, "w").write(template_svg(name, path_d(mono)))
        if rsvg:
            subprocess.run([rsvg, "-f", "pdf", "-d", "72", "-p", "72", "-o", svg_path[:-3] + "pdf", svg_path], check=True)
        preview[name] = {"label": LABELS[name], "mono": path_d(mono),
                         "primary": path_d(flat["primary"]), "secondary": path_d(flat["secondary"]),
                         "bounds": [round(v, 1) for v in b]}
        if warn:
            problems[name] = warn
    import gopher
    gopher.write(ROOT, rsvg, LABELS, sys.modules[__name__], preview)
    json.dump(preview, open(os.path.join(ROOT, "tools", "preview-data.json"), "w"))
    for n, w in problems.items():
        print(n, *w, sep="\n  ")
    print(f"{len(icons) + len(gopher.NAMES)} icons written")


if __name__ == "__main__":
    main()
