"""Generate the GoLens Seasonal Icon Themes Showcase (Default vs. Halloween vs. Noel/Winter).

Run:  /tmp/golens-icons-venv/bin/python design/symbol-icons/tools/seasonal_showcase.py
"""
import html
import json
import math
import os
import subprocess
import sys

import pathops
from fontTools.misc.transform import Transform

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
FILE_ICONS_ROOT = os.path.join(ROOT, "..", "file-icons")
sys.path.insert(0, os.path.join(FILE_ICONS_ROOT, "tools"))

from gopher import GAP, STROKE, check, circ, ell, gear, minus, path, poly, rrect, stroked, to_d, union  # noqa: E402

file_data = json.load(open(os.path.join(FILE_ICONS_ROOT, "tools", "preview-data.json")))
sym_data = json.load(open(os.path.join(HERE, "preview-data.json")))


def base_gopher_parts(fangs=False, dy=2.2):
    sh = Transform().translate(-1, -1 + dy)
    body = (
        "M16 4.2C22.4 4.2 26.0 8.0 26.0 13.0L26.5 23.2C26.5 27.1 22.3 29.3 16 29.3"
        "C9.7 29.3 5.5 27.1 5.5 23.2L6.0 13.0C6.0 8.0 9.6 4.2 16 4.2Z"
    )
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
        ("arm", union([path(ell(4.8, 18.8, 1.25, 2.0), rot(-30, 4.8, 18.8)), path(ell(27.2, 18.8, 1.25, 2.0), rot(30, 27.2, 18.8))])),
        ("foot", union([path(ell(11, 29.1, 2.4, 1.3), sh), path(ell(21, 29.1, 2.4, 1.3), sh)])),
        ("body", path(body, sh)),
        ("eye", union([path(circ(11, 11.6, 3.8), sh), path(circ(21, 11.6, 3.8), sh)])),
        ("pupil", union([path(circ(12, 12.1, 2.25), sh), path(circ(20, 12.1, 2.25), sh)])),
        ("muzzle", path(ell(16, 18.2, 3.5, 2.3), sh)),
        ("teeth", teeth_path),
        ("nose", path(ell(16, 16.7, 2.15, 1.3), sh)),
    ]


def halloween_gopher():
    """Vampire-Witch Gopher: tall crooked witch hat + gold buckle + sharp vampire fangs."""
    parts = base_gopher_parts(fangs=True, dy=3.2)
    cone = poly([(9.0, 7.2), (12.2, 0.4), (19.6, -1.8), (17.0, 2.2), (21.2, 7.2)])
    brim = path(ell(15.0, 7.2, 11.4, 1.85), Transform().translate(15, 7.2).rotate(math.radians(-6)).translate(-15, -7.2))
    band = path(rrect(9.5, 5.1, 11.0, 1.6, 0.5), Transform().translate(15, 5.9).rotate(math.radians(-6)).translate(-15, -5.9))
    buckle = minus(
        path(rrect(13.2, 4.5, 3.6, 2.6, 0.5), Transform().translate(15, 5.8).rotate(math.radians(-6)).translate(-15, -5.8)),
        path(rrect(14.1, 5.1, 1.8, 1.4, 0.2), Transform().translate(15, 5.8).rotate(math.radians(-6)).translate(-15, -5.8)),
    )
    return parts + [
        ("hat", union([cone, brim])),
        ("hat_band", union([band, buckle])),
    ]


def noel_gopher():
    """Santa Gopher: plush red Santa cap + puffy white fur brim + pom-pom + rosy winter cheeks."""
    parts = base_gopher_parts(fangs=False, dy=3.2)
    cheeks = union([path(ell(7.5, 18.6, 1.8, 1.1)), path(ell(22.5, 18.6, 1.8, 1.1))])
    cap = path("M7.2 7.2 C8.5 -0.8 16.5 -2.2 22.8 1.2 C25.6 2.8 27.0 5.8 27.2 9.0 L22.5 7.2 L7.2 7.2 Z")
    brim = union([
        path(rrect(6.2, 5.5, 17.2, 3.1, 1.5), Transform().translate(15, 7.0).rotate(math.radians(-4)).translate(-15, -7.0)),
        path(circ(7.4, 7.2, 1.65)),
        path(circ(14.8, 6.8, 1.65)),
        path(circ(22.2, 6.4, 1.65)),
    ])
    pom = path(circ(27.2, 9.5, 2.6))
    return parts + [
        ("cheek", cheeks),
        ("santa_cap", cap),
        ("santa_trim", union([brim, pom])),
    ]


def snowflake(cx=25.0, cy=25.0):
    arms = []
    for i in range(6):
        a = math.radians(i * 60)
        ux, uy = math.cos(a), math.sin(a)
        arms.append(stroked(poly([(cx - ux * 5.8, cy - uy * 5.8), (cx + ux * 5.8, cy + uy * 5.8)], close=False), 1.9))
    return union(arms + [path(circ(cx, cy, 2.4))])


def render_gopher_svg(theme, variant_name, size=32):
    if theme == "default":
        from gopher import gopher as orig_gopher
        layers = orig_gopher()
        pal = {
            "ear": "#4CC9EB", "body": "#4CC9EB",
            "arm": "#E8BF94", "foot": "#E8BF94", "muzzle": "#E8BF94",
            "eye": "#FFFFFF", "teeth": "#FFFFFF",
            "pupil": "#1D1D1F", "nose": "#1D1D1F",
            "badge": "#4CC9EB",
        }
        make_badge = {"go": None, "go-test": check, "go-generated": gear}[variant_name]
    elif theme == "halloween":
        layers = halloween_gopher()
        pal = {
            "ear": "#4CC9EB", "body": "#4CC9EB",
            "arm": "#E8BF94", "foot": "#E8BF94", "muzzle": "#E8BF94",
            "eye": "#FFF8E7", "teeth": "#FFFFFF",
            "pupil": "#2D1447", "nose": "#1D1D1F",
            "hat": "#5B2C82", "hat_band": "#FF9F43",
            "badge": "#FF9F43",
        }
        make_badge = {"go": None, "go-test": check, "go-generated": gear}[variant_name]
    else:  # noel
        layers = noel_gopher()
        pal = {
            "ear": "#4CC9EB", "body": "#4CC9EB",
            "arm": "#E8BF94", "foot": "#E8BF94", "muzzle": "#E8BF94",
            "eye": "#FFFFFF", "teeth": "#FFFFFF",
            "pupil": "#1D1D1F", "nose": "#1D1D1F",
            "cheek": "#FF758F",
            "santa_cap": "#E63946", "santa_trim": "#FFFFFF",
            "badge": "#FFD166" if variant_name == "go-generated" else "#52B788",
        }
        make_badge = {"go": None, "go-test": check, "go-generated": snowflake}[variant_name]

    badge = None
    if make_badge:
        badge = make_badge()
        cut = union([stroked(badge, 2 * GAP), badge])
        layers = [(r, minus(p, cut)) for r, p in layers]

    inner = "".join(f'<path fill="{pal[r]}" d="{to_d(p)}"/>' for r, p in layers)
    if badge:
        inner += f'<path fill="{pal["badge"]}" d="{to_d(badge)}"/>'
    vb = "0 0 32 32" if theme == "default" else "0 -3 32 35"
    return f'<svg class="ic" width="{size}" height="{size}" viewBox="{vb}">{inner}</svg>'


SEASONAL_PALETTES = {
    "default": {
        "title": "Default · Classic Go",
        "subtitle": "Cyan Gopher · System Semantic Palette",
        "bg": "#1E1E1E", "card": "#2A2A2D", "sel": "#0A64D2",
        "go": "#4CC9EB", "data": "#C98EF2", "infra": "#9A9CFF", "web": "#F27AC2", "neutral": "#A1A1A6",
    },
    "halloween": {
        "title": "Halloween · Spooky Gopher",
        "subtitle": "Cyan Gopher in Witch Hat · Pumpkin Amber & Slime Green",
        "bg": "#191521", "card": "#251E30", "sel": "#B84A00",
        "go": "#4CC9EB", "data": "#C98EF2", "infra": "#58D68D", "web": "#FF9F43", "neutral": "#B2A8C2",
    },
    "noel": {
        "title": "Noel / Winter · Santa Gopher",
        "subtitle": "Santa Cap Gopher · Frost Cyan, Holly Red, Evergreen & Warm Gold",
        "bg": "#141D24", "card": "#1E2B34", "sel": "#C1292E",
        "go": "#5CE1E6", "data": "#FF758F", "infra": "#52B788", "web": "#FFD166", "neutral": "#A3B8C2",
    },
}


def vec_icon(source_dict, name, color, size=16, hierarchical=False):
    d = source_dict[name]
    if hierarchical and d.get("secondary"):
        return (
            f'<svg class="ic" width="{size}" height="{size}" viewBox="-60 -60 120 120" fill="{color}">'
            f'<path d="{d["secondary"]}" opacity=".45"/><path d="{d["primary"]}"/></svg>'
        )
    return f'<svg class="ic" width="{size}" height="{size}" viewBox="-60 -60 120 120" fill="{color}"><path d="{d["mono"]}"/></svg>'


def build_theme_column(theme_key):
    p = SEASONAL_PALETTES[theme_key]
    gopher_cards = []
    for gname, glabel in (("go", "main.go"), ("go-test", "main_test.go"), ("go-generated", "api.pb.go")):
        gopher_cards.append(
            f'<div class="gcard" style="background:{p["card"]}">'
            f'<div class="grow-top">{render_gopher_svg(theme_key, gname, 76)}</div>'
            f'<div class="grow-sizes">{render_gopher_svg(theme_key, gname, 16)}{render_gopher_svg(theme_key, gname, 32)}</div>'
            f'<div class="gtitle">{gname}</div><div class="gsub">{glabel}</div></div>'
        )

    tree = [
        (0, "v", "folder", "cmd", "neutral", False),
        (1, "", "go", "main.go", "go", False),
        (0, "v", "folder", "pkg/server", "neutral", False),
        (1, "", "go", "handler.go", "go", False),
        (1, "", "go-test", "handler_test.go", "go", False),
        (1, "", "go-generated", "user.pb.go", "go", False),
        (1, "", "pprof", "cpu.pprof", "go", False),
        (1, "", "proto", "user.proto", "data", False),
        (0, "", "docker", "Dockerfile", "infra", False),
        (0, "", "kubernetes", "deployment.yaml", "infra", False),
        (0, "", "go-mod", "go.mod", "go", False),
        (0, "", "markdown", "README.md", "neutral", False),
    ]
    srows = []
    for depth, chev, icon, fname, fam, sel in tree:
        c_char = "&#x2304;" if chev else ""
        if icon in ("go", "go-test", "go-generated"):
            svg_ic = render_gopher_svg(theme_key, icon, 16)
        else:
            svg_ic = vec_icon(file_data, icon, "#FFFFFF" if sel else p[fam], 16)
        bg = f"background:{p['sel']};color:#fff;" if sel else ""
        srows.append(
            f'<div class="srow" style="padding-left:{8 + depth * 14}px;{bg}">'
            f'<span class="chev">{c_char}</span>{svg_ic}<span class="fname">{html.escape(fname)}</span></div>'
        )

    syms = [
        ("sym-func", "ComputeSum(a, b int)", "go"),
        ("sym-method", "ServeHTTP(w, r)", "go"),
        ("sym-struct", "ServerConfig", "data"),
        ("sym-interface", "Handler", "data"),
        ("sym-field", "ReadTimeout", "infra"),
        ("sym-package", "context", "web"),
    ]
    crows = []
    for s_ic, s_name, fam in syms:
        crows.append(
            f'<div class="crow">{vec_icon(sym_data, s_ic, p[fam], 16)}'
            f'<span class="cname">{html.escape(s_name)}</span><span class="cfam" style="color:{p[fam]}">{s_ic.replace("sym-","")}</span></div>'
        )

    empty_badge = vec_icon(sym_data, "empty-profiler", p["go"], 38, hierarchical=True)

    return f"""
    <div class="tcol" style="background:{p['bg']}">
      <div class="thead">
        <div class="ttitle">{p['title']}</div>
        <div class="tsub">{p['subtitle']}</div>
      </div>
      <div class="ggrid">{"".join(gopher_cards)}</div>
      <div class="uipair">
        <div class="ubox" style="background:{p['card']}">
          <div class="uhead">PROJECT NAVIGATOR</div>
          {"".join(srows)}
        </div>
        <div class="ubox" style="background:{p['card']}">
          <div class="uhead">GO AST SYMBOLS</div>
          {"".join(crows)}
          <div class="uhead" style="margin-top:10px">HERO EMPTY STATE</div>
          <div class="hero-mini">
            {empty_badge}
            <div>
              <div style="font-weight:600;font-size:11.5px">Flame Graph Profiler</div>
              <div style="font-size:10px;opacity:.65">Hierarchical 2-layer badge</div>
            </div>
          </div>
        </div>
      </div>
    </div>
    """


def main():
    cols = "".join(build_theme_column(k) for k in ("default", "halloween", "noel"))
    doc = f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>GoLens Seasonal Icon Themes</title>
<style>
:root{{font:13px -apple-system,BlinkMacSystemFont,"SF Pro Text","Helvetica Neue",sans-serif;color:#f5f5f7}}
body{{margin:0;background:#0F0F12;padding:24px}}
h1{{font-size:22px;margin:0 0 4px}}
p.lede{{margin:0 0 18px;color:#a1a1a6;font-size:13px}}
.wrap{{display:grid;grid-template-columns:repeat(3, 1fr);gap:16px}}
.tcol{{border-radius:14px;padding:16px;box-shadow:0 12px 32px rgba(0,0,0,.35),0 0 0 1px rgba(255,255,255,.08);display:flex;flex-direction:column;gap:14px}}
.ttitle{{font-size:16px;font-weight:700}}
.tsub{{font-size:11.5px;opacity:.68;margin-top:2px}}
.ggrid{{display:grid;grid-template-columns:repeat(3, 1fr);gap:8px}}
.gcard{{border-radius:10px;padding:10px 8px;display:flex;flex-direction:column;align-items:center;gap:6px;box-shadow:inset 0 0 0 .5px rgba(255,255,255,.08)}}
.grow-top{{height:80px;display:flex;align-items:center;justify-content:center}}
.grow-sizes{{display:flex;align-items:center;gap:10px;padding:4px 10px;border-radius:6px;background:rgba(0,0,0,.22)}}
.gtitle{{font-size:11.5px;font-weight:600;margin-top:2px}}
.gsub{{font-size:10px;opacity:.55;font-family:"SF Mono",Menlo,monospace}}
.uipair{{display:grid;grid-template-columns:1fr 1fr;gap:10px}}
.ubox{{border-radius:10px;padding:8px 6px;box-shadow:inset 0 0 0 .5px rgba(255,255,255,.08)}}
.uhead{{font-size:10px;font-weight:700;letter-spacing:.04em;opacity:.5;padding:2px 8px 6px}}
.srow{{display:flex;align-items:center;height:22px;gap:5px;padding-right:6px;border-radius:5px;font-size:12px}}
.chev{{width:10px;font-size:11px;opacity:.5;text-align:center}}
.fname{{flex:1;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}}
.crow{{display:flex;align-items:center;height:24px;gap:6px;padding:0 6px;font:11.5px "SF Mono",Menlo,monospace}}
.cname{{flex:1;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}}
.cfam{{font-size:10px;opacity:.85;font-family:-apple-system,sans-serif;font-weight:500}}
.hero-mini{{display:flex;align-items:center;gap:10px;padding:8px;border-radius:8px;background:rgba(0,0,0,.2);margin:2px 4px}}
.ic{{display:block;flex:none}}
</style></head>
<body>
<h1>GoLens Seasonal Icon Theme Packs — Concept Preview (@1x, @2x &amp; 76px Mascot Loupe)</h1>
<p class="lede">Generated procedurally from the same vector geometry pipeline (<code>gopher.py</code> + <code>icons.py</code> + <code>palette.json</code>):
Default Classic Go vs. <b>Halloween (Vampire-Witch Gopher)</b> vs. <b>Noel / Winter (Santa Gopher)</b>.</p>
<div class="wrap">{cols}</div>
</body></html>
"""
    html_path = os.path.join(ROOT, "seasonal-preview.html")
    open(html_path, "w").write(doc)
    out_png = os.path.join(ROOT, "preview", "seasonal-themes-2x.png")
    chrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
    subprocess.run([
        chrome, "--headless=new", "--disable-gpu", "--hide-scrollbars",
        "--no-first-run", "--no-default-browser-check",
        "--force-device-scale-factor=2", "--window-size=1320,690",
        f"--screenshot={out_png}", f"file://{html_path}"
    ], check=True)
    print("Wrote", out_png)


if __name__ == "__main__":
    main()
