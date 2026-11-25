"""Write design/symbol-icons/preview.html (self-contained) from preview-data.json, palette.json and symbol-mapping.json.

Views:
  preview.html                  full interactive specimen sheet
  ?view=grid-light | grid-dark  11 AST symbols + 4 Empty-State hero badges
  ?view=popups                  Mock Completion popup, Go to Symbol (⌃6), Call/Type Hierarchy (⌃H), and Empty State cards
  ?view=gray                    Grayscale silhouette test (shape-only distinguishability)
  ?view=zoom                    64px optical grid & geometry check
"""
import html
import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
PAL_PATH = os.path.join(ROOT, "..", "file-icons", "palette.json")

data = json.load(open(os.path.join(HERE, "preview-data.json")))
pal = json.load(open(PAL_PATH))["tints"]
mapping = json.load(open(os.path.join(ROOT, "symbol-mapping.json")))

tint_of = {}
for k, rule in mapping["completionKinds"].items():
    tint_of.setdefault(rule["icon"], rule["palette"])
for k, rule in mapping["emptyStates"].items():
    tint_of.setdefault(rule["icon"], "neutral")

SYM_ORDER = [n for n, d in data.items() if d["kind"] == "symbol"]
EMPTY_ORDER = [n for n, d in data.items() if d["kind"] == "empty"]


def symbols():
    out = []
    for n, d in data.items():
        out.append(f'<symbol id="m-{n}" viewBox="-60 -60 120 120" fill="currentColor"><path d="{d["mono"]}"/></symbol>')
        out.append(
            f'<symbol id="h-{n}" viewBox="-60 -60 120 120" fill="currentColor">'
            f'<path d="{d["secondary"]}" opacity=".48"/><path d="{d["primary"]}"/></symbol>'
        )
    return "\n".join(out)


def ic(n, size, mode="t", extra=""):
    kind = "h" if mode == "h" else "m"
    cls = "mono" if mode == "m" else f"t-{tint_of.get(n, 'neutral')}"
    return (
        f'<svg class="ic {cls} {extra}" width="{size}" height="{size}" role="img" '
        f'aria-label="{html.escape(data[n]["label"])}"><use href="#{kind}-{n}"/></svg>'
    )


def grid(theme):
    sym_cards = []
    for n in SYM_ORDER:
        short = n.replace("sym-", "")
        sym_cards.append(
            f'<div class="card"><div class="row">{ic(n, 16)}{ic(n, 16, "m")}<span class="sep"></span>'
            f'{ic(n, 32)}{ic(n, 32, "m")}{ic(n, 32, "h")}</div>'
            f'<div class="name">{short}</div><div class="key">{n} · {tint_of[n]}</div></div>'
        )
    empty_cards = []
    for n in EMPTY_ORDER:
        short = n.replace("empty-", "")
        empty_cards.append(
            f'<div class="card empty-card"><div class="row">{ic(n, 28, "h")}{ic(n, 28, "m")}<span class="sep"></span>'
            f'{ic(n, 44, "h")}{ic(n, 44, "t")}</div>'
            f'<div class="name">{short}</div><div class="key">{data[n]["label"]}</div></div>'
        )
    return (
        f'<section class="panel {theme}" data-view="grid-{theme}">'
        f'<h2>Go AST Symbol Pack (11 symbols, {theme}): 16 px tinted / mono · 32 px tinted / mono / hierarchical</h2>'
        f'<div class="grid">{"".join(sym_cards)}</div>'
        f'<h2 style="margin-top:20px">Multi-Layer Empty-State Hero Badges (4 workflow badges, {theme}): 28 px &amp; 44 px hierarchical</h2>'
        f'<div class="grid">{"".join(empty_cards)}</div></section>'
    )


COMPLETION_ROWS = [
    ("sym-func", "ComputeSum", "(a, b int)", "int", "store", True),
    ("sym-method", "ServeHTTP", "(w ResponseWriter, r *Request)", "", "http", False),
    ("sym-struct", "ServerConfig", "", "struct{...}", "config", False),
    ("sym-interface", "Handler", "", "interface{...}", "http", False),
    ("sym-field", "ReadTimeout", "", "time.Duration", "", False),
    ("sym-const", "StatusOK", "", "untyped int", "http", False),
    ("sym-var", "DefaultServeMux", "", "*ServeMux", "http", False),
    ("sym-type", "HandlerFunc", "", "func(ResponseWriter, *Request)", "http", False),
    ("sym-type-param", "T", "", "comparable", "", False),
    ("sym-package", "context", "", "package", '"context"', False),
    ("sym-snippet", "forr", "", "for k, v := range ...", "snippet", False),
]

GOTOSYMBOL_ROWS = [
    ("sym-struct", "Hub", "Hub"),
    ("sym-field", "clients", "Hub › clients"),
    ("sym-func", "NewHub", "NewHub"),
    ("sym-method", "Run", "Hub › Run"),
    ("sym-interface", "Broadcaster", "Broadcaster"),
    ("sym-const", "maxMessageSize", "maxMessageSize"),
]


def mock_popups(theme):
    comp_items = []
    for icon, name, params, typ, pkg, sel in COMPLETION_ROWS:
        s_cls = " sel" if sel else ""
        comp_items.append(
            f'<div class="crow{s_cls}">{ic(icon, 16)}'
            f'<span class="cname"><b>{name[:3]}</b>{name[3:]}<span class="cparam">{params}</span></span>'
            f'<span class="ctype">{typ}</span><span class="cpkg">{pkg}</span></div>'
        )
    sym_items = []
    for i, (icon, name, path) in enumerate(GOTOSYMBOL_ROWS):
        s_cls = " sel" if i == 3 else ""
        sym_items.append(
            f'<div class="grow{s_cls}">{ic(icon, 16)}'
            f'<div class="gcol"><div class="gname">{name}</div><div class="gpath">{path}</div></div></div>'
        )
    empty_mocks = [
        ("empty-profiler", "No Profile Samples", "Run Profile Application or Profile Tests (⌃⌥⌘U) to inspect CPU and heap flame graphs.", "Profile Application"),
        ("empty-safety", "No Safety Findings", "Run a Safety Audit (⌃⇧⌘S) to check for concurrency hazards, dead code, and data races.", "Run Safety Audit"),
        ("empty-debugger", "Running", "Frames and variables appear when the program pauses at a breakpoint.", ""),
        ("empty-tests", "No Tests", "Functions named TestXxx in _test.go files appear here.", "Refresh"),
    ]
    ecards = []
    for icon, title, desc, btn in empty_mocks:
        bhtml = f'<div class="ebtn">{btn}</div>' if btn else ""
        ecards.append(
            f'<div class="epane">{ic(icon, 32, "h")}'
            f'<div class="etitle">{title}</div><div class="edesc">{desc}</div>{bhtml}</div>'
        )
    return (
        f'<div class="popwrap {theme}">'
        f'<div class="popup"><div class="phead">Completion Popup · {theme}</div>{"".join(comp_items)}</div>'
        f'<div class="popup" style="width:280px"><div class="phead">Go to Symbol (⌃6) · {theme}</div>{"".join(sym_items)}</div>'
        f'<div class="egrids">{"".join(ecards)}</div>'
        f'</div>'
    )


def css_tints():
    out = []
    for k, v in pal.items():
        out.append(f".light .t-{k}{{color:{v['light']}}} .dark .t-{k}{{color:{v['dark']}}}")
        out.append(f".light.hc .t-{k}{{color:{v['lightHighContrast']}}} .dark.hc .t-{k}{{color:{v['darkHighContrast']}}}")
    return "\n".join(out)


ALL_ORDER = SYM_ORDER + EMPTY_ORDER

page = f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>GoLens AST Symbol &amp; Empty-State Asset Pack</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
:root{{font:13px -apple-system,BlinkMacSystemFont,"SF Pro Text","Helvetica Neue",sans-serif}}
body{{margin:0;background:#fff;color:#1d1d1f}}
h1{{font-size:22px;margin:24px 24px 4px}} p.lede{{margin:0 24px 16px;color:#6e6e73;max-width:78ch}}
h2{{font-size:13px;font-weight:600;margin:0 0 12px}}
.panel{{padding:20px 24px}}
.light{{background:#F5F5F7;color:#1d1d1f}} .dark{{background:#1E1E1E;color:#f5f5f7}}
.mono{{color:#6E6E73}} .dark .mono{{color:#A1A1A6}}
{css_tints()}
.ic{{display:block;flex:none}}
.grid{{display:grid;grid-template-columns:repeat(auto-fill,minmax(200px,1fr));gap:8px}}
.card{{padding:10px;border-radius:8px;background:rgba(127,127,127,.08)}}
.empty-card{{grid-column:span 1}}
.card .row{{display:flex;align-items:center;gap:10px}} .sep{{width:1px;height:28px;background:rgba(127,127,127,.3)}}
.name{{margin-top:8px;font-weight:600}} .key{{font-size:11px;opacity:.62}}
.popsection{{display:flex;flex-direction:column;gap:16px;padding:20px 24px;background:#d9d9de}}
.popwrap{{display:flex;gap:16px;padding:16px;border-radius:12px;flex-wrap:wrap;align-items:flex-start}}
.popwrap.light{{background:#E8E8ED}} .popwrap.dark{{background:#161618}}
.popup{{width:430px;padding:6px;border-radius:10px;box-shadow:0 8px 24px rgba(0,0,0,.18),0 0 0 .5px rgba(127,127,127,.25)}}
.light .popup{{background:rgba(248,248,250,.92)}} .dark .popup{{background:rgba(38,38,41,.94)}}
.phead{{font-size:11px;font-weight:600;opacity:.55;padding:4px 8px 6px}}
.crow{{display:flex;align-items:center;height:24px;gap:7px;padding:0 8px;border-radius:5px;font:12.5px "SF Mono",Menlo,monospace}}
.cname{{flex:1;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}}
.cparam,.ctype,.cpkg{{font-size:11.5px;opacity:.6}} .cpkg{{margin-left:4px}}
.grow{{display:flex;align-items:center;gap:8px;padding:5px 8px;border-radius:6px}}
.gcol{{display:flex;flex-direction:column;gap:1px}} .gname{{font-size:12.5px;font-weight:500}} .gpath{{font-size:10.5px;opacity:.6}}
.crow.sel,.grow.sel{{background:#0A64D2;color:#fff}}
.crow.sel .ic,.grow.sel .ic,.crow.sel .cparam,.crow.sel .ctype,.crow.sel .cpkg,.grow.sel .gpath{{color:#fff!important;opacity:.92}}
.egrids{{display:grid;grid-template-columns:repeat(2,200px);gap:10px}}
.epane{{padding:14px 12px;border-radius:10px;display:flex;flex-direction:column;align-items:center;text-align:center;gap:6px;box-shadow:0 0 0 .5px rgba(127,127,127,.22)}}
.light .epane{{background:#fff}} .dark .epane{{background:#242426}}
.etitle{{font-size:12px;font-weight:600;margin-top:2px}} .edesc{{font-size:10.5px;opacity:.65;line-height:1.35}}
.ebtn{{margin-top:4px;font-size:11px;padding:3px 9px;border-radius:5px;background:rgba(127,127,127,.16);font-weight:500}}
.gray{{filter:grayscale(1)}}
.zoom .grid{{grid-template-columns:repeat(auto-fill,minmax(130px,1fr))}}
.zoom .card{{display:flex;flex-direction:column;align-items:center;background:#fff}}
.zoom .ic{{outline:1px dashed rgba(0,160,255,.35)}}
body[data-only] section,body[data-only] header{{display:none}}
body[data-only] section.on{{display:block}}
</style></head>
<body>
<svg width="0" height="0" style="position:absolute" aria-hidden="true">{symbols()}</svg>
<header><h1>GoLens Go AST Symbol &amp; Multi-Layer Empty-State Asset Pack</h1>
<p class="lede">11 Go AST &amp; LSP symbol glyphs (func, method, struct, interface, type, type-param, field, var, const, package, snippet)
unified across Completion, Go to Symbol (&#x2303;6), Call/Type Hierarchy (&#x2303;H) and Breadcrumbs, plus 4 multi-layer empty-state hero badges.</p></header>
{grid("light")}
{grid("dark")}
<section class="popsection" data-view="popups">{mock_popups("light")}{mock_popups("dark")}</section>
<section class="panel light gray" data-view="gray"><h2>Grayscale Silhouette Test (shape-only distinguishability at 16 px &amp; 32 px)</h2>
<div class="grid">{"".join(f'<div class="card"><div class="row">{ic(n, 16)}{ic(n, 32, "h")}</div><div class="name">{n}</div></div>' for n in ALL_ORDER)}</div></section>
<section class="panel light zoom" data-view="zoom"><h2>Craft &amp; Optical Grid Check at 64 px (dashed = artboard)</h2>
<div class="grid">{"".join(f'<div class="card">{ic(n, 64, "h")}<div class="name">{n}</div></div>' for n in ALL_ORDER)}</div></section>
<script>
const v = new URLSearchParams(location.search).get('view');
if (v) {{ document.body.dataset.only = v; document.querySelectorAll('[data-view="' + v + '"]').forEach(e => e.classList.add('on')); }}
</script>
</body></html>
"""
open(os.path.join(ROOT, "preview.html"), "w").write(page)
print("symbol-icons/preview.html", len(page) // 1024, "KB")
