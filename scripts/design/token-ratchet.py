#!/usr/bin/env python3
"""Design-system ratchet for desktop/.

  token-ratchet.py                 print every metric next to the baseline
  token-ratchet.py --check         exit 1 when a literal metric went up; token-use counts are
                                   informational, because merging copies into a shared
                                   component lowers them legitimately
  token-ratchet.py --diff [REF]    exit 1 when lines added since REF (default HEAD, plus
                                   untracked files) use a literal the design system forbids
  token-ratchet.py --update        rewrite the baseline; only commit it when every metric
                                   moved the right way
"""
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
SRC = ROOT / "desktop"
BASELINE = pathlib.Path(__file__).with_name("token-baseline.txt")
TOKENS = "DesignTokens.swift"
THEMES = "ThemeManager.swift"

ROLE = r"(Row|Badge|Chip|Pill|Header|Card|EmptyState|Banner|Field|Section|Button|Tag)"
STATUS_COLOR = (r"Color\(nsColor: \.system(Red|Orange|Green|Yellow)\)|foregroundStyle\(\.(red|orange|green|yellow)\)"
                r"|Color\.(red|orange|green|yellow)\b")
ANIMATION = r"\.(easeInOut|easeOut|easeIn|linear|spring|snappy|smooth|bouncy)\((duration|response)"

# key, description, pattern, direction, files excluded, checked on added lines
METRICS = [
    ("radius_literals", "corner radius literals", r"cornerRadius: *[0-9]", "down", (TOKENS,), True),
    ("radius_tokens", "CornerRadius token uses", r"CornerRadius\.[a-zA-Z]", "up", (TOKENS,), False),
    ("raw_colors", "raw RGB/hex colors", r"Color\(red:|Color\(hex|NSColor\((red|calibratedRed|srgbRed):",
     "down", (THEMES,), True),
    ("fixed_fonts", "fixed .system(size:)", r"\.system\(size:", "down", (), False),
    ("fixed_fonts_styled", "fixed sizes 10-13pt (have a text style)", r"\.system\(size: *(10|11|12|13)[,)]",
     "down", (), True),
    ("fixed_fonts_small", "fixed sizes 8-9pt", r"\.system\(size: *(8|9)[,)]", "down", (), True),
    ("text_styles", "text style uses",
     r"\.font\(\.(caption2?|footnote|callout|subheadline|body|headline|title[0-9]?)", "up", (), False),
    ("tap_gestures", "onTapGesture", r"onTapGesture", "down", (), True),
    ("spacing_literals", "spacing literals in padding/stack spacing",
     r"\.padding\((\.[a-zA-Z]+, *)?[0-9.]+\)|spacing: *[1-9][0-9.]*", "down", (TOKENS,), True),
    ("spacing_offscale", "off-scale spacing 1/3/5/7/14/20",
     r"\.padding\((\.[a-zA-Z]+, *)?(1|3|5|7|14|20)\)|spacing: *(1|3|5|7|14|20)\b", "down", (TOKENS,), False),
    ("spacing_tokens", "Spacing token uses", r"Spacing\.[a-z]", "up", (TOKENS,), False),
    ("octagon_glyphs", "octagon error glyphs", r'"(xmark|exclamationmark)\.octagon(\.fill)?"', "down", (), True),
    ("status_colors", "hand-picked status colors", STATUS_COLOR, "down", (TOKENS,), True),
    ("primary_opacity", "Color.primary.opacity literals", r"Color\.primary\.opacity\(", "down", (TOKENS,), True),
    ("view_theme_checks", "views checking usesSystemMaterials", r"usesSystemMaterials", "down",
     (TOKENS, THEMES, "WorkspaceState.swift"), True),
    ("theme_color_tokens", "ThemeColor and wellBackground uses", r"ThemeColor\.|\.wellBackground\(", "up",
     (TOKENS,), False),
    ("animation_literals", "literal animation curves", ANIMATION, "down", (TOKENS,), True),
    ("motion_tokens", "Motion token uses", r"Motion\.(quick|standard|emphasized)", "up", (TOKENS,), False),
    ("shortcut_literals", "literal keyboardShortcut(\"...\")", r'\.keyboardShortcut\("', "down", (), True),
    ("old_theme_helpers", "workspace.themeText/Background/AccentColor in views",
     r"workspace\.theme(Text|Background|AccentColor)\(", "down", (TOKENS,), True),
    ("stroke_literals", "literal lineWidth", r"lineWidth: *[0-9.]+", "down", (TOKENS,), True),
    ("direct_glass", "glass or material outside shared surfaces",
     r"\.glassEffect\(|\.(ultraThin|thin|regular|thick|bar)Material", "down",
     (TOKENS, "FloatingPopup.swift", "GopilotPanelView.swift"), True),
    ("hand_formatting", "hand-rolled byte or date formatting", r"func formatBytes|(?<![A-Za-z0-9])DateFormatter\(\)",
     "down", (), True),
    ("sheet_size_literals", "literal sheet sizes (width >= 400)", r"\.frame\((min|ideal)?[wW]idth: *[4-9][0-9]{2}\b",
     "down", (TOKENS,), True),
    ("private_role_structs", "private role structs (per-file copies)",
     r"(private|fileprivate) struct [A-Za-z0-9]*" + ROLE + r"\b", "down", (), True),
    ("silent_beeps", "silent NSSound.beep() calls", r"NSSound\.beep\(", "down", (), True),
    ("hardcoded_help_shortcuts", "hardcoded shortcut glyphs in .help(", r"\.help\([^)\n]*[⌘⇧⌥⌃]", "down", (), True),
]


def swift_files():
    return sorted(p for p in SRC.rglob("*.swift") if ".build" not in p.parts)


def count(pattern, excluded):
    rx = re.compile(pattern)
    total = 0
    for path in swift_files():
        if path.name in excluded:
            continue
        total += sum(1 for line in path.read_text(errors="replace").splitlines() if rx.search(line))
    return total


def own_banners():
    head = re.compile(r"^(private |fileprivate )?struct [A-Za-z0-9]*Banner[A-Za-z0-9]*(<[^>]*>)? *: *View")
    uses = re.compile(r"InlineBanner(\(|$)")
    total = 0
    for path in swift_files():
        inside, composed = False, False
        for line in path.read_text(errors="replace").splitlines():
            if head.match(line):
                inside, composed = True, False
            elif inside and uses.search(line):
                composed = True
            elif inside and line.startswith("}"):
                total += 0 if composed else 1
                inside = False
    return total


def measure():
    values = {key: count(pattern, excluded) for key, _, pattern, _, excluded, _ in METRICS}
    values["own_banners"] = own_banners()
    return values


DESCRIPTIONS = {key: (desc, direction) for key, desc, _, direction, _, _ in METRICS}
DESCRIPTIONS["own_banners"] = ("banner views not built on InlineBanner", "down")


def read_baseline():
    if not BASELINE.exists():
        return {}
    pairs = (line.split() for line in BASELINE.read_text().splitlines() if line.strip())
    return {key: int(value) for key, value in pairs}


def regressed(key, value, base):
    direction = DESCRIPTIONS[key][1]
    return value > base if direction == "down" else value < base


def added_lines(ref):
    diff = subprocess.run(["git", "diff", "-U0", ref, "--", "desktop"], cwd=ROOT,
                          capture_output=True, text=True, check=True).stdout
    current = None
    for line in diff.splitlines():
        if line.startswith("+++ "):
            current = line[6:] if line.startswith("+++ b/") else None
        elif line.startswith("+") and current and current.endswith(".swift"):
            yield current, line[1:]
    untracked = subprocess.run(["git", "ls-files", "--others", "--exclude-standard", "desktop"], cwd=ROOT,
                               capture_output=True, text=True, check=True).stdout.split()
    for name in untracked:
        if name.endswith(".swift"):
            for line in (ROOT / name).read_text(errors="replace").splitlines():
                yield name, line


def check_diff(ref):
    rules = [(desc, re.compile(pattern), excluded)
             for _, desc, pattern, _, excluded, on_diff in METRICS if on_diff]
    findings = []
    for name, line in added_lines(ref):
        base = pathlib.Path(name).name
        for desc, rx, excluded in rules:
            if base not in excluded and rx.search(line):
                findings.append(f"{name}: {desc}: {line.strip()}")
    for finding in findings:
        print(finding)
    print(f"{len(findings)} forbidden literal(s) in lines added since {ref}")
    return 1 if findings else 0


def self_test():
    assert regressed("radius_literals", 744, 743) and not regressed("radius_literals", 742, 743)
    assert regressed("spacing_tokens", 6, 7) and not regressed("spacing_tokens", 8, 7)
    rules = {key: re.compile(pattern) for key, _, pattern, _, _, _ in METRICS}
    assert rules["spacing_literals"].search(".padding(.horizontal, 12)")
    assert not rules["spacing_literals"].search(".padding(.horizontal, Spacing.comfortable)")
    assert not rules["spacing_literals"].search("VStack(spacing: 0)")
    assert rules["fixed_fonts_styled"].search(".font(.system(size: 11, weight: .semibold))")
    assert not rules["fixed_fonts_styled"].search(".font(.system(size: 32, weight: .bold))")
    assert rules["status_colors"].search(".foregroundStyle(Color(nsColor: .systemOrange))")
    assert rules["private_role_structs"].search("private struct LargeFileBanner: View {")
    assert rules["animation_literals"].search("withAnimation(.easeInOut(duration: 0.15)) {")
    assert not rules["animation_literals"].search("withAnimation(Motion.quick) {")
    assert rules["old_theme_helpers"].search(".foregroundStyle(workspace.themeText(isActive: true, isDark: isDark))")
    assert rules["stroke_literals"].search(".strokeBorder(color, lineWidth: 0.5)")
    assert not rules["stroke_literals"].search(".strokeBorder(color, lineWidth: Stroke.hairline)")
    assert rules["hand_formatting"].search("let formatter = DateFormatter()")
    assert not rules["hand_formatting"].search("let iso = ISO8601DateFormatter()")
    assert rules["sheet_size_literals"].search(".frame(width: 760, height: 540)")
    assert not rules["sheet_size_literals"].search(".frame(width: 320, alignment: .leading)")
    assert rules["silent_beeps"].search("guard ok else { NSSound.beep(); return }")
    assert not rules["silent_beeps"].search("workspace.presentCommandFeedback(reason)")
    assert rules["hardcoded_help_shortcuts"].search('.help("Run Project (⌘R)")')
    assert not rules["hardcoded_help_shortcuts"].search('.help(KeymapStore.shared.labeled("Run Project", "product.run"))')
    print("self-test passed")
    return 0


def main(args):
    if "--self-test" in args:
        return self_test()
    if "--diff" in args:
        index = args.index("--diff")
        ref = args[index + 1] if index + 1 < len(args) and not args[index + 1].startswith("--") else "HEAD"
        return check_diff(ref)

    values = measure()
    if "--update" in args:
        BASELINE.write_text("".join(f"{key} {value}\n" for key, value in values.items()))
        print(f"baseline written: {BASELINE.relative_to(ROOT)}")
        return 0

    baseline = read_baseline()
    failures = 0
    for key, value in values.items():
        desc, direction = DESCRIPTIONS[key]
        base = baseline.get(key)
        bad = base is not None and direction == "down" and regressed(key, value, base)
        failures += bad
        mark = "REGRESSED" if bad else ("info" if direction == "up" else "")
        shown = "-" if base is None else base
        print(f"{desc:<45} {value:>6}  baseline {shown:>6}  must go {direction:<4} {mark}")
    if "--check" in args:
        if not baseline:
            print("no baseline: run with --update first")
            return 1
        print(f"{failures} metric(s) regressed")
        return 1 if failures else 0
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
