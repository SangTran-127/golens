"""Write preview.html (self-contained) from tools/preview-data.json, palette.json and mapping.json.

Views: preview.html shows everything; ?view=grid-light | grid-dark | sidebar | gray | zoom isolates one
section for screenshots (see README "Regenerate").
"""
import html
import json
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
data = json.load(open(os.path.join(ROOT, "tools", "preview-data.json")))
pal = json.load(open(os.path.join(ROOT, "palette.json")))["tints"]
mapping = json.load(open(os.path.join(ROOT, "mapping.json")))

tint_of = {}
for rule in mapping["folders"] + mapping["files"] + list(mapping["fallback"].values()):
    tint_of.setdefault(rule["icon"], rule["palette"])
for n in data:  # badged folders are not mapped in GoLens; preview them in the folder tint
    tint_of.setdefault(n, "accent" if n.startswith("folder") else "neutral")

ORDER = list(data)  # icons.py order: Go, infra, data, docs/misc, folders


def symbols():
    out = []
    for n, d in data.items():
        out.append(f'<symbol id="m-{n}" viewBox="-60 -60 120 120" fill="currentColor"><path d="{d["mono"]}"/></symbol>')
        out.append(f'<symbol id="h-{n}" viewBox="-60 -60 120 120" fill="currentColor"><path d="{d["secondary"]}" opacity=".5"/>'
                   f'<path d="{d["primary"]}"/></symbol>')
    return "\n".join(out)


def ic(n, size, mode="t", extra=""):
    kind = "h" if mode == "h" else "m"
    cls = "mono" if mode == "m" else f"t-{tint_of[n]}"
    return f'<svg class="ic {cls} {extra}" width="{size}" height="{size}" role="img" aria-label="{html.escape(data[n]["label"])}"><use href="#{kind}-{n}"/></svg>'


def grid(theme):
    cards = []
    for n in ORDER:
        cards.append(
            f'<div class="card"><div class="row">{ic(n, 16)}{ic(n, 16, "m")}<span class="sep"></span>'
            f'{ic(n, 32)}{ic(n, 32, "m")}{ic(n, 32, "h")}</div>'
            f'<div class="name">{n}</div><div class="key">{tint_of[n]}</div></div>')
    return (f'<section class="panel {theme}" data-view="grid-{theme}"><h2>Full set, {theme}: 16 px tinted / mono, '
            f'32 px tinted / mono / hierarchical</h2><div class="grid">{"".join(cards)}</div></section>')


TREE = [  # (depth, disclosure, icon, name, status)
    (0, "v", "folder", ".github", ""), (1, "v", "folder", "workflows", ""), (2, "", "ci-workflow", "ci.yml", ""),
    (0, "v", "folder", "cmd", ""), (1, "v", "folder", "server", ""), (2, "", "go", "main.go", ""),
    (0, ">", "folder", "internal", ""),
    (0, "v", "folder", "pkg", ""), (1, "v", "folder", "api", ""),
    (2, "", "go", "handler.go", "M"), (2, "", "go-test", "handler_test.go", "A"), (2, "", "go-generated", "user.pb.go", ""),
    (2, "", "pprof", "cpu.pprof", ""), (2, "", "proto", "user.proto", ""),
    (0, "v", "folder", "charts", ""), (1, "v", "folder", "golens", ""), (2, "", "helm", "Chart.yaml", ""),
    (2, "", "helm", "values.yaml", "M"), (2, ">", "folder", "templates", ""),
    (0, "v", "folder", "k8s", ""), (1, "", "kubernetes", "deployment.yaml", ""), (1, "", "kubernetes", "service.yaml", ""),
    (0, ">", "folder", "testdata", ""), (0, ">", "folder", "vendor", ""),
    (0, "", "docker-ignore", ".dockerignore", ""), (0, "", "env", ".env", ""), (0, "", "git-ignore", ".gitignore", ""),
    (0, "", "docker-compose", "docker-compose.yml", ""), (0, "", "docker", "Dockerfile", ""),
    (0, "", "go-mod", "go.mod", "M"), (0, "", "go-sum", "go.sum", "M"), (0, "", "license", "LICENSE", ""),
    (0, "", "makefile", "Makefile", ""), (0, "", "markdown", "README.md", ""), (0, "", "terraform", "main.tf", "U"),
]


def sidebar(theme, mono=False):
    rows = []
    for depth, disc, icon, name, status in TREE:
        sel = " sel" if name == "handler.go" else ""
        chev = {"v": "&#x2304;", ">": "&#x203A;", "": ""}[disc]
        st = f'<span class="st st-{status}">{status}</span>' if status else ""
        rows.append(f'<div class="srow{sel}" style="padding-left:{8 + depth * 16}px"><span class="chev">{chev}</span>'
                    f'{ic(icon, 16, "m" if mono else "t")}<span class="fname">{html.escape(name)}</span>{st}</div>')
    title = "monochrome" if mono else "tinted"
    return (f'<div class="sidebar {theme}"><div class="shead">GOLENS-DEMO <span>{theme}, {title}</span></div>'
            + "".join(rows) + "</div>")


def css_tints():
    out = []
    for k, v in pal.items():
        out.append(f".light .t-{k}{{color:{v['light']}}} .dark .t-{k}{{color:{v['dark']}}}")
        out.append(f".light.hc .t-{k}{{color:{v['lightHighContrast']}}} .dark.hc .t-{k}{{color:{v['darkHighContrast']}}}")
    return "\n".join(out)


page = f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>GoLens file icons</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
:root{{font:13px -apple-system,BlinkMacSystemFont,"SF Pro Text","Helvetica Neue",sans-serif}}
body{{margin:0;background:#fff;color:#1d1d1f}}
h1{{font-size:22px;margin:24px 24px 4px}} p.lede{{margin:0 24px 16px;color:#6e6e73;max-width:70ch}}
h2{{font-size:13px;font-weight:600;margin:0 0 12px}}
.panel{{padding:20px 24px}}
.light{{background:#F5F5F7;color:#1d1d1f}} .dark{{background:#1E1E1E;color:#f5f5f7}}
.mono{{color:#6E6E73}} .dark .mono{{color:#A1A1A6}}
{css_tints()}
.ic{{display:block;flex:none}}
.grid{{display:grid;grid-template-columns:repeat(auto-fill,minmax(200px,1fr));gap:8px}}
.card{{padding:10px;border-radius:8px;background:rgba(127,127,127,.08)}}
.card .row{{display:flex;align-items:center;gap:10px}} .sep{{width:1px;height:28px;background:rgba(127,127,127,.3)}}
.name{{margin-top:8px;font-weight:500}} .key{{font-size:11px;opacity:.6}}
.sidebars{{display:flex;gap:16px;padding:20px 24px;background:#d9d9de;flex-wrap:wrap}}
.sidebar{{width:250px;padding:8px 0;border-radius:10px;box-shadow:0 0 0 .5px rgba(0,0,0,.2)}}
.sidebar.light{{background:#EDEDF0}} .sidebar.dark{{background:#2A2A2C}}
.shead{{font-size:11px;font-weight:600;opacity:.55;padding:4px 12px 6px}} .shead span{{font-weight:400}}
.srow{{display:flex;align-items:center;height:24px;gap:5px;margin:0 6px;border-radius:5px;padding-right:8px}}
.chev{{width:10px;font-size:12px;opacity:.5;text-align:center}}
.fname{{flex:1;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}}
.st{{font-size:11px;font-weight:600;color:#6e6e73}} .dark .st{{color:#a1a1a6}}
.st-A{{color:#28a745!important}} .st-U{{color:#d70015!important}}
.srow.sel{{background:#0A64D2;color:#fff}} .srow.sel .ic,.srow.sel .st{{color:#fff!important}}
.gray{{filter:grayscale(1)}}
.zoom .grid{{grid-template-columns:repeat(auto-fill,minmax(120px,1fr))}}
.zoom .card{{display:flex;flex-direction:column;align-items:center;background:#fff}}
.zoom .ic{{outline:1px dashed rgba(0,160,255,.35)}}
body[data-only] section,body[data-only] header{{display:none}}
body[data-only] section.on{{display:block}}
</style></head>
<body>
<svg width="0" height="0" style="position:absolute" aria-hidden="true">{symbols()}</svg>
<header><h1>GoLens file-type icons</h1>
<p class="lede">{len(data)} custom symbols. Identity tints by family (Go, infra, data, web), the theme accent for folders and neutral for docs and tooling.
Gopher-derived glyph after the Go gopher by Ren&eacute;e French (CC BY 4.0). Other technology glyphs are original drawings
that only evoke the technology; all trademarks belong to their owners.</p></header>
{grid("light")}
{grid("dark")}
<section data-view="sidebar"><div class="sidebars">{sidebar("light")}{sidebar("dark")}{sidebar("light", True)}{sidebar("dark", True)}</div></section>
<section data-view="hc"><div class="sidebars"><div class="light hc" style="padding:0">{sidebar("light")}</div><div class="dark hc">{sidebar("dark")}</div></div></section>
<section class="panel light gray" data-view="gray"><h2>Grayscale test (tinted set, filter: grayscale)</h2>
<div class="grid">{"".join(f'<div class="card"><div class="row">{ic(n, 16)}{ic(n, 32)}</div><div class="name">{n}</div></div>' for n in ORDER)}</div></section>
<section class="panel light zoom" data-view="zoom"><h2>Craft check at 64 px (dashed = 16 pt artboard)</h2>
<div class="grid">{"".join(f'<div class="card">{ic(n, 64)}<div class="name">{n}</div></div>' for n in ORDER)}</div></section>
<script>
const v = new URLSearchParams(location.search).get('view');
if (v) {{ document.body.dataset.only = v; document.querySelectorAll('[data-view="' + v + '"]').forEach(e => e.classList.add('on')); }}
</script>
</body></html>
"""
open(os.path.join(ROOT, "preview.html"), "w").write(page)
print("preview.html", len(page) // 1024, "KB")
