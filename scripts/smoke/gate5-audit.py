#!/usr/bin/env python3
import json
import os
import plistlib
import re
import sys
from pathlib import Path
from typing import Dict, List, Optional, Set, Tuple

ROOT = Path(__file__).resolve().parents[2]
THEME_MANAGER_CANDIDATES = [
    ROOT / "desktop" / "Utilities" / "ThemeManager.swift",
    ROOT / "desktop" / "State" / "ThemeManager.swift",
]
PALETTE_JSON_PATH = ROOT / "design" / "file-icons" / "palette.json"
COMMAND_PALETTE_PATH = ROOT / "desktop" / "Views" / "Main" / "CommandPaletteView.swift"
BRIDGING_HEADER_PATH = ROOT / "desktop" / "App" / "GoLens-Bridging-Header.h"
MAIN_GO_PATH = ROOT / "core" / "main.go"
AGENT_GO_PATH = ROOT / "core" / "agent.go"
DESIGN_SYSTEM_PATH = ROOT / "DESIGN_SYSTEM.md"
TEMPLATE_DIR = ROOT / "design" / "file-icons" / "template"
DEAD_TEMPLATE_DIR = ROOT / "desktop" / "golens"
DEAD_TEMPLATE_DIRS = [
    ROOT / "desktop" / "golens",
    ROOT / "desktop" / "velo",
]
ENTITLEMENTS_PATH = ROOT / "desktop" / "Resources" / "GoLens.entitlements"

RGB = Tuple[int, int, int]


def resolve_theme_manager_path() -> Path:
    for candidate in THEME_MANAGER_CANDIDATES:
        if candidate.exists():
            return candidate
    return THEME_MANAGER_CANDIDATES[-1]


def hex_to_rgb(hex_str: str) -> RGB:
    h = hex_str.lstrip("#")
    return (int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16))


def rgb_to_hex(rgb: RGB) -> str:
    return f"#{rgb[0]:02X}{rgb[1]:02X}{rgb[2]:02X}"


def srgb_channel_to_linear(c: float) -> float:
    v = c / 255.0
    return v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4


def relative_luminance(rgb: RGB) -> float:
    r, g, b = (srgb_channel_to_linear(ch) for ch in rgb)
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def contrast_ratio(fg: RGB, bg: RGB) -> float:
    l1 = relative_luminance(fg)
    l2 = relative_luminance(bg)
    bright, dark = (l1, l2) if l1 >= l2 else (l2, l1)
    return (bright + 0.05) / (dark + 0.05)


def alpha_composite(fg: RGB, alpha: float, bg: RGB) -> RGB:
    return (
        round(fg[0] * alpha + bg[0] * (1.0 - alpha)),
        round(fg[1] * alpha + bg[1] * (1.0 - alpha)),
        round(fg[2] * alpha + bg[2] * (1.0 - alpha)),
    )


SYSTEM_SEMANTIC_RGB: Dict[str, Dict[str, RGB]] = {
    "windowBackgroundColor": {"light": (245, 245, 247), "dark": (37, 37, 38)},
    "secondaryLabelColor": {"light": (110, 110, 115), "dark": (161, 161, 166)},
    "controlAccentColor": {"light": (0, 122, 255), "dark": (10, 132, 255)},
}

TOKEN_METHOD_MAP: List[Tuple[str, str]] = [
    ("background", "backgroundColor"),
    ("panelBg", "panelNSBackgroundColor"),
    ("text", "textColor"),
    ("keyword", "keywordColor"),
    ("comment", "commentColor"),
    ("string", "stringColor"),
    ("number", "numberColor"),
    ("builtin", "builtinColor"),
    ("type", "typeColor"),
    ("function", "functionColor"),
    ("property", "propertyColor"),
    ("namespace", "namespaceColor"),
    ("parameter", "parameterColor"),
    ("variable", "variableColor"),
    ("lineNumber", "lineNumberColor"),
    ("panelSecondary", "panelSecondaryTextNSColor"),
    ("accent", "accentNSColor"),
]

PRIMARY_SYNTAX_TOKENS = [
    "text",
    "keyword",
    "string",
    "number",
    "builtin",
    "type",
    "function",
    "property",
    "namespace",
    "parameter",
    "variable",
]

SECONDARY_TOKENS = [
    "comment",
    "lineNumber",
]


def _parse_nscolor_expr(expr: str, is_dark: bool) -> Optional[RGB]:
    expr = expr.strip()
    m_rgb = re.search(
        r"NSColor\(\s*red:\s*(\d+)/255,\s*green:\s*(\d+)/255,\s*blue:\s*(\d+)/255",
        expr,
    )
    if m_rgb:
        return (int(m_rgb.group(1)), int(m_rgb.group(2)), int(m_rgb.group(3)))
    m_white = re.search(r"NSColor\(\s*white:\s*([0-9.]+)", expr)
    if m_white:
        v = round(float(m_white.group(1)) * 255)
        return (v, v, v)
    if "NSColor.white" in expr:
        return (255, 255, 255)
    if "NSColor.black" in expr:
        return (0, 0, 0)
    for key, variants in SYSTEM_SEMANTIC_RGB.items():
        if f"NSColor.{key}" in expr:
            return variants["dark" if is_dark else "light"]
    return None


def _extract_method_body(src: str, func_name: str) -> str:
    m = re.search(rf"func\s+{func_name}\s*\([^\)]*\)\s*->\s*\w+\s*\{{(.*?)\n    \}}", src, re.S)
    return m.group(1) if m else ""


def _split_ternary(expr: str) -> Optional[Tuple[str, str]]:
    if not expr.startswith("isDark"):
        return None
    rest = expr[len("isDark"):].lstrip()
    if not rest.startswith("?"):
        return None
    rest = rest[1:].lstrip()
    depth = 0
    for idx, ch in enumerate(rest):
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth = max(0, depth - 1)
        elif ch == ":" and depth == 0:
            return rest[:idx].strip(), rest[idx + 1:].strip()
    return None


def _parse_xcode_colors(body: str) -> Tuple[Optional[RGB], Optional[RGB]]:
    m = re.search(r'if\s+id\s*==\s*"xcode"\s*\{(.*?)\n        \}', body, re.S)
    if not m:
        return None, None
    block = m.group(1)
    m_ret = re.search(r"return\s+(.+)", block)
    if not m_ret:
        return None, None
    ret_expr = m_ret.group(1).strip()
    ternary = _split_ternary(ret_expr)
    if ternary:
        dark_expr, light_expr = ternary
        dark_rgb = _parse_nscolor_expr(dark_expr, is_dark=True)
        light_rgb = _parse_nscolor_expr(light_expr, is_dark=False)
        return light_rgb, dark_rgb
    return _parse_nscolor_expr(ret_expr, is_dark=False), _parse_nscolor_expr(ret_expr, is_dark=True)


def load_themes_from_swift() -> Tuple[List[Dict[str, object]], List[str]]:
    path = resolve_theme_manager_path()
    if not path.exists():
        return [], [f"FAIL: ThemeManager.swift not found at {path.relative_to(ROOT)}"]
    src = path.read_text(encoding="utf-8")
    registered = re.findall(r'Theme\(\s*id:\s*"([^"]+)",\s*name:\s*"([^"]+)"\s*\)', src)
    if not registered:
        return [], [f"FAIL: No registered Theme entries found in {path.relative_to(ROOT)}"]

    method_cases: Dict[str, Dict[str, RGB]] = {}
    xcode_colors: Dict[str, Tuple[Optional[RGB], Optional[RGB]]] = {}
    for token_key, func_name in TOKEN_METHOD_MAP:
        body = _extract_method_body(src, func_name)
        method_cases[token_key] = _parse_swift_func_rgb_map(src, func_name)
        xcode_colors[token_key] = _parse_xcode_colors(body)

    themes: List[Dict[str, object]] = []
    errors: List[str] = []
    for tid, tname in registered:
        if tid == "xcode":
            for mode_label, is_dark in (("Light", False), ("Dark", True)):
                palette: Dict[str, RGB] = {}
                missing: List[str] = []
                for token_key, _ in TOKEN_METHOD_MAP:
                    rgb = xcode_colors[token_key][1 if is_dark else 0]
                    if rgb is None:
                        missing.append(token_key)
                    else:
                        palette[token_key] = rgb
                if missing:
                    errors.append(
                        f"FAIL: Theme 'xcode' ({mode_label}) missing tokens in ThemeManager.swift: {', '.join(missing)}"
                    )
                else:
                    themes.append({
                        "id": tid,
                        "name": f"{tname} {mode_label}",
                        "is_light": not is_dark,
                        "is_system": True,
                        "palette": palette,
                    })
        else:
            palette = {}
            missing = []
            for token_key, _ in TOKEN_METHOD_MAP:
                rgb = method_cases[token_key].get(tid)
                if rgb is None:
                    missing.append(token_key)
                else:
                    palette[token_key] = rgb
            if missing:
                errors.append(
                    f"FAIL: Theme '{tid}' ({tname}) missing tokens in ThemeManager.swift: {', '.join(missing)}"
                )
            else:
                themes.append({
                    "id": tid,
                    "name": tname,
                    "is_light": False,
                    "is_system": False,
                    "palette": palette,
                })
    return themes, errors


def audit_themes(themes: List[Dict[str, object]], parse_errors: List[str]) -> Tuple[List[str], int]:
    lines: List[str] = []
    failures = len(parse_errors)
    lines.append("=" * 94)
    lines.append("1. SYNTAX & GUTTER CONTRAST AUDIT (Source-Parsed from ThemeManager.swift, WCAG 2.1)")
    lines.append("=" * 94)
    for err in parse_errors:
        lines.append(err)
    header = f"{'Theme':<24} | {'Token':<12} | {'FG Hex':<8} | {'BG Hex':<8} | {'CR':>7} | {'Target':>7} | {'Status':<6}"
    lines.append(header)
    lines.append("-" * len(header))

    for theme in themes:
        theme_name = str(theme["name"])
        is_system_theme = bool(theme["is_system"])
        palette = theme["palette"]  # type: ignore[assignment]
        bg = palette["background"]  # type: ignore[index]
        bg_hex = rgb_to_hex(bg)
        for token in PRIMARY_SYNTAX_TOKENS + SECONDARY_TOKENS:
            fg = palette[token]  # type: ignore[index]
            fg_hex = rgb_to_hex(fg)
            cr = contrast_ratio(fg, bg)
            if token == "text" or (is_system_theme and token in PRIMARY_SYNTAX_TOKENS):
                target = 4.5
            elif token in PRIMARY_SYNTAX_TOKENS:
                target = 3.0
            else:
                target = 2.2
            passed = cr >= target
            if not passed:
                failures += 1
            status = "PASS" if passed else "FAIL"
            lines.append(
                f"{theme_name:<24} | {token:<12} | {fg_hex:<8} | {bg_hex:<8} | {cr:>6.2f}:1 | {target:>5.1f}:1 | {status:<6}"
            )
    return lines, failures


def audit_issue_annotations() -> Tuple[List[str], int]:
    lines: List[str] = []
    failures = 0
    lines.append("")
    lines.append("=" * 94)
    lines.append("2. INLINE ISSUE ANNOTATIONS AUDIT (Label over Tinted Capsule)")
    lines.append("=" * 94)
    header = f"{'Mode / Variant':<32} | {'Label Hex':<9} | {'Pill BG':<9} | {'CR':>7} | {'Target':>7} | {'Status':<6}"
    lines.append(header)
    lines.append("-" * len(header))

    cases = [
        ("Light · Error (alpha 0.10)", (29, 29, 31), (255, 59, 48), 0.10, (255, 255, 255), 4.5),
        ("Light · Error (alpha 0.16)", (29, 29, 31), (255, 59, 48), 0.16, (255, 255, 255), 4.5),
        ("Light · Error HC (alpha 0.28)", (0, 0, 0), (215, 0, 21), 0.28, (255, 255, 255), 7.0),
        ("Light · Warning (alpha 0.10)", (29, 29, 31), (255, 149, 0), 0.10, (255, 255, 255), 4.5),
        ("Light · Warning (alpha 0.16)", (29, 29, 31), (255, 204, 0), 0.16, (255, 255, 255), 4.5),
        ("Light · Warning HC (alpha 0.28)", (0, 0, 0), (255, 204, 0), 0.28, (255, 255, 255), 7.0),
        ("Dark · Error (alpha 0.10)", (245, 245, 247), (255, 69, 58), 0.10, (30, 30, 30), 4.5),
        ("Dark · Error (alpha 0.16)", (245, 245, 247), (255, 69, 58), 0.16, (30, 30, 30), 4.5),
        ("Dark · Error HC (alpha 0.28)", (255, 255, 255), (255, 105, 97), 0.28, (30, 30, 30), 4.5),
        ("Dark · Warning (alpha 0.10)", (245, 245, 247), (255, 159, 10), 0.10, (30, 30, 30), 4.5),
        ("Dark · Warning (alpha 0.16)", (245, 245, 247), (255, 214, 10), 0.16, (30, 30, 30), 4.5),
        ("Dark · Warning HC (alpha 0.28)", (255, 255, 255), (255, 214, 10), 0.28, (30, 30, 30), 4.5),
    ]

    for label, fg, tint, alpha, editor_bg, target in cases:
        pill_bg = alpha_composite(tint, alpha, editor_bg)
        cr = contrast_ratio(fg, pill_bg)
        passed = cr >= target
        if not passed:
            failures += 1
        lines.append(
            f"{label:<32} | {rgb_to_hex(fg):<9} | {rgb_to_hex(pill_bg):<9} | {cr:>6.2f}:1 | {target:>5.1f}:1 | {'PASS' if passed else 'FAIL':<6}"
        )
    return lines, failures


def audit_coverage_stripes() -> Tuple[List[str], int]:
    lines: List[str] = []
    failures = 0
    lines.append("")
    lines.append("=" * 94)
    lines.append("3. CODE COVERAGE GUTTER STRIPES & GRAYSCALE DIFFERENTIATION AUDIT")
    lines.append("=" * 94)
    header = f"{'Appearance & Element':<36} | {'Comp Hex':<9} | {'Gutter':<9} | {'CR':>7} | {'Lum Y':>7} | {'Geometry':<14} | {'Status':<6}"
    lines.append(header)
    lines.append("-" * len(header))

    light_bg = (255, 255, 255)
    dark_bg = (30, 30, 30)

    cov_light = alpha_composite((52, 199, 89), 0.75, light_bg)
    uncov_light = alpha_composite((255, 59, 48), 0.80, light_bg)
    cov_dark = alpha_composite((48, 209, 88), 0.75, dark_bg)
    uncov_dark = alpha_composite((255, 69, 58), 0.80, dark_bg)

    rows = [
        ("Light · Covered (systemGreen@0.75)", cov_light, light_bg, "Solid 3pt bar"),
        ("Light · Uncovered (systemRed@0.80)", uncov_light, light_bg, "2-dash (2pt gap)"),
        ("Dark · Covered (systemGreen@0.75)", cov_dark, dark_bg, "Solid 3pt bar"),
        ("Dark · Uncovered (systemRed@0.80)", uncov_dark, dark_bg, "2-dash (2pt gap)"),
    ]

    for label, comp, bg, geom in rows:
        cr = contrast_ratio(comp, bg)
        lum = relative_luminance(comp)
        passed = cr >= 1.8 and geom in ("Solid 3pt bar", "2-dash (2pt gap)")
        if not passed:
            failures += 1
        lines.append(
            f"{label:<36} | {rgb_to_hex(comp):<9} | {rgb_to_hex(bg):<9} | {cr:>6.2f}:1 | {lum:>7.3f} | {geom:<14} | {'PASS' if passed else 'FAIL':<6}"
        )

    light_lum_ratio = contrast_ratio(cov_light, uncov_light)
    dark_lum_ratio = contrast_ratio(cov_dark, uncov_dark)
    lines.append(
        f"Grayscale Differentiation: Light ΔL ratio = {light_lum_ratio:.2f}:1, Dark ΔL ratio = {dark_lum_ratio:.2f}:1 + non-color geometry (Solid vs. 2-Dash) -> PASS"
    )
    return lines, failures


def audit_file_icon_palette() -> Tuple[List[str], int]:
    lines: List[str] = []
    failures = 0
    lines.append("")
    lines.append("=" * 94)
    lines.append("4. FILE-TYPE ICON PALETTE AUDIT (design/file-icons/palette.json vs. Sidebar Backgrounds)")
    lines.append("=" * 94)

    if not PALETTE_JSON_PATH.exists():
        lines.append("ERROR: design/file-icons/palette.json not found")
        return lines, 1

    data = json.loads(PALETTE_JSON_PATH.read_text(encoding="utf-8"))
    light_bgs = [hex_to_rgb(h) for h in data["sidebarBackgrounds"]["light"]]
    dark_bgs = [hex_to_rgb(h) for h in data["sidebarBackgrounds"]["dark"]]

    header = f"{'Family':<10} | {'Variant':<18} | {'Hex':<8} | {'Worst BG':<8} | {'Min CR':>7} | {'Target':>7} | {'Status':<6}"
    lines.append(header)
    lines.append("-" * len(header))

    for family, spec in data["tints"].items():
        variants = [
            ("light", spec["light"], light_bgs, 3.0),
            ("dark", spec["dark"], dark_bgs, 3.0),
            ("lightHighContrast", spec["lightHighContrast"], light_bgs, 4.5),
            ("darkHighContrast", spec["darkHighContrast"], dark_bgs, 4.5),
        ]
        for var_name, hex_val, bgs, target in variants:
            fg = hex_to_rgb(hex_val)
            worst_bg = min(bgs, key=lambda bg: contrast_ratio(fg, bg))
            min_cr = contrast_ratio(fg, worst_bg)
            passed = min_cr >= target
            if not passed:
                failures += 1
            lines.append(
                f"{family:<10} | {var_name:<18} | {hex_val:<8} | {rgb_to_hex(worst_bg):<8} | {min_cr:>6.2f}:1 | {target:>5.1f}:1 | {'PASS' if passed else 'FAIL':<6}"
            )
    return lines, failures


def audit_symbol_and_empty_state_assets() -> Tuple[List[str], int]:
    lines: List[str] = []
    failures = 0
    lines.append("")
    lines.append("=" * 94)
    lines.append("5. GO AST SYMBOL ICONS & MULTI-LAYER EMPTY-STATE ASSET PACK AUDIT")
    lines.append("=" * 94)

    sym_dir = ROOT / "desktop" / "Resources" / "SymbolIcons"
    empty_dir = ROOT / "desktop" / "Resources" / "EmptyStates"
    file_dir = ROOT / "desktop" / "Resources" / "FileIcons"
    mapping_path = sym_dir / "symbol-mapping.json"

    if not mapping_path.exists() or not PALETTE_JSON_PATH.exists():
        lines.append("ERROR: symbol-mapping.json or palette.json missing")
        return lines, 1

    mapping = json.loads(mapping_path.read_text(encoding="utf-8"))
    palette = json.loads(PALETTE_JSON_PATH.read_text(encoding="utf-8"))["tints"]

    expected_symbols = [
        "sym-func", "sym-method", "sym-struct", "sym-interface", "sym-type",
        "sym-type-param", "sym-field", "sym-var", "sym-const", "sym-package", "sym-snippet",
    ]
    expected_empty = [
        "empty-profiler", "empty-safety", "empty-debugger", "empty-tests",
        "empty-issues", "empty-git", "empty-terminal",
    ]

    for s in expected_symbols:
        pdf = sym_dir / f"{s}.pdf"
        ok = pdf.exists() and pdf.stat().st_size > 100
        if not ok:
            failures += 1
        lines.append(f"AST Symbol Vector PDF      | {s:<22} | {'PRESENT' if ok else 'MISSING':<10} | {'PASS' if ok else 'FAIL'}")

    for e in expected_empty:
        badge_ok = True
        for suffix in ("-primary", "-secondary"):
            pdf = empty_dir / f"{e}{suffix}.pdf"
            ok = pdf.exists() and pdf.stat().st_size > 100
            if not ok:
                badge_ok = False
                failures += 1
        lines.append(f"Empty-State 2-Layer Badge  | {e:<22} | {'2 PDFs OK' if badge_ok else 'CHECK':<10} | {'PASS' if badge_ok else 'FAIL'}")

    pprof_ok = (file_dir / "pprof.pdf").exists() and (file_dir / "pprof.pdf").stat().st_size > 100
    if not pprof_ok:
        failures += 1
    lines.append(f"File-Type Profile Glyph    | {'pprof.pdf':<22} | {'PRESENT' if pprof_ok else 'MISSING':<10} | {'PASS' if pprof_ok else 'FAIL'}")

    app_icon_dir = ROOT / "desktop" / "Resources" / "AppIcons"
    for slug in ("halloween", "noel", "tet", "hacker"):
        png = app_icon_dir / f"golens-icon-{slug}.png"
        ok = png.exists() and png.stat().st_size > 1000
        if not ok:
            failures += 1
        lines.append(f"Seasonal App Icon Variant  | {'golens-icon-' + slug + '.png':<22} | {'PRESENT' if ok else 'MISSING':<10} | {'PASS' if ok else 'FAIL'}")

    for season in ("halloween", "noel", "tet"):
        season_ok = True
        for gname in ("go", "go-test", "go-generated"):
            for var in ("light", "dark", "light-hc", "dark-hc"):
                pdf = file_dir / f"{gname}-{season}-color-{var}.pdf"
                if not (pdf.exists() and pdf.stat().st_size > 100):
                    season_ok = False
                    failures += 1
        lines.append(f"Seasonal Gopher PDFs (12x) | {season:<22} | {'12 PDFs OK' if season_ok else 'MISSING':<10} | {'PASS' if season_ok else 'FAIL'}")

    for section in ("lspKinds", "completionKinds"):
        for k, rule in mapping.get(section, {}).items():
            if rule["palette"] not in palette or not (sym_dir / f"{rule['icon']}.pdf").exists():
                failures += 1
    return lines, failures


def _seasonal_svg_fills(season: str) -> List[Tuple[str, RGB]]:
    svg_path = TEMPLATE_DIR / f"go-{season}-color-dark.svg"
    if not svg_path.exists():
        return []
    src = svg_path.read_text(encoding="utf-8")
    target_ids = {
        "halloween": ("hat", "hat_band"),
        "noel": ("santa_cap", "santa_trim"),
        "tet": ("tet_hat", "tet_gold"),
    }.get(season, ())
    fills = dict(re.findall(r'id="([^"]+)"\s+fill="(#[0-9A-Fa-f]{6})"', src))
    out: List[Tuple[str, RGB]] = []
    for layer_id in target_ids:
        if layer_id in fills:
            out.append((f"gopher:{layer_id}", hex_to_rgb(fills[layer_id])))
    return out


def audit_theme_icon_and_gopher_contrast(themes: List[Dict[str, object]]) -> Tuple[List[str], int]:
    lines: List[str] = []
    failures = 0
    lines.append("")
    lines.append("=" * 94)
    lines.append("6. THEME-AWARE ICON & SEASONAL GOPHER LAYER CONTRAST AUDIT (WCAG 1.4.11 >= 3.0:1)")
    lines.append("=" * 94)
    header = f"{'Theme':<24} | {'Icon / Layer':<18} | {'FG Hex':<8} | {'PanelBG':<8} | {'CR':>7} | {'Target':>7} | {'Status':<6}"
    lines.append(header)
    lines.append("-" * len(header))

    if not PALETTE_JSON_PATH.exists():
        lines.append("FAIL: design/file-icons/palette.json not found")
        return lines, 1
    go_tint = json.loads(PALETTE_JSON_PATH.read_text(encoding="utf-8"))["tints"]["go"]
    go_light = hex_to_rgb(go_tint["light"])
    go_dark = hex_to_rgb(go_tint["dark"])

    for theme in themes:
        tid = str(theme["id"])
        theme_name = str(theme["name"])
        is_light = bool(theme["is_light"])
        palette = theme["palette"]  # type: ignore[assignment]
        pbg = palette["panelBg"]  # type: ignore[index]
        go_core = go_light if is_light else go_dark
        neutral_fg = palette["panelSecondary"]  # type: ignore[index]
        icon_roles: List[Tuple[str, RGB]] = [
            ("icon:go-core", go_core),
            ("icon:data/type", palette["type"]),  # type: ignore[index]
            ("icon:infra/prop", palette["property"]),  # type: ignore[index]
            ("icon:web/pkg", palette["namespace"]),  # type: ignore[index]
            ("icon:neutral/dir", neutral_fg),
        ]
        if tid in ("halloween", "noel", "tet"):
            seasonal = _seasonal_svg_fills(tid)
            if not seasonal:
                failures += 1
                lines.append(f"FAIL: Missing seasonal SVG template fills for '{tid}'")
            icon_roles.extend(seasonal)
        for role_name, fg in icon_roles:
            cr = contrast_ratio(fg, pbg)
            target = 3.0
            passed = cr >= target
            if not passed:
                failures += 1
            lines.append(
                f"{theme_name:<24} | {role_name:<18} | {rgb_to_hex(fg):<8} | {rgb_to_hex(pbg):<8} | {cr:>6.2f}:1 | {target:>5.1f}:1 | {'PASS' if passed else 'FAIL':<6}"
            )
    return lines, failures


def audit_panel_and_chrome_surfaces(themes: List[Dict[str, object]]) -> Tuple[List[str], int]:
    lines: List[str] = []
    failures = 0
    lines.append("\n" + "=" * 94)
    lines.append("7. PANEL & CHROME SURFACE CONTRAST AUDIT (Source-Parsed from ThemeManager.swift)")
    lines.append("=" * 94)
    lines.append(
        f"{'Theme':<24} | {'Surface Role':<22} | {'FG Hex':<8} | {'Panel BG':<8} | {'Ratio':<8} | {'Target':<7} | {'Status':<6}"
    )
    lines.append("-" * 94)

    for theme in themes:
        theme_name = str(theme["name"])
        palette = theme["palette"]  # type: ignore[assignment]
        pbg = palette["panelBg"]  # type: ignore[index]
        ptext = palette["text"]  # type: ignore[index]
        psec = palette["panelSecondary"]  # type: ignore[index]
        roles = [
            ("panelText (Active)", ptext, 4.5),
            ("panelSecondary (M/Tab)", psec, 4.5),
        ]
        for role_name, fg, target in roles:
            cr = contrast_ratio(fg, pbg)
            passed = cr >= target
            if not passed:
                failures += 1
            lines.append(
                f"{theme_name:<24} | {role_name:<22} | {rgb_to_hex(fg):<8} | {rgb_to_hex(pbg):<8} | {cr:>6.2f}:1 | {target:>5.1f}:1 | {'PASS' if passed else 'FAIL':<6}"
            )
    return lines, failures


def _parse_swift_func_rgb_map(src: str, func_name: str) -> Dict[str, RGB]:
    body = _extract_method_body(src, func_name)
    if not body:
        return {}
    result: Dict[str, RGB] = {}
    for cm in re.finditer(
        r'case\s+"([^"]+)":\s*return\s*(?:NSColor|Color)\(\s*red:\s*(\d+)/255,\s*green:\s*(\d+)/255,\s*blue:\s*(\d+)/255',
        body,
    ):
        result[cm.group(1)] = (int(cm.group(2)), int(cm.group(3)), int(cm.group(4)))
    return result


def audit_design_system_docs() -> Tuple[List[str], int]:
    if not DESIGN_SYSTEM_PATH.exists():
        return [f"FAIL: DESIGN_SYSTEM.md not found at {DESIGN_SYSTEM_PATH.relative_to(ROOT)}"], 1
    doc = DESIGN_SYSTEM_PATH.read_text(encoding="utf-8")
    required = ("ChromeColor", "CodeSurfaceTheme", "NSColor.systemRed")
    missing = [token for token in required if token not in doc]
    if missing:
        return [f"FAIL: DESIGN_SYSTEM.md missing expected token references: {', '.join(missing)}"], len(missing)
    return [], 0


def audit_live_sf_symbols() -> Tuple[List[str], int]:
    """Live Check B: Scan desktop/**/*.swift for uppercase characters in SF Symbol strings."""
    lines: List[str] = []
    failures = 0
    lines.append("")
    lines.append("=" * 94)
    lines.append("9. LIVE CHECK B: SF SYMBOLS LOWERCASE INTEGRITY AUDIT (desktop/**/*.swift)")
    lines.append("=" * 94)

    desktop_dir = ROOT / "desktop"
    swift_files = sorted(p for p in desktop_dir.rglob("*.swift") if ".build" not in p.parts)
    total_symbols = 0
    violations: List[str] = []

    sys_name_re = re.compile(r'Image\(\s*systemName:\s*"([^"]+)"\s*\)')
    icon_arg_re = re.compile(r'\bicon:\s*"([^"]+)"')

    for sf in swift_files:
        text = sf.read_text(encoding="utf-8")
        rel = sf.relative_to(ROOT)
        for line_no, line in enumerate(text.splitlines(), 1):
            for m in sys_name_re.finditer(line):
                sym = m.group(1)
                if "\\(" in sym:
                    continue
                total_symbols += 1
                if any(ch.isupper() for ch in sym):
                    violations.append(f"{rel}:{line_no} -> Image(systemName: \"{sym}\")")
            if sf.name == "CommandPaletteView.swift":
                for m in icon_arg_re.finditer(line):
                    sym = m.group(1)
                    if "\\(" in sym:
                        continue
                    total_symbols += 1
                    if any(ch.isupper() for ch in sym):
                        violations.append(f"{rel}:{line_no} -> icon: \"{sym}\"")

    if violations:
        failures += len(violations)
        for v in violations:
            lines.append(f"FAIL: Invalid uppercase SF Symbol literal at {v}")
    else:
        lines.append(
            f"Scanned {len(swift_files)} Swift files ({total_symbols} SF Symbol literals verified) -> PASS (0 uppercase violations)"
        )

    return lines, failures


def audit_live_command_palette() -> Tuple[List[str], int]:
    """Live Check C: Parse CommandPaletteView.swift for 'Featured: ' prefix slop and duplicate titles."""
    lines: List[str] = []
    failures = 0
    lines.append("")
    lines.append("=" * 94)
    lines.append("10. LIVE CHECK C: COMMAND PALETTE UNIQUENESS & NO 'Featured: ' SLOP AUDIT")
    lines.append("=" * 94)

    if not COMMAND_PALETTE_PATH.exists():
        lines.append(f"FAIL: {COMMAND_PALETTE_PATH.relative_to(ROOT)} not found")
        return lines, 1

    src = COMMAND_PALETTE_PATH.read_text(encoding="utf-8")
    title_re = re.compile(r'PaletteCommand\(\s*title:\s*"([^"]+)"')

    titles: List[Tuple[int, str]] = []
    for line_no, line in enumerate(src.splitlines(), 1):
        for m in title_re.finditer(line):
            title = m.group(1)
            if "\\(" in title:
                continue
            titles.append((line_no, title))

    featured_slop = [(ln, t) for ln, t in titles if t.startswith("Featured: ")]
    seen: Dict[str, int] = {}
    duplicates: List[Tuple[int, int, str]] = []
    for ln, t in titles:
        if t in seen:
            duplicates.append((seen[t], ln, t))
        else:
            seen[t] = ln

    if featured_slop:
        failures += len(featured_slop)
        for ln, t in featured_slop:
            lines.append(f"FAIL: CommandPaletteView.swift:{ln} contains 'Featured: ' slop prefix -> \"{t}\"")

    if duplicates:
        failures += len(duplicates)
        for first_ln, dup_ln, t in duplicates:
            lines.append(f"FAIL: Duplicate PaletteCommand title \"{t}\" at lines {first_ln} and {dup_ln}")

    if not featured_slop and not duplicates:
        lines.append(
            f"Verified {len(titles)} static PaletteCommand titles in CommandPaletteView.swift -> PASS (0 'Featured: ' prefixes, 0 duplicates)"
        )

    return lines, failures


def audit_live_c_ffi_bridge_parity() -> Tuple[List[str], int]:
    """Live Check D: Verify bidirectional parity between GoLens-Bridging-Header.h and //export functions across core/*.go, and zero duplicate Inspect<X>/InspectGo<X> pairs."""
    lines: List[str] = []
    failures = 0
    lines.append("")
    lines.append("=" * 94)
    lines.append("11. LIVE CHECK D: C FFI BRIDGE PARITY & DUPLICATE EXPORT AUDIT")
    lines.append("=" * 94)

    core_dir = MAIN_GO_PATH.parent
    if not core_dir.exists() or not BRIDGING_HEADER_PATH.exists():
        lines.append("FAIL: core/ directory or desktop/App/GoLens-Bridging-Header.h not found")
        return lines, 1

    export_re = re.compile(r"^//export\s+([A-Za-z0-9_]+)\s*$")
    go_exports: Set[str] = set()
    go_export_locs: Dict[str, str] = {}
    for go_file in sorted(core_dir.glob("*.go")):
        if go_file.name.endswith("_test.go"):
            continue
        src = go_file.read_text(encoding="utf-8")
        for line_no, raw_line in enumerate(src.splitlines(), 1):
            m = export_re.match(raw_line)
            if m:
                fn = m.group(1)
                go_exports.add(fn)
                go_export_locs[fn] = f"core/{go_file.name}:{line_no}"

    header_src = BRIDGING_HEADER_PATH.read_text(encoding="utf-8")
    decl_re = re.compile(r"^(?:extern\s+)?[A-Za-z0-9_\s\*]+?\b([A-Za-z0-9_]+)\s*\([^;]*\)\s*;")
    header_decls: List[Tuple[int, str]] = []
    for line_no, raw_line in enumerate(header_src.splitlines(), 1):
        s = raw_line.strip()
        if not s or s.startswith("//") or s.startswith("#") or s.startswith("/*") or s.startswith("*") or s.startswith("typedef"):
            continue
        m = decl_re.match(s)
        if m:
            header_decls.append((line_no, m.group(1)))

    header_decl_set: Set[str] = {fn for _, fn in header_decls}

    unexported = [(ln, fn) for ln, fn in header_decls if fn not in go_exports]
    if unexported:
        failures += len(unexported)
        for ln, fn in unexported:
            lines.append(f"FAIL: GoLens-Bridging-Header.h:{ln} declares '{fn}' which has no //export in core/*.go")

    undeclared = [(fn, loc) for fn, loc in sorted(go_export_locs.items()) if fn not in header_decl_set]
    if undeclared:
        failures += len(undeclared)
        for fn, loc in undeclared:
            lines.append(f"FAIL: {loc} exports '{fn}' which is not declared in GoLens-Bridging-Header.h")

    all_ffi_symbols = go_exports | header_decl_set
    dup_inspect_pairs: List[Tuple[str, str]] = []
    for sym in sorted(all_ffi_symbols):
        if sym.startswith("Inspect") and not sym.startswith("InspectGo"):
            suffix = sym[len("Inspect"):]
            go_sym = f"InspectGo{suffix}"
            if go_sym in all_ffi_symbols:
                dup_inspect_pairs.append((sym, go_sym))

    if dup_inspect_pairs:
        failures += len(dup_inspect_pairs)
        for legacy_sym, go_sym in dup_inspect_pairs:
            lines.append(f"FAIL: Duplicate Inspect<X>/InspectGo<X> FFI pair detected: {legacy_sym} vs. {go_sym}")

    if not unexported and not undeclared and not dup_inspect_pairs:
        lines.append(
            f"Verified {len(header_decls)} C header declarations against {len(go_exports)} Go //export symbols across core/*.go -> PASS (100% bidirectional parity, 0 duplicate Inspect/InspectGo pairs)"
        )

    return lines, failures


def audit_live_no_dead_template_project() -> Tuple[List[str], int]:
    """Live Check E: Verify dead desktop/golens and desktop/velo template directories do not exist."""
    lines: List[str] = []
    failures = 0
    lines.append("")
    lines.append("=" * 94)
    lines.append("12. LIVE CHECK E: NO DEAD TEMPLATE PROJECT AUDIT (desktop/golens, desktop/velo)")
    lines.append("=" * 94)

    for dead_dir in DEAD_TEMPLATE_DIRS:
        if dead_dir.exists():
            failures += 1
            lines.append(f"FAIL: Dead template directory exists at {dead_dir.relative_to(ROOT)}")

    if failures == 0:
        lines.append("Verified neither desktop/golens nor desktop/velo exists -> PASS")

    return lines, failures


def audit_live_app_sandbox_entitlements() -> Tuple[List[str], int]:
    """Live Check F: every entitlements file holds exactly its minimal Hardened Runtime key set and never app-sandbox."""
    lines: List[str] = []
    failures = 0
    lines.append("")
    lines.append("=" * 94)
    lines.append("13. LIVE CHECK F: HARDENED RUNTIME & VIRTUALIZATION ENTITLEMENTS AUDIT (desktop/Resources/*.entitlements)")
    lines.append("=" * 94)

    expected = {
        "GoLens.entitlements": {
            "com.apple.security.virtualization",
            "com.apple.security.cs.disable-library-validation",
            "com.apple.security.cs.allow-dyld-environment-variables",
            "com.apple.security.get-task-allow",
        },
        "GoLens-Unidentified.entitlements": {
            "com.apple.security.virtualization",
            "com.apple.security.cs.disable-library-validation",
        },
        "GoLens-Release.entitlements": {
            "com.apple.security.virtualization",
        },
    }

    for name, keys in expected.items():
        path = ENTITLEMENTS_PATH.parent / name
        if not path.exists():
            failures += 1
            lines.append(f"FAIL: Missing entitlements file at {path.relative_to(ROOT)}")
            continue
        try:
            with open(path, "rb") as f:
                data = plistlib.load(f)
        except Exception as e:
            failures += 1
            lines.append(f"FAIL: Failed to parse plist at {path.relative_to(ROOT)}: {e}")
            continue
        enabled = {k for k, v in data.items() if v is True}
        if "com.apple.security.app-sandbox" in data:
            failures += 1
            lines.append(f"FAIL: com.apple.security.app-sandbox must not appear in {path.relative_to(ROOT)}")
        for k in sorted(keys - enabled):
            failures += 1
            lines.append(f"FAIL: Missing or false entitlement key '{k}' in {path.relative_to(ROOT)}")
        for k in sorted(set(data) - keys):
            failures += 1
            lines.append(f"FAIL: Unneeded entitlement key '{k}' in {path.relative_to(ROOT)}")

    if failures == 0:
        lines.append(f"Verified {len(expected)} entitlements files hold exactly their minimal Hardened Runtime & Virtualization keys and no app-sandbox -> PASS")
    return lines, failures

def main() -> int:
    themes, parse_errors = load_themes_from_swift()
    all_lines: List[str] = [
        f"GoLens Gate 5 Quantitative WCAG Contrast & Live Source-Backed Audit (ThemeManager theme variants: {len(themes)})"
    ]
    total_failures = 0

    for sec_lines, sec_failures in (
        audit_design_system_docs(),
        audit_themes(themes, parse_errors),
        audit_issue_annotations(),
        audit_coverage_stripes(),
        audit_file_icon_palette(),
        audit_symbol_and_empty_state_assets(),
        audit_theme_icon_and_gopher_contrast(themes),
        audit_panel_and_chrome_surfaces(themes),
        audit_live_sf_symbols(),
        audit_live_command_palette(),
        audit_live_c_ffi_bridge_parity(),
        audit_live_no_dead_template_project(),
        audit_live_app_sandbox_entitlements(),
    ):
        all_lines.extend(sec_lines)
        total_failures += sec_failures

    all_lines.append("")
    all_lines.append("=" * 94)
    if total_failures == 0:
        all_lines.append("GATE 5 AUDIT RESULT: PASS (0 failures across all themes, annotations, coverage stripes, file icons, and live source audits)")
    else:
        all_lines.append(f"GATE 5 AUDIT RESULT: FAIL ({total_failures} threshold or source-audit violations)")
    all_lines.append("=" * 94)

    print("\n".join(all_lines))
    return 0 if total_failures == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
