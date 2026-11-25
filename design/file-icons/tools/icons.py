"""Icon definitions for the GoLens file-icon set (original artwork).

Design space: Medium-scale SF Symbols template units, origin = optical centre,
y down. Reference sizes measured from system symbols at 100 pt Regular:
`doc` ink 83 x 105, `folder` 112 x 89, Regular stroke ~8.4.

Layers are listed back to front. Roles: "secondary" (structure: page, folder,
outline), "primary" (the identity mark), "erase" (clear-behind gap for badges).
"""
from geometry import P, E, L, DISC, RRECT, POLY, T, FILL

# ------------------------------------------------------------------ bases
# Document page with folded corner, centre-line box x +-37, y +-48.
PAGE = [
    P([(-37, -48, 10), (9, -48, 8), (37, -20, 8), (37, 48, 10), (-37, 48, 10)], closed=True),
    P([(9, -48, 0), (9, -20, 0), (37, -20, 0)]),
]
MARK_C = (0, 12)  # centre of the free area below the fold


def page(*mark, dx=0, dy=0):
    """Page + mark drawn around (0, 0) and centred into the page's free area."""
    return [("secondary", PAGE), ("primary", T(list(mark), MARK_C[0] + dx, MARK_C[1] + dy))]


# Filled folder (outer edge where the outline folder's stroke ends) with a thin gap under the tab.
FOLDER = [("primary", [FILL([(-50, 40, 10), (-50, -38, 8), (-20, -38, 8), (-11, -28, 8), (50, -28, 10), (50, 40, 10)])]),
          ("erase", [RRECT(-46, -20, 46, -14, 2.9)])]

BADGE_C = (30, 24)
BADGE_R = 28  # erase radius: stroke half-width + visual gap around the badge


def badged(base_layers, badge, c=BADGE_C, r=BADGE_R):
    return base_layers + [("erase", [DISC(c[0], c[1], r)]), ("primary", T(badge, c[0], c[1]))]


def folder(badge=()):
    """Folder with an optional badge knocked out of the front panel, like Finder's special folders."""
    return FOLDER + ([("erase", T(badge, 0, 14, 1.2))] if badge else [])


# ------------------------------------------------------------------ small marks (around 0,0)
def braces(w=15, h=40, gap=14):
    """{ } pair; each brace is a rounded polyline with a sharp middle point."""
    def brace(sx):
        x0 = sx * gap
        x1 = sx * (gap + 8)
        tip = sx * (gap + w)
        return P([(x0, -h / 2, 0), (x1, -h / 2, 5), (x1, -5, 4), (tip, 0, 0), (x1, 5, 4), (x1, h / 2, 5), (x0, h / 2, 0)])
    return [brace(-1), brace(1)]


CHECK = [P([(-13, 0, 0), (-4, 10, 0), (13, -11, 0)])]
NOSIGN = [E(0, 0, 13), L(-9, 9, 9, -9)]
LOCK = [P([(-9, 0, 0), (-9, -12, 9), (9, -12, 9), (9, 0, 0)]), RRECT(-15, -3, 15, 19, 5)]
PROMPT = [P([(-13, -10, 0), (-3, 0, 0), (-13, 10, 0)]), L(3, 11, 14, 11)]
STACK = [P([(-8, -15, 5), (15, -15, 5), (15, 8, 0)]), RRECT(-15, -8, 8, 15, 4)]


def cube(r=44, cx=0, cy=0, inner=True):
    import math
    v = [(cx + r * math.cos(math.radians(a)), cy + r * math.sin(math.radians(a))) for a in (-90, -30, 30, 90, 150, 210)]
    rr = r * 0.22
    out = [P([(x, y, rr) for x, y in v], closed=True)]
    if inner:
        out.append(P([v[5] + (0,), (cx, cy, 0), v[1] + (0,)]))
        out.append(L(cx, cy, v[3][0], v[3][1]))
    return out


def hexagon(r, cx=0, cy=0):
    import math
    return POLY([(cx + r * math.cos(math.radians(a)), cy + r * math.sin(math.radians(a))) for a in (-90, -30, 30, 90, 150, 210)])


def heptagon_wheel(R=47, spoke=30, hub=9):
    import math
    angs = [-90 + k * 360 / 7 for k in range(7)]
    hept = P([(R * math.cos(math.radians(a)), R * math.sin(math.radians(a)), R * 0.2) for a in angs], closed=True)
    spokes = [L(0, 0, spoke * math.cos(math.radians(a)), spoke * math.sin(math.radians(a))) for a in angs]
    return hept, spokes + [DISC(0, 0, hub)]


def ship_helm(rim=27, reach=43, knob=6.5, hub=11, n=8):
    """Ship's helm: round rim, solid hub, n handles ending in knobs. No inner spokes, so it never
    reads like the Kubernetes heptagon-and-asterisk."""
    import math
    out = [E(0, 0, rim), DISC(0, 0, hub)]
    for k in range(n):
        a = math.radians(k * 360 / n)
        c, si = math.cos(a), math.sin(a)
        out.append(L(rim * c, rim * si, (reach - knob) * c, (reach - knob) * si))
        out.append(DISC(reach * c, reach * si, knob))
    return out


def big_braces():
    """Standalone { } that fills the glyph box (no page)."""
    def brace(sx):
        return P([(sx * 14, -44, 0), (sx * 26, -44, 10), (sx * 26, -8, 8), (sx * 40, 0, 0),
                  (sx * 26, 8, 8), (sx * 26, 44, 10), (sx * 14, 44, 0)])
    return [brace(-1), brace(1)]


def bracket_table():
    """Standalone [ = ] : TOML's [table] header around key = value rows."""
    def bracket(sx):
        return P([(sx * 20, -44, 0), (sx * 38, -44, 9), (sx * 38, 44, 9), (sx * 20, 44, 0)])
    return [bracket(-1), bracket(1), L(-14, -11, 14, -11), L(-14, 11, 14, 11)]


PAGE_SIL = [(-37, -48), (9, -48), (37, -20), (37, 48), (-37, 48)]


def stacked_pages(*mark):
    """Template: a page in front of a second page (one source, many outputs)."""
    s, f, b = 0.8, (-9, 9), (11, -11)
    back = T(PAGE[:1], b[0], b[1], s)
    gap = [POLY([(x * s * 1.25 + f[0], y * s * 1.19 + f[1]) for x, y in PAGE_SIL])]
    front = T(PAGE, f[0], f[1], s)
    return [("secondary", back), ("erase", gap), ("secondary", front),
            ("primary", T(list(mark), f[0] + MARK_C[0] * s, f[1] + MARK_C[1] * s))]


def branch(s=1.0):
    g = [E(-18, -30, 10), E(-18, 30, 10), E(20, -12, 10), L(-18, -20, -18, 20),
         P([(20, -2, 0), (20, 14, 14), (-18, 14, 0)])]
    return T(g, 0, 0, s)


WHALE_HULL = [P([(-46, 0, 8), (26, 0, 10), (44, -18, 0), (40, 14, 22), (-4, 36, 26), (-42, 20, 16)], closed=True)]
WHALE_DECK = [RRECT(-36, -21, -23, -8, 2.5), RRECT(-17, -21, -4, -8, 2.5), RRECT(2, -21, 15, -8, 2.5),
              RRECT(-17, -40, -4, -27, 2.5), DISC(-30, 15, 4.5)]
WHALE = [("primary", WHALE_HULL), ("primary", WHALE_DECK)]


# ------------------------------------------------------------------ the set
def build():
    hept, k8s_wheel = heptagon_wheel()
    I = {}
    # Go (go, go-test, go-generated: multicolor gopher in gopher.py)
    I["go-mod"] = [("primary", cube()[:1]), ("secondary", cube()[1:])]
    I["go-work"] = [("secondary", cube(31, 13, -14, inner=False)),
                    ("erase", [hexagon(31 + 10, -9, 10)]),
                    ("primary", cube(31, -9, 10))]
    I["go-sum"] = page(*LOCK, dy=-2)
    I["go-template"] = stacked_pages(*T(braces(), 0, 0, 0.7), DISC(0, 0, 5.5))
    I["pprof"] = page(E(0, 10, 21, 21, 180, 360), L(0, 10, 11, -4), DISC(0, 10, 5.5), dy=-2)
    # containers & infra
    I["docker"] = WHALE
    I["docker-compose"] = badged(WHALE, STACK, c=(32, 27))
    I["docker-ignore"] = badged(WHALE, NOSIGN, c=(32, 27))
    I["kubernetes"] = [("secondary", [hept]), ("primary", k8s_wheel)]
    I["helm"] = [("primary", ship_helm())]
    I["terraform"] = [("primary", [P([(0, -42, 10), (46, -19, 10), (0, 4, 10), (-46, -19, 10)], closed=True)]),
                      ("secondary", [P([(-46, 1, 0), (0, 24, 12), (46, 1, 0)]), P([(-46, 21, 0), (0, 44, 12), (46, 21, 0)])])]
    I["makefile"] = page(L(-16, 20, 5, -1), POLY([(-4, -21), (17, 0), (25, -8), (4, -29)]))  # hammer: handle + head
    I["shell"] = page(*PROMPT)
    I["env"] = page(E(-8, 0, 10), L(2, 0, 18, 0), L(12, 0, 12, 9), L(18, 0, 18, 7))  # key
    # data & config
    I["yaml"] = page(L(-20, -16, 4, -16), L(-6, 0, 20, 0), L(-6, 16, 14, 16))
    I["json"] = [("primary", big_braces())]
    I["toml"] = [("secondary", bracket_table()[:2]), ("primary", bracket_table()[2:])]
    I["config"] = page(L(-20, -10, -14, -10), E(-6, -10, 7), L(2, -10, 20, -10),
                       L(-20, 12, 2, 12), E(10, 12, 7), L(18, 12, 20, 12))
    I["proto"] = page(P([(0, -20, 8), (17.3, -10, 8), (17.3, 10, 8), (0, 20, 8), (-17.3, 10, 8), (-17.3, -10, 8)], closed=True),
                      DISC(0, 0, 4.5))
    I["graphql"] = page(L(0, -18, 19, 15), L(19, 15, -19, 15), L(-19, 15, 0, -18),
                        DISC(0, -18, 6.5), DISC(19, 15, 6.5), DISC(-19, 15, 6.5))
    I["sql"] = [("primary", [E(0, -30, 38, 13), L(-38, -30, -38, 30), L(38, -30, 38, 30), E(0, 30, 38, 13, 0, 180)]),
                ("secondary", [E(0, 0, 38, 13, 0, 180)])]
    # docs & misc
    I["markdown"] = [("secondary", [P([(-50, -32, 10), (50, -32, 10), (50, 32, 10), (-50, 32, 10)], closed=True)]),
                     ("primary", [P([(-32, 14, 0), (-32, -14, 0), (-20, 0, 0), (-8, -14, 0), (-8, 14, 0)]),
                                  L(22, -14, 22, 12), P([(11, 2, 0), (22, 13, 0), (33, 2, 0)])])]
    I["license"] = page(E(0, -6, 11), P([(-7, 3, 0), (-11, 24, 0), (0, 18, 0), (11, 24, 0), (7, 3, 0)]), dy=-2)
    I["text"] = page(L(-20, -14, 20, -14), L(-20, 2, 20, 2), L(-20, 18, 8, 18))
    I["file"] = [("secondary", PAGE)]
    I["git"] = [("secondary", [L(-18, -20, -18, 20), P([(20, -2, 0), (20, 14, 14), (-18, 14, 0)])]),
                ("primary", [E(-18, -30, 10), E(-18, 30, 10), E(20, -12, 10)])]
    I["git-ignore"] = badged(I["git"], NOSIGN, c=(30, 30))
    I["ci-workflow"] = [("secondary", [P([(-22, -12, 0), (-22, 22, 12), (10, 22, 0)])]),
                        ("primary", [RRECT(-36, -40, -8, -12, 6), P([(10, 8, 7), (38, 8, 7), (38, 36, 7), (10, 36, 7)], closed=True)])]
    I["image"] = [("secondary", [P([(-50, -38, 10), (50, -38, 10), (50, 38, 10), (-50, 38, 10)], closed=True)]),
                  ("primary", [P([(-36, 24, 0), (-12, -2, 6), (6, 16, 0), (16, 6, 5), (36, 24, 0)]), DISC(20, -16, 7)])]
    I["html"] = page(P([(-8, -16, 0), (-22, 0, 0), (-8, 16, 0)]), P([(8, -16, 0), (22, 0, 0), (8, 16, 0)]))
    I["css"] = page(L(-20, -8, 20, -8), L(-20, 8, 20, 8), L(-8, -20, -8, 20), L(8, -20, 8, 20))
    I["javascript"] = page(P([(-8, -18, 0), (-8, 10, 9), (-24, 10, 0)]),  # J
                           P([(20, -16, 0), (10, -18, 7), (4, -12, 6), (8, -2, 0), (16, 2, 0), (20, 10, 6), (12, 18, 7), (2, 16, 0)]))  # S
    I["typescript"] = page(L(-24, -18, -2, -18), L(-13, -18, -13, 18),  # T
                           P([(20, -16, 0), (10, -18, 7), (4, -12, 6), (8, -2, 0), (16, 2, 0), (20, 10, 6), (12, 18, 7), (2, 16, 0)]))
    # folders
    I["folder"] = folder()
    return I


# Accessibility descriptions (VoiceOver) — also used as preview captions.
LABELS = {
    "go": "Go source file", "go-test": "Go test file", "go-generated": "Generated Go file",
    "go-mod": "Go module file", "go-work": "Go workspace file", "go-sum": "Go checksum file",
    "go-template": "Go template", "pprof": "Go performance profile", "docker": "Dockerfile", "docker-compose": "Docker Compose file",
    "docker-ignore": "Docker ignore file", "kubernetes": "Kubernetes manifest", "helm": "Helm chart file",
    "terraform": "Terraform file", "makefile": "Makefile", "shell": "Shell script", "env": "Environment file",
    "yaml": "YAML file", "json": "JSON file", "toml": "TOML file", "config": "Configuration file",
    "proto": "Protocol Buffers file", "graphql": "GraphQL file", "sql": "SQL file", "markdown": "Markdown file",
    "license": "License file", "text": "Text file", "file": "File", "git": "Git configuration file",
    "git-ignore": "Git ignore file", "ci-workflow": "CI workflow", "image": "Image", "html": "HTML file",
    "css": "CSS file", "javascript": "JavaScript file", "typescript": "TypeScript file",
    "folder": "Folder",
}
