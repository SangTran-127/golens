"""Icon definitions for the GoLens Go AST symbol set (11 symbols) and Multi-Layer Empty-State Hero Badges (4 badges).

Design space: Medium-scale SF Symbols template units, origin = optical centre,
y down, artboard 120 x 120 (-60..60). Regular stroke = 8.4 units.

Every AST symbol has a distinct outer silhouette + inner structural mark so that
all 11 symbols pass the grayscale silhouette test at 16 x 16 px without relying on color.
"""
import math
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "file-icons", "tools"))
from geometry import P, E, L, DISC, RRECT, POLY, T  # noqa: E402


def braces(w=15, h=68, gap=18):
    def brace(sx):
        x0 = sx * gap
        x1 = sx * (gap + 9)
        tip = sx * (gap + w)
        return P([
            (x0, -h / 2, 0),
            (x1, -h / 2, 7),
            (x1, -6, 5),
            (tip, 0, 0),
            (x1, 6, 5),
            (x1, h / 2, 7),
            (x0, h / 2, 0),
        ])
    return [brace(-1), brace(1)]


def cube(r=44, cx=0, cy=0):
    v = [(cx + r * math.cos(math.radians(a)), cy + r * math.sin(math.radians(a))) for a in (-90, -30, 30, 90, 150, 210)]
    rr = r * 0.22
    outer = P([(x, y, rr) for x, y in v], closed=True)
    y_top = P([v[5] + (0,), (cx, cy, 0), v[1] + (0,)])
    y_stem = L(cx, cy, v[3][0], v[3][1])
    return outer, y_top, y_stem


def build_symbols():
    S = {}

    # 1. sym-func: Circle badge + italic hooked f
    S["sym-func"] = [
        ("secondary", [E(0, 0, 46)]),
        ("primary", [
            P([(13, -21, 0), (3, -23, 9), (-2, -12, 0), (-2, 13, 9), (-11, 22, 0)]),
            L(-13, -3, 11, -3),
        ]),
    ]

    # 2. sym-method: Flat-top hexagon receiver badge + crisp M
    S["sym-method"] = [
        ("secondary", [
            P([(-25, -43, 10), (25, -43, 10), (49, 0, 10), (25, 43, 10), (-25, 43, 10), (-49, 0, 10)], closed=True),
        ]),
        ("primary", [
            P([(-17, 15, 0), (-17, -15, 0), (0, 5, 0), (17, -15, 0), (17, 15, 0)]),
        ]),
    ]

    # 3. sym-struct: Headered struct record box + 2 memory field slots
    S["sym-struct"] = [
        ("secondary", [
            P([(-43, -43, 14), (43, -43, 14), (43, 43, 14), (-43, 43, 14)], closed=True),
            L(-43, -12, 43, -12),
        ]),
        ("primary", [
            DISC(-19, 8, 5.5),
            L(-3, 8, 22, 8),
            DISC(-19, 25, 5.5),
            L(-3, 25, 14, 25),
        ]),
    ]

    # 4. sym-interface: Contract socket arcs + dual connection nodes + serifed I
    S["sym-interface"] = [
        ("secondary", [
            E(0, 0, 43, 43, 128, 232),
            E(0, 0, 43, 43, -52, 52),
        ]),
        ("primary", [
            DISC(-39, 0, 7.5),
            DISC(39, 0, 7.5),
            L(0, -21, 0, 21),
            L(-12, -21, 12, -21),
            L(-12, 21, 12, 21),
        ]),
    ]

    # 5. sym-type: Rounded diamond frame + crisp T
    S["sym-type"] = [
        ("secondary", [
            P([(0, -50, 12), (50, 0, 12), (0, 50, 12), (-50, 0, 12)], closed=True),
        ]),
        ("primary", [
            L(-15, -14, 15, -14),
            L(0, -14, 0, 19),
        ]),
    ]

    # 6. sym-type-param: Go generics square brackets [ T ]
    S["sym-type-param"] = [
        ("secondary", [
            P([(-21, -38, 0), (-41, -38, 8), (-41, 38, 8), (-21, 38, 0)]),
            P([(21, -38, 0), (41, -38, 8), (41, 38, 8), (21, 38, 0)]),
        ]),
        ("primary", [
            L(-13, -15, 13, -15),
            L(0, -15, 0, 18),
        ]),
    ]

    # 7. sym-field: Selector dot .Field + horizontal property slot
    S["sym-field"] = [
        ("secondary", [
            P([(-12, -26, 12), (45, -26, 12), (45, 26, 12), (-12, 26, 12)], closed=True),
        ]),
        ("primary", [
            DISC(-36, 0, 10.5),
            L(4, 0, 28, 0),
        ]),
    ]

    # 8. sym-var: Pointed-top hexagon cell + crisp v chevron
    S["sym-var"] = [
        ("secondary", [
            P([(0, -47, 10), (41, -23, 10), (41, 23, 10), (0, 47, 10), (-41, 23, 10), (-41, -23, 10)], closed=True),
        ]),
        ("primary", [
            P([(-15, -11, 0), (0, 15, 0), (15, -11, 0)]),
        ]),
    ]

    # 9. sym-const: Wide immutable pill capsule + double constant bars
    S["sym-const"] = [
        ("secondary", [
            P([(-46, -32, 16), (46, -32, 16), (46, 32, 16), (-46, 32, 16)], closed=True),
        ]),
        ("primary", [
            L(-19, -9, 19, -9),
            L(-19, 9, 19, 9),
        ]),
    ]

    # 10. sym-package: 3D isometric Go package cube
    c_out, c_top, c_stem = cube(45)
    S["sym-package"] = [
        ("secondary", [c_top, c_stem]),
        ("primary", [c_out]),
    ]

    # 11. sym-snippet: Code template braces { .. }
    S["sym-snippet"] = [
        ("secondary", braces(w=14, h=72, gap=19)),
        ("primary", [
            DISC(-9, 0, 6.5),
            DISC(9, 0, 6.5),
        ]),
    ]

    return S


def build_empty_states():
    E_SET = {}

    # 1. empty-profiler: Tiered Flame Graph bars (secondary) + clear-behind gap + Speedometer Gauge (primary)
    E_SET["empty-profiler"] = [
        ("secondary", [
            RRECT(-48, 14, 24, 30, 5),
            RRECT(-48, -9, 10, 7, 5),
            RRECT(-2, -32, 22, -16, 5),
        ]),
        ("erase", [DISC(21, 18, 31)]),
        ("primary", [
            RRECT(-48, -32, -9, -16, 5),
            E(21, 20, 22, 22, 180, 360),
            L(21, 20, 32, 5),
            DISC(21, 20, 5.5),
        ]),
    ]

    # 2. empty-safety: Faceted security shield with AST code tracks (secondary) + verification check & lock node (primary)
    E_SET["empty-safety"] = [
        ("secondary", [
            P([(0, -47, 8), (40, -31, 8), (40, 4, 24), (0, 47, 8), (-40, 4, 24), (-40, -31, 8)], closed=True),
            L(-20, -20, 20, -20),
            L(-20, 18, 6, 18),
        ]),
        ("erase", [DISC(0, -1, 24), DISC(29, 25, 25)]),
        ("primary", [
            P([(-13, -1, 0), (-3, 9, 0), (14, -10, 0)]),
            P([(22, 24, 0), (22, 15, 7), (36, 15, 7), (36, 24, 0)]),
            RRECT(17, 22, 41, 40, 4.5),
        ]),
    ]

    # 3. empty-debugger: Execution call-stack lines (secondary) + Breakpoint chevron & step inspect badge (primary)
    E_SET["empty-debugger"] = [
        ("secondary", [
            L(-38, -28, 36, -28),
            L(-14, 0, 42, 0),
            L(-38, 28, 16, 28),
            L(-38, -28, -38, 28),
        ]),
        ("erase", [
            POLY([(-52, -18), (-12, -18), (2, 0), (-12, 18), (-52, 18)]),
            DISC(27, 23, 27),
        ]),
        ("primary", [
            POLY([(-46, -12), (-16, -12), (-4, 0), (-16, 12), (-46, 12)]),
            E(27, 23, 18),
            POLY([(23, 14), (36, 23), (23, 32)]),
        ]),
    ]

    # 4. empty-tests: Test suite diamond frame (secondary) + verification check & benchmark target (primary)
    E_SET["empty-tests"] = [
        ("secondary", [
            P([(0, -47, 10), (47, 0, 10), (0, 47, 10), (-47, 0, 10)], closed=True),
        ]),
        ("erase", [DISC(28, 25, 25)]),
        ("primary", [
            P([(-16, -1, 0), (-4, 11, 0), (16, -12, 0)]),
            E(28, 25, 16),
            DISC(28, 25, 5.5),
        ]),
    ]

    # 5. empty-issues: Diagnostic radar ring (secondary) + clean verification check & badge (primary)
    E_SET["empty-issues"] = [
        ("secondary", [
            E(0, 0, 43),
        ]),
        ("erase", [DISC(28, 25, 22)]),
        ("primary", [
            P([(-16, 0, 0), (-4, 12, 0), (17, -11, 0)]),
            DISC(28, 25, 11),
        ]),
    ]

    # 6. empty-git: Commit trunk (secondary) + branch curve & node (primary)
    E_SET["empty-git"] = [
        ("secondary", [
            L(-18, -28, -18, 28),
            DISC(-18, -32, 9),
            DISC(-18, 32, 9),
        ]),
        ("primary", [
            P([(-18, 12, 0), (20, 12, 14), (20, -10, 0)]),
            E(20, -22, 11),
        ]),
    ]

    # 7. empty-terminal: Console window frame (secondary) + shell prompt chevron & cursor (primary)
    E_SET["empty-terminal"] = [
        ("secondary", [
            P([(-44, -36, 12), (44, -36, 12), (44, 36, 12), (-44, 36, 12)], closed=True),
        ]),
        ("primary", [
            P([(-22, -12, 0), (-8, 2, 0), (-22, 16, 0)]),
            L(4, 16, 24, 16),
        ]),
    ]

    return E_SET


LABELS = {
    "sym-func": "Go function symbol",
    "sym-method": "Go receiver method symbol",
    "sym-struct": "Go struct type symbol",
    "sym-interface": "Go interface contract symbol",
    "sym-type": "Go defined type symbol",
    "sym-type-param": "Go generic type parameter symbol",
    "sym-field": "Go struct field symbol",
    "sym-var": "Go variable symbol",
    "sym-const": "Go constant symbol",
    "sym-package": "Go package symbol",
    "sym-snippet": "Go code snippet or keyword",
    "empty-profiler": "Profiler flame graph and gauge badge",
    "empty-safety": "Safety static analyzer shield badge",
    "empty-debugger": "Debugger call stack and breakpoint badge",
    "empty-tests": "Test suite verification badge",
    "empty-issues": "Clean diagnostics verification badge",
    "empty-git": "Git repository branch badge",
    "empty-terminal": "Terminal shell prompt badge",
}
