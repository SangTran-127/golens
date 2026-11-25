#!/usr/bin/env python3
"""AI slop scanner with a ratchet gate. Usage and scoring are documented in ../SKILL.md."""

import argparse
import bisect
import fnmatch
import json
import math
import os
import re
import subprocess
import sys
import time
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any, Callable, Dict, Iterable, List, Optional, Set, Tuple

Finding = Dict[str, Any]

IGNORED_DIRS: Set[str] = {
    ".git", ".claude", ".agents", ".agent", ".build", "build", "DerivedData", "TreeSitterGrammars",
    "node_modules", "vendor", "dist", "out", ".next", ".nuxt", "__pycache__", ".venv", "venv",
    ".pytest_cache", ".mypy_cache", ".ruff_cache", ".idea", ".vscode", "Pods", "target",
}
CODE_EXTENSIONS: Set[str] = {
    ".swift", ".go", ".ts", ".tsx", ".js", ".jsx", ".py", ".rs", ".c", ".h", ".cpp", ".hpp", ".m", ".mm",
}
SCRIPT_EXTENSIONS: Set[str] = {".py", ".sh"}
DOC_EXTENSIONS: Set[str] = {".md", ".txt", ".rst"}
DATA_EXTENSIONS: Set[str] = {".json", ".yaml", ".yml", ".html", ".strings"}
TEXT_EXTENSIONS: Set[str] = CODE_EXTENSIONS | SCRIPT_EXTENSIONS | DOC_EXTENSIONS | DATA_EXTENSIONS
ASSET_EXTENSIONS: Set[str] = {".pdf", ".png", ".svg", ".jpg", ".jpeg", ".heic", ".tiff", ".icns"}
MAX_FILE_BYTES = 5 * 1024 * 1024
APP_SOURCE_ROOTS = ("desktop/", "core/")
DEFAULT_LIMIT = 20
DEFAULT_BASELINE = "scripts/design/slop-baseline.json"
DEFAULT_ALLOW = "scripts/design/slop-allow.txt"
SEVERITY_RANK = {"Critical": 0, "High": 1, "Warning": 2}
SEVERITY_WEIGHT = {"Critical": 8, "High": 3, "Warning": 1}

EMOJI_REGEX = re.compile("[\u2600-\u27BF\u2B00-\u2BFF\uFE0F\U0001F000-\U0001FAFF]+")
DECORATIVE_PREFIX = re.compile(
    "^[\u2022\u2023\u2605\u2606\u2726\u2727\u2728\u25CF\u25CB\u25C6\u25C7\u25B6\u25BA\u2756\u2B50\u27A4\u26A1]\\s*[A-Za-z]"
)
MARKETING_PREFIX = re.compile(
    r"^(Featured|New|Beta|Hot|Recommended|Updated|Popular|Trending|Experimental|Improved|Enhanced"
    r"|Suggested|Smart|Contextual|Premium|Pinned|Highlighted|Spotlight)\s*:\s"
)
TITLE_LITERAL_CONTEXT = re.compile(r"(?:\btitle:|\b(?:Button|Label|Text|Toggle)\()\s*$")
SF_SYMBOL_CONTEXT = re.compile(r"(?:\bsystemName:|\bsystemImage:|\bsystemSymbolName:|\bicon:)\s*$")
SF_SYMBOL_STRICT_CONTEXT = re.compile(r"(?:\bsystemName:|\bsystemImage:|\bsystemSymbolName:)\s*$")
SF_SYMBOL_NAME = re.compile(r"^[a-z0-9]+(?:\.[a-z0-9]+)*$")
SF_SYMBOL_ANY_CASE = re.compile(r"^[A-Za-z0-9]+(?:\.[A-Za-z0-9]+)*$")
SWIFT_UI_CONTEXT = re.compile(
    r"(?:\b(?:Text|Button|Label|Toggle|Menu|Section|Picker|TextField|SecureField|Link|LabeledContent|GroupBox"
    r"|DisclosureGroup|ContentUnavailableView|NavigationLink|PaletteCommand|NSMenuItem)\(\s*"
    r"|\.(?:help|alert|confirmationDialog|navigationTitle|accessibilityLabel|accessibilityHint|badge)\(\s*"
    r"|\b(?:title|message|subtitle|detail|label|prompt|placeholder|informativeText|messageText|summary|reason)"
    r"\s*[:=]\s*|Feedback\(\s*)$"
)
GO_UI_CONTEXT = re.compile(
    r"\b(?:Title|Message|Summary|Detail|Description|Label|Reason|Hint|Headline"
    r"|title|message|summary|detail|description|label|reason|hint|headline)\s*[:=]\s*(?:fmt\.Sprintf\(\s*)?$"
)
INTERNAL_CODE = re.compile(
    r"\[(?!REDACTED)[A-Z][A-Z0-9_]{2,}\]|(?<![A-Za-z0-9_])[A-Z][A-Z0-9]*_[A-Z0-9_]*[A-Z0-9]:"
)
PLAN_ID = re.compile(
    r"(?i:\bphase-\d+\b)|\bplans/\d{6}|(?i:\bwave[-_ ]?\d+\b)"
    r"|\b(?:DEFECT|FINDING|AUDIT|GAP|ISSUE|RISK)-[A-Z0-9]+(?:-[A-Z0-9]+)*\b"
)
TODO_IN_LITERAL = re.compile(r"(?://|/\*|#)\s*(?:TODO|FIXME|XXX)\b|^\s*(?:TODO|FIXME)\s*[(:]")
PASS_WORD = re.compile(r"(?:\b(?:PASS(?:ED)?|OK)\b|\bpass(?:ed|es)?\b)(?!\s*[<>=])")
LITERAL_METRIC = re.compile(
    r"(?<![\w./<>=-])\d+/\d+(?![\w/])|(?<![\w.<>=])\d+(?:\.\d+)?%"
    r"|(?<![\w.<>=])\d+\s+(?:[\w/-]+\s+){0,2}(?:error\(s\)|errors?|failures?|violations?|scenarios?|checks?"
    r"|tests?|regressions?|issues?|warnings?)\b"
)
SIMPLE_INTERPOLATION = re.compile(r"\{[^{}\"']*\}|\$\{[^}]*\}|\$\([^)]*\)|\$[A-Za-z_0-9@#?]+")
GATE_SCRIPT_NAME = re.compile(r"audit|check|gate|verify", re.I)
PY_READS = re.compile(
    r"\bopen\s*\(|\.\s*read_(?:text|bytes)\s*\(|\bos\s*\.\s*(?:walk|listdir|scandir)\s*\(|\.\s*r?glob\s*\("
    r"|\bglob\s*\.\s*i?glob\s*\(|\bsubprocess\s*\.\s*\w+\s*\(|\.\s*iterdir\s*\(|\bsys\s*\.\s*stdin\b"
    r"|\b(?:check_output|run|Popen)\s*\(\s*\["
)
SH_READS = re.compile(
    r"(?:^|[|;&(`{]|\bthen\b|\bdo\b|\belse\b|!)\s*(?:command\s+|sudo\s+|env\s+)?"
    r"(?:grep|egrep|rg|cat|find|git|sed|awk|head|tail|wc|diff|cmp|jq|ls|stat|python3?|go|swift|make|xcrun"
    r"|plutil|sqlite3|curl|shasum|md5|otool|nm|codesign|lsof|pgrep|ps|cp|swiftc|clang|cc|xcodebuild|bash|sh"
    r"|node)\b"
    r"|(?<![<0-9])<\s*(?![<(])[\"$\w./~]|\[\[?\s+-[efdsr]\s",
    re.M,
)


class SourceFile:
    def __init__(self, rel: str, text: str) -> None:
        self.rel = rel
        self.text = text
        self.lines = text.splitlines()
        self.path = Path(rel)
        self.name = self.path.name
        self.suffix = self.path.suffix.lower()
        self._lexed: Optional[Tuple[List[Tuple[int, str]], List[Tuple[int, str, str]], str]] = None
        self._newlines: Optional[List[int]] = None

    def line_of(self, pos: int) -> int:
        if self._newlines is None:
            self._newlines = [m.start() for m in re.finditer("\n", self.text)]
        return bisect.bisect_left(self._newlines, pos) + 1

    @property
    def lexed(self) -> Tuple[List[Tuple[int, str]], List[Tuple[int, str, str]], str]:
        if self._lexed is None:
            self._lexed = lex(self)
        return self._lexed

    @property
    def comments(self) -> List[Tuple[int, str]]:
        return self.lexed[0]

    @property
    def strings(self) -> List[Tuple[int, str, str]]:
        return self.lexed[1]

    @property
    def code(self) -> str:
        return self.lexed[2]


TOKEN_RE = {
    ".go": re.compile(r"//|/\*|\"|`|'"),
    ".swift": re.compile(r"//|/\*|#*\""),
    ".py": re.compile(r"#|(?<![A-Za-z0-9_])[rRbBuUfF]{0,2}(?:\"\"\"|'''|\"|')"),
}
GO_STRING = re.compile(r"\"(?:[^\"\\\n]|\\.)*\"?")
GO_RUNE = re.compile(r"'(?:[^'\\\n]|\\.)*'?")
PY_BODY = {
    '"""': re.compile(r"(?:\\.|[^\\])*?\"\"\"", re.S),
    "'''": re.compile(r"(?:\\.|[^\\])*?'''", re.S),
    '"': re.compile(r"(?:\\.|[^\\\n\"])*\"?"),
    "'": re.compile(r"(?:\\.|[^\\\n'])*'?"),
}
SWIFT_STR_SPECIAL = re.compile(r"[\"\\\n]")
SWIFT_INTERP_SPECIAL = re.compile(r"[()\"]")


def _swift_string(text: str, start: int) -> Tuple[int, str]:
    i = start
    hashes = 0
    while text[i] == "#":
        hashes += 1
        i += 1
    multi = text.startswith('"""', i)
    quote = '"""' if multi else '"'
    i += len(quote)
    close = quote + "#" * hashes
    escape = "\\" + "#" * hashes
    out: List[str] = []
    n = len(text)
    while i < n:
        m = SWIFT_STR_SPECIAL.search(text, i)
        if not m:
            out.append(text[i:])
            return n, "".join(out)
        k = m.start()
        out.append(text[i:k])
        ch = text[k]
        if ch == "\n":
            if not multi:
                return k, "".join(out)
            out.append("\n")
            i = k + 1
        elif ch == '"':
            if text.startswith(close, k):
                return k + len(close), "".join(out)
            out.append('"')
            i = k + 1
        elif text.startswith(escape, k):
            j = k + len(escape)
            if j < n and text[j] == "(":
                i = _skip_interpolation(text, j + 1)
                out.append("{}")
            else:
                out.append(text[k:j + 1])
                i = j + 1
        else:
            out.append("\\")
            i = k + 1
    return n, "".join(out)


def _skip_interpolation(text: str, i: int) -> int:
    depth = 0
    n = len(text)
    while i < n:
        m = SWIFT_INTERP_SPECIAL.search(text, i)
        if not m:
            return n
        k = m.start()
        ch = text[k]
        if ch == "(":
            depth += 1
            i = k + 1
        elif ch == ")":
            if depth == 0:
                return k + 1
            depth -= 1
            i = k + 1
        else:
            i, _ = _swift_string(text, k)
    return n


def _lex_spans(sf: SourceFile) -> Tuple[List[Tuple[int, int]], List[Tuple[int, int, str]]]:
    text = sf.text
    token = TOKEN_RE[sf.suffix]
    comments: List[Tuple[int, int]] = []
    strings: List[Tuple[int, int, str]] = []
    pos = 0
    n = len(text)
    while pos < n:
        m = token.search(text, pos)
        if not m:
            break
        s = m.start()
        tok = m.group()
        if tok in ("//", "#"):
            e = text.find("\n", s)
            e = n if e < 0 else e
            comments.append((s, e))
        elif tok == "/*":
            e = text.find("*/", s + 2)
            e = n if e < 0 else e + 2
            comments.append((s, e))
        elif sf.suffix == ".go":
            if tok == "`":
                e = text.find("`", s + 1)
                e = n if e < 0 else e + 1
                strings.append((s, e, text[s + 1:e - 1]))
            elif tok == "'":
                e = GO_RUNE.match(text, s).end()
            else:
                e = GO_STRING.match(text, s).end()
                strings.append((s, e, text[s + 1:e - 1]))
        elif sf.suffix == ".swift":
            e, content = _swift_string(text, s)
            strings.append((s, e, content))
        else:
            quote = tok.lstrip("rRbBuUfF")
            body = m.end()
            e = PY_BODY[quote].match(text, body).end()
            inner_end = e - len(quote) if text.endswith(quote, body, e) else e
            strings.append((s, e, text[body:inner_end]))
        pos = max(e, s + 1)
    return comments, strings


def lex(sf: SourceFile) -> Tuple[List[Tuple[int, str]], List[Tuple[int, str, str]], str]:
    if sf.suffix not in TOKEN_RE:
        return [], [], sf.text
    comment_spans, string_spans = _lex_spans(sf)
    text = sf.text
    comments: List[Tuple[int, str]] = []
    for s, e in comment_spans:
        first = sf.line_of(s)
        for k, part in enumerate(text[s:e].split("\n")):
            comments.append((first + k, part))
    strings: List[Tuple[int, str, str]] = []
    for s, e, content in string_spans:
        line_start = text.rfind("\n", 0, s) + 1
        strings.append((sf.line_of(s), content, text[line_start:s]))
    spans = sorted([(s, e) for s, e in comment_spans] + [(s, e) for s, e, _ in string_spans])
    parts: List[str] = []
    pos = 0
    for s, e in spans:
        if s < pos:
            continue
        parts.append(text[pos:s])
        parts.append(re.sub(r"[^\n]", " ", text[s:e]))
        pos = e
    parts.append(text[pos:])
    return comments, strings, "".join(parts)


def string_lines(strings: Iterable[Tuple[int, str, str]]) -> Iterable[Tuple[int, str, str]]:
    for line, content, prefix in strings:
        for k, part in enumerate(content.split("\n")):
            yield line + k, part, prefix if k == 0 else ""


def is_test_path(rel: str) -> bool:
    parts = rel.split("/")
    name = parts[-1]
    if set(parts[:-1]) & {"tests", "Tests", "test", "testdata", "fixtures", "Fixtures"}:
        return True
    return (
        name.endswith("_test.go")
        or name.startswith("test_")
        or name.endswith("_test.py")
    )


def is_generated(sf: SourceFile) -> bool:
    return any("DO NOT EDIT" in line and "generated" in line.lower() for line in sf.lines[:5])


class Context:
    def __init__(
        self, workspace: Path, files: Dict[str, SourceFile], skipped: List[str], in_git: bool, all_rels: List[str],
    ) -> None:
        self.workspace = workspace
        self.asset_names: Set[str] = set()
        for rel in all_rels:
            if Path(rel).suffix.lower() in ASSET_EXTENSIONS:
                stem = Path(rel).stem
                self.asset_names.update({stem, stem.rsplit("-", 1)[-1]})
        self.files = files
        self.skipped = skipped
        self.in_git = in_git
        roots = [r for r in APP_SOURCE_ROOTS if any(rel.startswith(r) for rel in files)]
        self.app_roots = tuple(roots)
        self._registry: Optional[Set[str]] = None
        self._registry_loaded = False

    def is_app_source(self, rel: str) -> bool:
        return (not self.app_roots or rel.startswith(self.app_roots)) and not is_test_path(rel)

    def symbol_registry(self) -> Optional[Set[str]]:
        if self._registry_loaded:
            return self._registry
        self._registry_loaded = True
        doc = self.files.get("DESIGN_SYSTEM.md")
        if doc is None:
            return None
        section: List[str] = []
        level = 0
        for line in doc.lines:
            m = re.match(r"^(#+)\s+(.*)", line)
            if m and level and len(m.group(1)) <= level:
                break
            if m and not level and "Iconography" in m.group(2):
                level = len(m.group(1))
            if level:
                section.append(line)
        if section:
            self._registry = set(re.findall(r"`([a-z0-9]+(?:\.[a-z0-9]+)*)`", "\n".join(section)))
        return self._registry

    def by_suffix(self, *suffixes: str) -> List[SourceFile]:
        return [sf for sf in self.files.values() if sf.suffix in suffixes]


def git(workspace: Path, *args: str, check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(["git", "-C", str(workspace), *args], capture_output=True, check=check)


def list_files(workspace: Path, include_untracked: bool) -> Tuple[List[str], bool]:
    try:
        args = ["ls-files", "-z", "--cached"]
        if include_untracked:
            args += ["--others", "--exclude-standard"]
        out = git(workspace, *args).stdout.decode("utf-8", "surrogateescape")
        return sorted(set(p for p in out.split("\0") if p)), True
    except (OSError, subprocess.CalledProcessError):
        rels: List[str] = []
        for root, dirs, names in os.walk(workspace):
            dirs[:] = [d for d in dirs if d not in IGNORED_DIRS]
            for name in names:
                rels.append((Path(root) / name).relative_to(workspace).as_posix())
        return sorted(rels), False


def load_context(workspace: Path, include_untracked: bool = False) -> Context:
    rels, in_git = list_files(workspace, include_untracked)
    files: Dict[str, SourceFile] = {}
    skipped: List[str] = []
    for rel in rels:
        parts = rel.split("/")
        if set(parts[:-1]) & IGNORED_DIRS or Path(rel).suffix.lower() not in TEXT_EXTENSIONS:
            continue
        path = workspace / rel
        try:
            if path.is_symlink() or not path.is_file():
                continue
            if path.stat().st_size > MAX_FILE_BYTES:
                skipped.append(f"{rel} (exceeds 5MB)")
                continue
            files[rel] = SourceFile(rel, path.read_text(encoding="utf-8"))
        except UnicodeDecodeError:
            skipped.append(f"{rel} (non-UTF8)")
        except OSError as exc:
            skipped.append(f"{rel} ({exc})")
    return Context(workspace, files, skipped, in_git, rels)


def make_finding(
    ctx: Context, category: str, subcategory: str, severity: str, rel: str, line: int, symbol: str,
    summary: str, recommendation: str, scope: str = "line",
) -> Finding:
    abs_path = (ctx.workspace / rel).as_posix() if rel else ctx.workspace.as_posix()
    return {
        "category": category,
        "subcategory": subcategory,
        "severity": severity,
        "scope": scope,
        "file": rel,
        "line": line,
        "file_uri": f"file://{abs_path}#L{max(1, line)}",
        "symbol": symbol,
        "summary": summary,
        "pm_recommendation": recommendation,
    }


def check_monolith(ctx: Context, sf: SourceFile) -> List[Finding]:
    count = len(sf.lines)
    if sf.suffix not in CODE_EXTENSIONS or is_test_path(sf.rel) or count < 2000 or is_generated(sf):
        return []
    severity = "Critical" if count >= 5000 else ("High" if count >= 3000 else "Warning")
    return [make_finding(
        ctx, "architecture", "monolith_append_file", severity, sf.rel, 1, sf.name,
        f"'{sf.name}' has {count} lines (threshold 2,000), a sign of wave-by-wave append bloat.",
        "Split by domain responsibility and move per-view state out of global files.", "file",
    )]


def check_god_object(ctx: Context, sf: SourceFile) -> List[Finding]:
    if sf.suffix != ".swift" or not re.search(r"State|Store|ViewModel", sf.name):
        return []
    var_lines = [i for i, l in enumerate(sf.lines, 1)
                 if re.match(r"^\s*(?:@\w+\s+)*(?:public\s+|internal\s+)?var\s+\w+", l)]
    flags = [i for i, l in enumerate(sf.lines, 1)
             if re.search(r"\bvar\s+show[A-Z]\w*(?:Sheet|Modal|Popover|Inspector)\s*:\s*Bool", l)]
    if len(var_lines) < 200 and len(flags) < 30:
        return []
    severity = "Critical" if (len(var_lines) >= 400 or len(flags) >= 60) else "High"
    return [make_finding(
        ctx, "architecture", "god_object_state_singleton", severity, sf.rel, var_lines[0] if var_lines else 1,
        sf.path.stem, f"'{sf.name}' declares {len(var_lines)} mutable properties and {len(flags)} show*Sheet flags.",
        "Route sheets through one enum (activeSheet) and keep dialog-local state inside each sheet.", "file",
    )]


def check_sheet_chain(ctx: Context, sf: SourceFile) -> List[Finding]:
    if sf.suffix != ".swift":
        return []
    findings: List[Finding] = []
    type_re = re.compile(r"^\s*(?:private\s+|public\s+|internal\s+|fileprivate\s+)?struct\s+(\w+)")
    current, start, count = sf.path.stem, 1, 0

    def flush() -> None:
        if count > 25:
            findings.append(make_finding(
                ctx, "architecture", "excessive_chained_sheet_modifiers", "Critical" if count > 50 else "High",
                sf.rel, start, current, f"'{current}' chains {count} .sheet(...) modifiers in one struct body.",
                "Group sheets into domain ViewModifiers (<= 20 each) or route via one .sheet(item:) enum.", "file",
            ))

    for idx, line in enumerate(sf.lines, 1):
        m = type_re.match(line)
        if m:
            flush()
            current, start, count = m.group(1), idx, 0
        if ".sheet(isPresented:" in line or ".sheet(item:" in line:
            count += 1
    flush()
    return findings


def check_flat_menu(ctx: Context, sf: SourceFile) -> List[Finding]:
    if sf.suffix != ".swift":
        return []
    findings: List[Finding] = []
    counts: Dict[str, Tuple[int, int]] = {}

    def flush(var: str) -> None:
        start, n = counts.pop(var, (0, 0))
        if n > 20:
            findings.append(make_finding(
                ctx, "ui_slop", "flat_context_menu_dumping", "High", sf.rel, start, var,
                f"Menu '{var}' appends {n} items (separators excluded) at one level.",
                "Group related items into submenus (<= 12 items each) mirroring the menu bar.", "file",
            ))

    for idx, line in enumerate(sf.lines, 1):
        declared = re.search(r"\b(?:let|var)\s+(\w+)\s*=\s*NSMenu\(", line)
        if declared:
            flush(declared.group(1))
            counts[declared.group(1)] = (idx, 0)
        m = re.search(r"\b(\w+)\.addItem\(", line)
        if m and ".separator()" not in line:
            start, n = counts.get(m.group(1), (idx, 0))
            counts[m.group(1)] = (start, n + 1)
    for var in list(counts):
        flush(var)
    return findings


def check_self_asserting(ctx: Context, sf: SourceFile) -> List[Finding]:
    if (sf.suffix not in SCRIPT_EXTENSIONS or "scripts" not in sf.rel.split("/")[:-1]
            or not GATE_SCRIPT_NAME.search(sf.name) or is_test_path(sf.rel)):
        return []
    if sf.suffix == ".py":
        reads = PY_READS.search(sf.code)
    else:
        body = "\n".join(re.sub(r"'[^'\n]*'", "''", l) for l in sf.lines if not l.lstrip().startswith("#"))
        reads = SH_READS.search(body)
    if reads:
        return []
    return [make_finding(
        ctx, "qa_theater", "self_asserting_audit_script", "Critical", sf.rel, 1, sf.name,
        f"Gate script '{sf.name}' never reads workspace files or runs a command that does.",
        "Make the gate parse real source files, build output or command results.", "file",
    )]


def check_dead_template(ctx: Context, sf: SourceFile) -> List[Finding]:
    if sf.name != "ContentView.swift" or '"Hello, world!"' not in sf.text:
        return []
    return [make_finding(
        ctx, "qa_theater", "dead_template_project", "High", sf.rel, 1, sf.path.parent.name,
        f"Dead Xcode template 'ContentView.swift' ('Hello, world!') at '{sf.rel}'.",
        "Delete the unused template project and any stale exclude entries in Package.swift.", "file",
    )]


PY_GUARD = re.compile(r"^(?:if|elif|else|except|while|case)\b")


def _py_guarded(code_lines: List[str], line: int) -> bool:
    own = code_lines[line - 1]
    if re.search(r"\bif\b", own):
        return True
    indent = len(own) - len(own.lstrip())
    for k in range(line - 2, -1, -1):
        text = code_lines[k]
        stripped = text.strip()
        if not stripped:
            continue
        level = len(text) - len(text.lstrip())
        if level >= indent:
            continue
        indent = level
        if PY_GUARD.match(stripped):
            return True
        if re.match(r"^(?:async\s+)?(?:def|class)\b", stripped) or level == 0:
            return False
    return False


def _py_literal_segments(sf: SourceFile) -> Iterable[Tuple[int, str]]:
    code_lines = sf.code.split("\n")
    for line, content, _ in sf.strings:
        if _py_guarded(code_lines, line):
            continue
        for k, part in enumerate(content.split("\n")):
            yield line + k, part


def _sh_literal_segments(sf: SourceFile) -> Iterable[Tuple[int, str]]:
    heredoc: Optional[str] = None
    heredoc_guarded = False
    depth = 0
    for idx, line in enumerate(sf.lines, 1):
        if heredoc is not None:
            if line.strip() == heredoc:
                heredoc = None
            elif not heredoc_guarded:
                yield idx, line
            continue
        stripped = line.strip()
        if stripped.startswith("#"):
            continue
        opens = re.match(r"^(?:if|case|while|until)\b", stripped) and not re.search(r"\b(?:fi|esac|done)\b", stripped)
        closes = re.match(r"^(?:fi|esac|done)\b", stripped)
        depth = max(0, depth + (1 if opens else 0) - (1 if closes else 0))
        guarded = depth > 0 or bool(re.search(r"&&|\|\||\bthen\b", line))
        m = re.search(r"<<-?\s*['\"]?(\w+)['\"]?", line)
        if m:
            heredoc, heredoc_guarded = m.group(1), guarded
        if guarded:
            continue
        for seg in re.findall(r"\"(?:[^\"\\]|\\.)*\"|'[^']*'", line):
            yield idx, seg[1:-1]


def check_hardcoded_pass(ctx: Context, sf: SourceFile) -> List[Finding]:
    if (sf.suffix not in SCRIPT_EXTENSIONS or "scripts" not in sf.rel.split("/")[:-1]
            or is_test_path(sf.rel)):
        return []
    segments = _py_literal_segments(sf) if sf.suffix == ".py" else _sh_literal_segments(sf)
    findings: List[Finding] = []
    seen: Set[int] = set()
    for line, text in segments:
        literal = SIMPLE_INTERPOLATION.sub("{}", text)
        if line in seen or not PASS_WORD.search(literal):
            continue
        metric = LITERAL_METRIC.search(literal)
        if not metric:
            continue
        seen.add(line)
        findings.append(make_finding(
            ctx, "qa_theater", "hardcoded_pass_result", "Critical", sf.rel, line, metric.group(),
            f"String literal reports a pass with a hardcoded result '{metric.group()}': {literal.strip()[:100]}",
            "Print only results computed from gates that actually ran; never a fixed PASS table or count.",
        ))
    return findings


def check_emoji(ctx: Context, sf: SourceFile) -> List[Finding]:
    findings: List[Finding] = []
    for idx, line in enumerate(sf.lines, 1):
        m = EMOJI_REGEX.search(line)
        if m:
            findings.append(make_finding(
                ctx, "ui_slop", "prohibited_emoji", "Warning", sf.rel, idx, m.group(),
                f"Emoji or pictographic symbol '{m.group()}' in '{sf.name}'.",
                "Use SF Symbols in UI code and plain text in docs, logs and comments.",
            ))
    return findings


def check_ui_titles(ctx: Context, sf: SourceFile) -> List[Finding]:
    if sf.suffix != ".swift" or is_test_path(sf.rel):
        return []
    findings: List[Finding] = []
    for line, content, prefix in sf.strings:
        if not TITLE_LITERAL_CONTEXT.search(prefix):
            continue
        title = content.split("\n")[0]
        if DECORATIVE_PREFIX.match(title) or MARKETING_PREFIX.match(title):
            findings.append(make_finding(
                ctx, "ui_slop", "cosmetic_bandaid_prefix", "High", sf.rel, line, title,
                f"Title starts with a decorative symbol or a marketing/meta prefix: '{title}'.",
                "Use the command's canonical menu title; express emphasis or grouping with metadata, not text.",
            ))
    return findings


def check_sf_symbols(ctx: Context, sf: SourceFile) -> List[Finding]:
    if sf.suffix != ".swift" or is_test_path(sf.rel):
        return []
    findings: List[Finding] = []
    registry = ctx.symbol_registry()
    check_registry = registry is not None and ctx.is_app_source(sf.rel)
    for line, content, prefix in sf.strings:
        if not SF_SYMBOL_CONTEXT.search(prefix):
            continue
        strict = SF_SYMBOL_STRICT_CONTEXT.search(prefix) or "PaletteCommand(" in prefix
        if strict and SF_SYMBOL_ANY_CASE.match(content) and content != content.lower():
            findings.append(make_finding(
                ctx, "ui_slop", "invalid_uppercase_sf_symbol", "Critical", sf.rel, line, content,
                f"SF Symbol '{content}' contains uppercase characters and will not render.",
                f"Use the lowercase identifier '{content.lower()}'.",
            ))
        elif (check_registry and SF_SYMBOL_NAME.match(content) and content not in registry
              and content not in ctx.asset_names):
            findings.append(make_finding(
                ctx, "design_drift", "unregistered_sf_symbol", "Warning", sf.rel, line, content,
                f"SF Symbol '{content}' is not in the design system's symbol registry.",
                "Reuse a registered symbol for the concept, or register the new concept in the same change.",
            ))
    return findings


def check_internal_codes(ctx: Context, sf: SourceFile) -> List[Finding]:
    if sf.suffix not in (".swift", ".go") or not ctx.is_app_source(sf.rel) or is_generated(sf):
        return []
    context = SWIFT_UI_CONTEXT if sf.suffix == ".swift" else GO_UI_CONTEXT
    findings: List[Finding] = []
    for line, content, prefix in sf.strings:
        if not context.search(prefix):
            continue
        m = INTERNAL_CODE.search(content)
        if m:
            findings.append(make_finding(
                ctx, "ui_slop", "internal_code_in_ui_string", "High", sf.rel, line, m.group(),
                f"User-visible string carries an internal code '{m.group()}': {content.strip()[:100]}",
                "Keep codes in identifiers (finding id, enum case) and show plain-language titles.",
            ))
    return findings


GO_DIRECTIVE = re.compile(r"^//(?:export\s|go:|nolint|line\s|lint:|\s*\+build\s)")
SWIFT_DIRECTIVE = re.compile(r"^//\s*(?:swiftlint:|swift-format-ignore|periphery:|sourcery:)")


def _go_exempt_comment_lines(sf: SourceFile, comment_lines: Set[int]) -> Set[int]:
    exempt: Set[int] = set()
    for idx, line in enumerate(sf.lines, 1):
        if re.match(r'^\s*import\s+"C"\s*$', line):
            k = idx - 1
            while k in comment_lines:
                exempt.add(k)
                k -= 1
    leading: List[int] = []
    for idx, line in enumerate(sf.lines, 1):
        if idx in comment_lines or not line.strip():
            if idx in comment_lines:
                leading.append(idx)
            continue
        break
    if any(re.search(r"copyright|license|spdx", sf.lines[i - 1], re.I) for i in leading):
        exempt.update(leading)
    return exempt


def check_source_comments(ctx: Context, sf: SourceFile) -> List[Finding]:
    if sf.suffix not in (".swift", ".go") or not ctx.is_app_source(sf.rel) or is_generated(sf):
        return []
    comment_lines = {line for line, _ in sf.comments}
    exempt = _go_exempt_comment_lines(sf, comment_lines) if sf.suffix == ".go" else set()
    if sf.suffix == ".swift":
        leading = []
        for idx, line in enumerate(sf.lines, 1):
            if idx in comment_lines or not line.strip():
                leading.append(idx)
                continue
            break
        if any(re.search(r"copyright|license|spdx", sf.lines[i - 1], re.I) for i in leading):
            exempt.update(leading)
    directive = GO_DIRECTIVE if sf.suffix == ".go" else SWIFT_DIRECTIVE
    findings: List[Finding] = []
    for line, text in sf.comments:
        stripped = text.strip()
        if line in exempt or directive.match(stripped) or not stripped.strip("/*").strip():
            continue
        findings.append(make_finding(
            ctx, "project_rules", "source_comment", "Warning", sf.rel, line, stripped[:60],
            f"Source comment in app code: {stripped[:100]}",
            "Project rule: no comments unless asked. Express intent in names and tests, or delete it.",
        ))
    return findings


def check_plan_ids(ctx: Context, sf: SourceFile) -> List[Finding]:
    if (sf.suffix not in CODE_EXTENSIONS | SCRIPT_EXTENSIONS or is_test_path(sf.rel)
            or sf.rel.startswith("scripts/smoke/")):
        return []
    findings: List[Finding] = []
    for idx, line in enumerate(sf.lines, 1):
        m = PLAN_ID.search(line)
        if m:
            findings.append(make_finding(
                ctx, "project_rules", "plan_id_in_code", "Warning", sf.rel, idx, m.group(),
                f"Plan, phase, wave or finding code '{m.group()}' in code: {line.strip()[:100]}",
                "State the invariant or behavior directly; plan and audit labels rot.",
            ))
    return findings


def check_todo_pseudo_fix(ctx: Context, sf: SourceFile) -> List[Finding]:
    if sf.suffix not in (".go", ".swift") or not ctx.is_app_source(sf.rel) or is_generated(sf):
        return []
    findings: List[Finding] = []
    for line, part, _ in string_lines(sf.strings):
        m = TODO_IN_LITERAL.search(part)
        if m:
            findings.append(make_finding(
                ctx, "project_rules", "todo_pseudo_fix", "High", sf.rel, line, m.group().strip(),
                f"String literal writes a TODO into user code: {part.strip()[:100]}",
                "A fix must change behavior; offer no action instead of inserting a TODO comment.",
            ))
    return findings


FILE_CHECKS: Dict[str, List[Callable[[Context, SourceFile], List[Finding]]]] = {
    "check-duplicates": [],
    "check-architecture": [check_monolith, check_god_object, check_sheet_chain],
    "check-ui-slop": [check_flat_menu, check_emoji, check_ui_titles, check_sf_symbols, check_internal_codes],
    "check-qa-theater": [check_self_asserting, check_dead_template, check_hardcoded_pass],
    "check-project-rules": [check_source_comments, check_plan_ids, check_todo_pseudo_fix],
}


def _duplicate_findings(
    ctx: Context, groups: Dict[str, List[Tuple[str, int]]], subcategory: str, severity: str, label: str,
    recommendation: str,
) -> List[Finding]:
    findings: List[Finding] = []
    for title, locs in sorted(groups.items()):
        if len(locs) < 2:
            continue
        where = ", ".join(f"{rel}:{ln}" for rel, ln in locs)
        for rel, ln in locs[1:]:
            findings.append(make_finding(
                ctx, "duplicates", subcategory, severity, rel, ln, title,
                f"{label} '{title}' is registered {len(locs)} times ({where}).", recommendation,
            ))
    return findings


def cross_duplicates(ctx: Context) -> List[Finding]:
    findings: List[Finding] = []
    palette: Dict[str, List[Tuple[str, int]]] = defaultdict(list)
    menu_bar: Dict[str, List[Tuple[str, int]]] = defaultdict(list)
    sheets: Dict[str, List[str]] = defaultdict(list)
    for sf in ctx.by_suffix(".swift", ".ts", ".tsx"):
        if is_test_path(sf.rel):
            continue
        for idx, line in enumerate(sf.lines, 1):
            m = re.search(r'PaletteCommand\s*\(\s*title:\s*"([^"]+)"', line)
            if m:
                palette[m.group(1)].append((sf.rel, idx))
        if "CommandMenu(" in sf.text or "CommandGroup(" in sf.text:
            for idx, line in enumerate(sf.lines, 1):
                for m in re.finditer(r'\b(?:Button|Toggle)\(\s*"([^"\\]+)"', line):
                    menu_bar[m.group(1)].append((sf.rel, idx))
        if sf.name.endswith("SheetView.swift") or sf.name.endswith("Modal.tsx"):
            norm = re.sub(r"(Methods|Helper|Loader|Go|SheetView|Modal)$", "", sf.path.stem).replace("Go", "")
            sheets[norm].append(sf.rel)
    findings += _duplicate_findings(
        ctx, palette, "duplicate_command_palette_entry", "High", "Command Palette title",
        "Keep one canonical command; sort featured commands by metadata instead of duplicating them.")
    findings += _duplicate_findings(
        ctx, menu_bar, "duplicate_menu_bar_title", "Warning", "Menu bar item",
        "A command lives in one menu bar menu; drop the copy or give it a distinct, accurate title.")
    for norm, rels in sorted(sheets.items()):
        if len(rels) > 1 and len(norm) >= 8:
            names = ", ".join(Path(r).stem for r in rels)
            findings.append(make_finding(
                ctx, "duplicates", "overlapping_modal_sheets", "High", rels[0], 1, names,
                f"Modal sheet views share the domain stem '{norm}': {names}.",
                "Check whether two waves built the same sheet twice; merge into one.", "file",
            ))
    return findings + cross_ffi(ctx)


def cross_ffi(ctx: Context) -> List[Finding]:
    exports: Dict[str, Tuple[str, int]] = {}
    for sf in ctx.by_suffix(".go"):
        if is_test_path(sf.rel):
            continue
        for idx, line in enumerate(sf.lines, 1):
            m = re.match(r"^//export\s+([A-Za-z0-9_]+)\s*$", line)
            if m:
                exports[m.group(1)] = (sf.rel, idx)
    if not exports:
        return []
    decl_re = re.compile(r"^(?:extern\s+)?[A-Za-z0-9_\s\*]+?\b([A-Za-z0-9_]+)\s*\([^;]*\)\s*;")
    headers: Dict[str, Tuple[str, int]] = {}
    for sf in ctx.by_suffix(".h"):
        if is_generated(sf) or "cmd/cgo" in sf.text[:200]:
            continue
        decls: Dict[str, Tuple[str, int]] = {}
        for idx, line in enumerate(sf.lines, 1):
            s = line.strip()
            if s.startswith(("//", "#", "/*", "*", "typedef")):
                continue
            m = decl_re.match(s)
            if m:
                decls.setdefault(m.group(1), (sf.rel, idx))
        if set(decls) & set(exports):
            for name, loc in decls.items():
                headers.setdefault(name, loc)
    findings: List[Finding] = []
    for name, (rel, ln) in sorted(headers.items()):
        if name not in exports:
            findings.append(make_finding(
                ctx, "duplicates", "orphan_ffi_header_declaration", "High", rel, ln, name,
                f"Bridging header declares '{name}' with no matching Go //export.",
                "Remove the dead declaration or restore the export.",
            ))
    swift_words: Set[str] = set()
    for sf in ctx.by_suffix(".swift", ".m", ".mm", ".c"):
        if not is_test_path(sf.rel) and "scripts" not in sf.rel.split("/"):
            swift_words.update(re.findall(r"[A-Za-z_][A-Za-z0-9_]*", sf.code))
    for name, (rel, ln) in sorted(exports.items()):
        if headers and name not in headers:
            findings.append(make_finding(
                ctx, "duplicates", "ffi_export_missing_header", "High", rel, ln, name,
                f"Go //export '{name}' has no declaration in the bridging header.",
                "Declare it in the bridging header or drop the export.",
            ))
        if swift_words and name not in swift_words:
            findings.append(make_finding(
                ctx, "duplicates", "ffi_export_unused_in_swift", "Warning", rel, ln, name,
                f"Go //export '{name}' is never referenced from app Swift or C code.",
                "Delete the dead export, or allow-list it while its UI lands on another branch.",
            ))
    names = set(exports) | set(headers)
    for name in sorted(names):
        for prefix in ("Inspect", "Generate", "Apply", "Preview", "List"):
            if name.startswith(prefix) and not name.startswith(prefix + "Go"):
                twin = prefix + "Go" + name[len(prefix):]
                if twin in names:
                    rel, ln = exports.get(name) or headers[name]
                    findings.append(make_finding(
                        ctx, "duplicates", "duplicate_ffi_export_pair", "Critical", rel, ln, f"{name} / {twin}",
                        f"Both '{name}' and '{twin}' cross the FFI boundary (naming split across waves).",
                        f"Keep one canonical symbol and delete '{name}' or '{twin}'.",
                    ))
    return findings


def cross_architecture(ctx: Context) -> List[Finding]:
    inspectors = sum(1 for rel in ctx.files if rel.endswith("InspectorSheetView.swift"))
    generators = sum(1 for rel in ctx.files
                     if Path(rel).name.startswith("Generate") and rel.endswith("SheetView.swift"))
    if inspectors <= 15:
        return []
    return [make_finding(
        ctx, "architecture", "modal_inspector_proliferation", "High", "", 1, "InspectorSheetViews",
        f"{inspectors} modal Inspector sheet views and {generators} Generator sheet views.",
        "Surface findings inline via background diagnostics and Quick Fixes instead of one sheet per rule.",
        "workspace",
    )]


def cross_qa(ctx: Context) -> List[Finding]:
    teamwork = ctx.workspace / ".agents" / "teamwork"
    if not teamwork.is_dir():
        return []
    subdirs = [p for p in teamwork.iterdir() if p.is_dir()]
    if len(subdirs) <= 20:
        return []
    return [make_finding(
        ctx, "qa_theater", "uncleaned_agent_scratch_dirs", "Warning", ".agents/teamwork", 1, ".agents/teamwork",
        f"'.agents/teamwork' holds {len(subdirs)} leftover agent scratch directories.",
        "Clean up stale scratch directories or ignore them in git.", "workspace",
    )]


CROSS_CHECKS: Dict[str, List[Callable[[Context], List[Finding]]]] = {
    "check-duplicates": [cross_duplicates],
    "check-architecture": [cross_architecture],
    "check-ui-slop": [],
    "check-qa-theater": [cross_qa],
    "check-project-rules": [],
}
SUBCOMMANDS = {
    "scan-all": "Run every check.",
    "check-duplicates": "Duplicate palette and menu bar titles, FFI parity and Swift use, overlapping sheets.",
    "check-architecture": "Monolith files, God-Object state, chained sheet modifiers, inspector proliferation.",
    "check-ui-slop": "Band-aid title prefixes, SF Symbols, flat menus, emoji, internal codes in UI strings.",
    "check-qa-theater": "Self-asserting gate scripts, hardcoded PASS results, dead templates, scratch dirs.",
    "check-project-rules": "Source comments, plan and finding IDs in code, TODO pseudo-fixes.",
}
GROUPS = [name for name in SUBCOMMANDS if name != "scan-all"]
SUBCATEGORIES = (
    "duplicate_command_palette_entry", "duplicate_menu_bar_title", "overlapping_modal_sheets",
    "orphan_ffi_header_declaration", "ffi_export_missing_header", "ffi_export_unused_in_swift",
    "duplicate_ffi_export_pair", "monolith_append_file", "god_object_state_singleton",
    "excessive_chained_sheet_modifiers", "modal_inspector_proliferation", "flat_context_menu_dumping",
    "prohibited_emoji", "cosmetic_bandaid_prefix", "invalid_uppercase_sf_symbol", "unregistered_sf_symbol",
    "internal_code_in_ui_string", "self_asserting_audit_script", "dead_template_project", "hardcoded_pass_result",
    "uncleaned_agent_scratch_dirs", "source_comment", "plan_id_in_code", "todo_pseudo_fix",
)


def selected_groups(subcommand: str) -> List[str]:
    return GROUPS if subcommand == "scan-all" else [subcommand]


def run_file_checks(ctx: Context, sf: SourceFile, groups: List[str]) -> List[Finding]:
    findings: List[Finding] = []
    for group in groups:
        for check in FILE_CHECKS[group]:
            findings.extend(check(ctx, sf))
    return findings


def scan(ctx: Context, groups: List[str]) -> List[Finding]:
    findings: List[Finding] = []
    for sf in ctx.files.values():
        findings.extend(run_file_checks(ctx, sf, groups))
    for group in groups:
        for check in CROSS_CHECKS[group]:
            findings.extend(check(ctx))
    findings.sort(key=lambda f: (SEVERITY_RANK[f["severity"]], f["subcategory"], f["file"], f["line"], f["symbol"]))
    return findings


def load_allow(path: Path) -> List[Tuple[str, Optional[str]]]:
    if not path.is_file():
        return []
    entries: List[Tuple[str, Optional[str]]] = []
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        glob, sep, sub = line.rpartition(":")
        if sep and re.fullmatch(r"[a-z_]+", sub):
            entries.append((glob, sub))
        else:
            entries.append((line, None))
    return entries


def is_allowed(finding: Finding, allow: List[Tuple[str, Optional[str]]]) -> bool:
    return any(
        fnmatch.fnmatchcase(finding["file"], glob) and (sub is None or sub == finding["subcategory"])
        for glob, sub in allow
    )


def all_subcategories() -> List[str]:
    return sorted(SUBCATEGORIES)


def score(findings: List[Finding]) -> int:
    groups = Counter((f["subcategory"], f["severity"]) for f in findings)
    penalty = sum(SEVERITY_WEIGHT[sev] * (1 + math.log2(n)) for (_, sev), n in groups.items())
    return max(0, round(100 - penalty))


def counts_by_subcategory(findings: List[Finding]) -> Dict[str, int]:
    counts = Counter(f["subcategory"] for f in findings)
    return {key: counts.get(key, 0) for key in all_subcategories()}


def capped(findings: List[Finding], limit: int) -> Tuple[List[Finding], Dict[str, int]]:
    shown: List[Finding] = []
    seen: Counter = Counter()
    omitted: Counter = Counter()
    for f in findings:
        if seen[f["subcategory"]] < limit:
            shown.append(f)
            seen[f["subcategory"]] += 1
        else:
            omitted[f["subcategory"]] += 1
    return shown, dict(omitted)


def build_report(ctx: Context, mode: str, limit: int, findings: List[Finding], allowed: int) -> Dict[str, Any]:
    shown, omitted = capped(findings, limit)
    severity = Counter(f["severity"] for f in findings)
    return {
        "scanner": "ai-slop-auditor",
        "subcommand": mode,
        "workspace": ctx.workspace.as_posix(),
        "file_source": "git ls-files" if ctx.in_git else "os.walk",
        "files_scanned": len(ctx.files),
        "limit_per_subcategory": limit,
        "product_coherence_score": score(findings),
        "summary": {
            "total_findings": len(findings),
            "allowed_findings": allowed,
            "by_severity": {key: severity.get(key, 0) for key in SEVERITY_RANK},
            "by_category": dict(Counter(f["category"] for f in findings)),
            "by_subcategory": {k: v for k, v in counts_by_subcategory(findings).items() if v},
            "omitted_by_subcategory": omitted,
            "skipped_files_count": len(ctx.skipped),
        },
        "findings": shown,
        "skipped_files": ctx.skipped[:50],
    }


def print_report(report: Dict[str, Any], list_findings: bool) -> None:
    summary = report["summary"]
    sev = summary["by_severity"]
    print(f"[{report['subcommand']}] Product Coherence Score: {report['product_coherence_score']}/100 "
          f"(Critical {sev['Critical']}, High {sev['High']}, Warning {sev['Warning']}; "
          f"{summary['allowed_findings']} allowed; {report['files_scanned']} files via {report['file_source']})")
    for key, value in sorted(summary["by_subcategory"].items()):
        print(f"  {key:<36} {value:>6}")
    if not list_findings:
        return
    for f in report["findings"]:
        where = f"{f['file']}:{f['line']}" if f["file"] else "(workspace)"
        print(f"{f['severity']:<8} {f['subcategory']}  {where}  {f['summary']}")
    for key, n in sorted(summary["omitted_by_subcategory"].items()):
        print(f"  ... {n} more {key} finding(s) omitted (raise --limit to list them)")


def added_lines(ctx: Context, ref: str) -> Tuple[Dict[str, Set[int]], Set[str]]:
    out = git(ctx.workspace, "diff", "-U0", "--no-color", "--no-ext-diff", "--relative", ref, "--").stdout
    added: Dict[str, Set[int]] = defaultdict(set)
    current: Optional[str] = None
    for line in out.decode("utf-8", "surrogateescape").splitlines():
        if line.startswith("+++ "):
            current = line[6:] if line.startswith("+++ b/") else None
        elif line.startswith("@@") and current:
            m = re.match(r"@@ -\S+ \+(\d+)(?:,(\d+))? @@", line)
            if m:
                start, length = int(m.group(1)), int(m.group(2) or "1")
                added[current].update(range(start, start + length))
    untracked = git(ctx.workspace, "ls-files", "-z", "--others", "--exclude-standard").stdout
    new_files = {p for p in untracked.decode("utf-8", "surrogateescape").split("\0") if p}
    for rel in new_files:
        sf = ctx.files.get(rel)
        if sf is not None:
            added[rel].update(range(1, len(sf.lines) + 1))
    return added, new_files


def ref_findings(ctx: Context, ref: str, rel: str, groups: List[str]) -> Optional[Set[Tuple[str, str, str]]]:
    shown = git(ctx.workspace, "show", f"{ref}:./{rel}", check=False)
    if shown.returncode != 0:
        return None
    try:
        sf = SourceFile(rel, shown.stdout.decode("utf-8"))
    except UnicodeDecodeError:
        return None
    return {(f["subcategory"], f["symbol"], f["severity"]) for f in run_file_checks(ctx, sf, groups)
            if f["scope"] == "file"}


def diff_findings(ctx: Context, ref: str, findings: List[Finding], groups: List[str]) -> List[Finding]:
    added, new_files = added_lines(ctx, ref)
    cache: Dict[str, Optional[Set[Tuple[str, str, str]]]] = {}
    introduced: List[Finding] = []
    for f in findings:
        rel = f["file"]
        if f["scope"] == "line":
            if f["line"] in added.get(rel, ()):
                introduced.append(f)
        elif f["scope"] == "file" and rel in added:
            if rel not in cache:
                cache[rel] = None if rel in new_files else ref_findings(ctx, ref, rel, groups)
            before = cache[rel]
            if before is None or (f["subcategory"], f["symbol"], f["severity"]) not in before:
                introduced.append(f)
    return introduced


def read_baseline(path: Path) -> Optional[Dict[str, int]]:
    if not path.is_file():
        return None
    return {k: int(v) for k, v in json.loads(path.read_text(encoding="utf-8")).items()}


def ratchet(current: Dict[str, int], baseline: Dict[str, int]) -> Tuple[List[str], List[str]]:
    regressed = [k for k, v in current.items() if v > baseline.get(k, 0)]
    improved = [k for k, v in baseline.items() if current.get(k, 0) < v]
    return sorted(regressed), sorted(improved)


def run_gate(args: argparse.Namespace, ctx: Context, findings: List[Finding], baseline_path: Path) -> int:
    current = counts_by_subcategory(findings)
    baseline = read_baseline(baseline_path)
    if args.update:
        if baseline is not None:
            regressed, _ = ratchet(current, baseline)
            if regressed:
                print(f"refusing to update {baseline_path}: regressed {', '.join(regressed)}")
                return 1
        baseline_path.parent.mkdir(parents=True, exist_ok=True)
        baseline_path.write_text(json.dumps(current, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        print(f"baseline written: {baseline_path}")
        return 0
    if baseline is None:
        print(f"no baseline at {baseline_path}: run with --update first")
        return 1
    regressed, improved = ratchet(current, baseline)
    for key in sorted(set(current) | set(baseline)):
        value, base = current.get(key, 0), baseline.get(key, 0)
        mark = "REGRESSED" if key in regressed else ("improved" if key in improved else "")
        if value or base:
            print(f"{key:<36} {value:>6}  baseline {base:>6}  {mark}")
    if improved:
        print("counts went down: run --update and commit the baseline to lock the gain")
    print(f"{len(regressed)} subcategory count(s) regressed")
    return 1 if regressed else 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="slop_scanner.py", description="AI slop scanner with a ratchet gate.")
    parser.add_argument("subcommand", nargs="?", default="scan-all", choices=list(SUBCOMMANDS),
                        help="; ".join(f"{k}: {v}" for k, v in SUBCOMMANDS.items()))
    parser.add_argument("--workspace", default=None, help="Project root (default: git top level of the cwd).")
    parser.add_argument("--limit", type=int, default=DEFAULT_LIMIT,
                        help=f"Findings listed per subcategory (default {DEFAULT_LIMIT}); counts and score use all.")
    parser.add_argument("--output", help="Write the JSON report here.")
    parser.add_argument("--list", action="store_true", help="List findings on stdout (default when no --output).")
    parser.add_argument("--allow", default=None, help=f"Allow file (default: <workspace>/{DEFAULT_ALLOW}).")
    parser.add_argument("--baseline", default=None, help=f"Baseline file (default: <workspace>/{DEFAULT_BASELINE}).")
    gate = parser.add_mutually_exclusive_group()
    gate.add_argument("--check", action="store_true", help="Exit 1 if any subcategory count rose above the baseline.")
    gate.add_argument("--diff", nargs="?", const="HEAD", metavar="REF",
                      help="Exit 1 if lines added since REF (default HEAD, plus untracked files) add a finding.")
    gate.add_argument("--update", action="store_true", help="Rewrite the baseline when nothing regressed.")
    return parser


def resolve_workspace(value: Optional[str]) -> Path:
    if value:
        return Path(value).resolve()
    try:
        top = subprocess.run(["git", "rev-parse", "--show-toplevel"], capture_output=True, check=True, text=True)
        return Path(top.stdout.strip()).resolve()
    except (OSError, subprocess.CalledProcessError):
        return Path.cwd().resolve()


def main(argv: Optional[List[str]] = None) -> int:
    args = build_parser().parse_args(argv)
    workspace = resolve_workspace(args.workspace)
    if not workspace.is_dir():
        print(f"error: workspace is not a directory: {workspace}", file=sys.stderr)
        return 2
    if args.limit <= 0:
        print(f"error: --limit must be positive (got {args.limit})", file=sys.stderr)
        return 2
    if (args.check or args.update or args.diff) and args.subcommand != "scan-all":
        print("error: --check, --diff and --update run on scan-all only", file=sys.stderr)
        return 2
    started = time.monotonic()
    ctx = load_context(workspace, include_untracked=bool(args.diff))
    groups = selected_groups(args.subcommand)
    allow = load_allow(Path(args.allow) if args.allow else workspace / DEFAULT_ALLOW)
    raw = scan(ctx, groups)
    findings = [f for f in raw if not is_allowed(f, allow)]
    allowed = len(raw) - len(findings)
    if args.diff:
        if not ctx.in_git:
            print("error: --diff needs a git repository", file=sys.stderr)
            return 2
        introduced = diff_findings(ctx, args.diff, findings, groups)
        shown, omitted = capped(introduced, args.limit)
        for f in shown:
            print(f"{f['severity']:<8} {f['subcategory']}  {f['file']}:{f['line']}  {f['summary']}")
        for key, n in sorted(omitted.items()):
            print(f"  ... {n} more {key} finding(s) omitted")
        print(f"{len(introduced)} slop finding(s) in lines added since {args.diff}")
        return 1 if introduced else 0
    report = build_report(ctx, args.subcommand, args.limit, findings, allowed)
    report["elapsed_seconds"] = round(time.monotonic() - started, 2)
    if args.output:
        out = Path(args.output)
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    if args.check or args.update:
        print(f"Product Coherence Score: {report['product_coherence_score']}/100")
        return run_gate(args, ctx, findings, Path(args.baseline) if args.baseline else workspace / DEFAULT_BASELINE)
    print_report(report, args.list or not args.output)
    if args.output:
        print(f"report written: {Path(args.output).resolve().as_posix()}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
