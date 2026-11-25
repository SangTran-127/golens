import contextlib
import io
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import slop_scanner as scanner

QA_FIX_RUNNER_BEFORE_FIX = r'''
def build_handoff_packet(commit_text, root_cause, fix_details, evidence_notes=None):
    packet = f"""
### 4. Kết quả kiểm thử Developer & Bằng chứng (Developer Test Results & Evidence)
| Cổng Kiểm Thử (Gate) | Lệnh Thực Thi | Kết Quả | Ghi Chú |
| :--- | :--- | :--- | :--- |
| Gate 1: Make Build | `make build` | PASS | Go cgo dylib + Swift release app bundle |
| Gate 2: Go Unit Tests | `cd core && go test ./...` | PASS | 100% Go packages pass |
| Gate 3: Dogfood Journey | `bash scripts/smoke/dogfood-journey.sh` | PASS | Continuous user journey suite |
| Gate 4: Track B Smoke | `bash scripts/smoke/track-b.sh` | PASS | 16/16 Track B scenarios pass |
| Gate 5: Core Smoke Suite | `bash scripts/smoke/run.sh` | PASS | 24/24 core smoke checks pass |
| Gate 6: Apple HIG Lint | `python3 .../hig-lint.py desktop` | PASS | 0 error(s), tuân thủ Apple HIG |
| Gate 7: Gate 5 WCAG Audit | `python3 scripts/smoke/gate5-audit.py` | PASS | 0 contrast/asset violations |

- **Bằng chứng kiểm thử & Ghi chú bổ sung**:
{evidence_notes or "- Toàn bộ 7 cổng developer gates đã được thực thi và đạt 100% PASS.\n- Mã nguồn tuân thủ."}
"""
    return packet
'''

DESIGN_SYSTEM = """# Design System
### 2.5 Iconography
| Concept | Symbol |
|---|---|
| Copy | `doc.on.doc` |
| Delete | `trash` |
### 2.6 Shapes
`not.registered.here`
"""


class Workspace:
    def __init__(self, files, git=False):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name).resolve()
        self.write(files)
        if git:
            self.git("init", "-q")
            self.commit()

    def write(self, files):
        for rel, text in files.items():
            path = self.root / rel
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text, encoding="utf-8")

    def git(self, *args):
        return subprocess.run(
            ["git", "-c", "user.name=t", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false", *args],
            cwd=self.root, capture_output=True, check=True, text=True,
        ).stdout

    def commit(self):
        self.git("add", "-A")
        self.git("commit", "-q", "--allow-empty", "-m", "fixture")

    def scan(self, *groups):
        ctx = scanner.load_context(self.root)
        return scanner.scan(ctx, list(groups) or scanner.GROUPS)

    def run(self, *args):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = scanner.main(["--workspace", str(self.root), *args])
        return code, out.getvalue()

    def close(self):
        self._tmp.cleanup()


def of(findings, subcategory):
    return [f for f in findings if f["subcategory"] == subcategory]


class ScannerTestCase(unittest.TestCase):
    def output(self, name):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        return Path(tmp.name) / name

    def workspace(self, files, git=False):
        ws = Workspace(files, git)
        self.addCleanup(ws.close)
        return ws


class LimitAndScoreTests(ScannerTestCase):
    def test_limit_caps_listing_but_not_score_or_counts(self):
        ws = self.workspace({"docs/notes.md": "".join(f"line {i} \u2705\n" for i in range(30))})
        reports = {}
        for limit in ("1", "100"):
            out = self.output(f"report-{limit}.json")
            code, _ = ws.run("check-ui-slop", "--limit", limit, "--output", str(out))
            self.assertEqual(code, 0)
            reports[limit] = json.loads(out.read_text(encoding="utf-8"))
        small, large = reports["1"], reports["100"]
        self.assertEqual(small["product_coherence_score"], large["product_coherence_score"])
        self.assertEqual(small["summary"]["total_findings"], 30)
        self.assertEqual(len(small["findings"]), 1)
        self.assertEqual(small["summary"]["omitted_by_subcategory"], {"prohibited_emoji": 29})
        self.assertEqual(len(large["findings"]), 30)

    def test_limit_is_optional(self):
        ws = self.workspace({"a.md": "plain\n"})
        code, out = ws.run()
        self.assertEqual(code, 0)
        self.assertIn("Product Coherence Score: 100/100", out)

    def test_score_formula(self):
        findings = [{"subcategory": "a", "severity": "Warning"}] * 4 + [{"subcategory": "b", "severity": "Critical"}]
        self.assertEqual(scanner.score(findings), round(100 - (1 * 3) - (8 * 1)))


class EmojiTests(ScannerTestCase):
    def test_detects_pictographs_and_keeps_arrows_box_drawing_and_punctuation(self):
        ws = self.workspace({
            "STATE.md": "\u2705 done\n\u2726 Featured\n\u26a0\ufe0f careful\n\U0001F1FB\U0001F1F3 flag\n\u2b50 star\n",
            "desktop/IssueAnnotations.swift": "let x = 1 // \u2715 close\n",
            "docs/ok.md": "a \u2192 b \u2500\u2502 \u201cquoted\u201d \u2014 dash \u2026 \u2318K\n",
        })
        findings = of(ws.scan("check-ui-slop"), "prohibited_emoji")
        self.assertEqual(sorted((f["file"], f["line"]) for f in findings), [
            ("STATE.md", 1), ("STATE.md", 2), ("STATE.md", 3), ("STATE.md", 4), ("STATE.md", 5),
            ("desktop/IssueAnnotations.swift", 1),
        ])

    def test_allow_file_suppresses_by_glob_and_subcategory(self):
        ws = self.workspace({
            "core/database/testdata/wide.json": "{\"text\": \"\u2713 wide\"}\n",
            "core/database/fixtures_test.go": "package database\n\nvar wide = \"\u2713\"\n",
            "docs/a.md": "\u2705\n",
            "allow.txt": "core/database/testdata/*:prohibited_emoji\ncore/database/fixtures_test.go\n",
        })
        out = self.output("r.json")
        ws.run("check-ui-slop", "--allow", str(ws.root / "allow.txt"), "--output", str(out))
        report = json.loads(out.read_text(encoding="utf-8"))
        self.assertEqual(report["summary"]["total_findings"], 1)
        self.assertEqual(report["summary"]["allowed_findings"], 2)


class QATheaterTests(ScannerTestCase):
    def test_qa_fix_runner_fixed_pass_table_regression(self):
        ws = self.workspace({"scripts/qa/qa_fix_runner.py": QA_FIX_RUNNER_BEFORE_FIX})
        findings = of(ws.scan("check-qa-theater"), "hardcoded_pass_result")
        symbols = {f["symbol"] for f in findings}
        self.assertTrue({"16/16", "24/24"} <= symbols, symbols)
        self.assertGreaterEqual(len(findings), 5)
        self.assertTrue(all(f["severity"] == "Critical" for f in findings))

    def test_computed_or_guarded_results_are_not_flagged(self):
        ws = self.workspace({
            "scripts/gate-report.py": (
                "import subprocess\n"
                "def report(passed, total, ok):\n"
                "    print(f\"{passed}/{total} checks passed\")\n"
                "    if ok:\n"
                "        print(\"ALL GATES PASSED 100%\")\n"
                "    print(\"threshold: pass>=90%\")\n"
                "    print('OK' if ok else '1/2 failed')\n"
            ),
            "scripts/gate.sh": (
                "#!/bin/sh\n"
                "n=$(grep -c x file)\n"
                "echo \"PASS $n/$n\"\n"
                "if [ \"$n\" -gt 0 ]; then\n"
                "  echo \"PASS 3/3\"\n"
                "fi\n"
            ),
        })
        self.assertEqual(of(ws.scan("check-qa-theater"), "hardcoded_pass_result"), [])

    def test_shell_fixed_pass_is_flagged(self):
        ws = self.workspace({"scripts/smoke/report.sh": "#!/bin/sh\necho \"Track B: PASS (16/16 scenarios)\"\n"})
        findings = of(ws.scan("check-qa-theater"), "hardcoded_pass_result")
        self.assertEqual([(f["line"], f["symbol"]) for f in findings], [(2, "16/16")])

    def test_self_asserting_requires_real_calls(self):
        ws = self.workspace({
            "scripts/theater-audit.py": "THEME = (1, 2, 3)\nprint('open(' + 'Path(')\nprint('PASS')\n",
            "scripts/real-audit.py": "from pathlib import Path\nfor p in Path('.').rglob('*.swift'):\n    p.read_text()\n",
            "scripts/theater-check.sh": "#!/bin/sh\n# grep the sources\necho 'grep -r x' \necho ok\n",
            "scripts/real-check.sh": "#!/bin/sh\nset -eu\ncount=$(grep -c foo desktop/a.swift)\necho \"$count\"\n",
            "scripts/redirect-gate.sh": "#!/bin/sh\nwhile read -r l; do echo \"$l\"; done < desktop/list.txt\n",
        })
        flagged = sorted(f["file"] for f in of(ws.scan("check-qa-theater"), "self_asserting_audit_script"))
        self.assertEqual(flagged, ["scripts/theater-audit.py", "scripts/theater-check.sh"])

    def test_dead_template(self):
        ws = self.workspace({"Old/ContentView.swift": "Text(\"Hello, world!\")\n"})
        self.assertEqual(len(of(ws.scan("check-qa-theater"), "dead_template_project")), 1)


class DuplicateTests(ScannerTestCase):
    def test_palette_and_menu_bar_duplicates(self):
        ws = self.workspace({
            "desktop/Palette.swift": (
                'PaletteCommand(title: "Format Document", icon: "doc.on.doc")\n'
                'PaletteCommand(title: "Format Document", icon: "doc.on.doc")\n'
            ),
            "desktop/App.swift": (
                'CommandMenu("View") {\n Button("Show Services") {}\n Button("Copy") {}\n}\n'
                'CommandMenu("Tools") {\n Button("Show Services") {}\n}\n'
            ),
            "desktop/ContextMenu.swift": 'Button("Copy") {}\nButton("Copy") {}\n',
        })
        findings = ws.scan("check-duplicates")
        self.assertEqual([(f["file"], f["line"]) for f in of(findings, "duplicate_command_palette_entry")],
                         [("desktop/Palette.swift", 2)])
        self.assertEqual([(f["symbol"], f["line"]) for f in of(findings, "duplicate_menu_bar_title")],
                         [("Show Services", 6)])

    def test_ffi_parity_and_swift_use(self):
        ws = self.workspace({
            "core/exports.go": (
                "package main\n\n//export UsedThing\nfunc UsedThing() {}\n\n//export UnusedThing\nfunc UnusedThing() {}\n"
                "\n//export Undeclared\nfunc Undeclared() {}\n"
            ),
            "include/Bridge.h": "void UsedThing(void);\nvoid UnusedThing(void);\nvoid Ghost(void);\n",
            "include/libgo.h": "/* Code generated by cmd/cgo; DO NOT EDIT. */\nextern void Undeclared(void);\n",
            "desktop/Use.swift": "UsedThing()\nlet s = \"Undeclared\"\n",
        })
        findings = ws.scan("check-duplicates")
        self.assertEqual([f["symbol"] for f in of(findings, "orphan_ffi_header_declaration")], ["Ghost"])
        self.assertEqual([f["symbol"] for f in of(findings, "ffi_export_missing_header")], ["Undeclared"])
        self.assertEqual(sorted(f["symbol"] for f in of(findings, "ffi_export_unused_in_swift")),
                         ["Undeclared", "UnusedThing"])
        self.assertTrue(all(f["severity"] == "Warning" for f in of(findings, "ffi_export_unused_in_swift")))


class UITests(ScannerTestCase):
    def test_internal_codes_in_ui_strings(self):
        ws = self.workspace({
            "desktop/Commands.swift": (
                'let f = Finding(\n'
                '    id: "DEP_VULN_\\(osvID)",\n'
                '    title: "[DEP_VULN] \\(osvID)\\(aliasTag): \\(summary)",\n'
                ')\n'
                'if finding.id.hasPrefix("CAPABILITY_NETWORK:") {}\n'
                'Text("Value [REDACTED]")\n'
                'Text("SAFETY_CODE: something")\n'
            ),
            "core/safety/safety.go": (
                'package safety\n\nfunc f() {\n'
                '\tx := Finding{\n'
                '\t\ttitle:   fmt.Sprintf("Capability [UNSAFE]: unsafe import in %s", pkgName),\n'
                '\t\tid:      "CAPABILITY_UNSAFE:" + pkgName,\n'
                '\t}\n'
                '\tbridge.Debug("[LSP] dropped")\n'
                '}\n'
            ),
            "core/safety/safety_test.go": 'package safety\n\nvar t = Finding{title: "[UNSAFE] x"}\n',
        })
        findings = of(ws.scan("check-ui-slop"), "internal_code_in_ui_string")
        self.assertEqual(sorted((f["file"], f["line"]) for f in findings), [
            ("core/safety/safety.go", 5), ("desktop/Commands.swift", 3), ("desktop/Commands.swift", 7),
        ])

    def test_bandaid_prefixes(self):
        ws = self.workspace({"desktop/Palette.swift": (
            'PaletteCommand(title: "Contextual: Show Code Actions", icon: "trash")\n'
            'PaletteCommand(title: "\u2726 Featured Search", icon: "trash")\n'
            'PaletteCommand(title: "Code Lenses: Off", icon: "trash")\n'
            'Text("\u2022")\n'
            'Button("New: Project") {}\n'
        )})
        findings = of(ws.scan("check-ui-slop"), "cosmetic_bandaid_prefix")
        self.assertEqual([f["line"] for f in findings], [1, 2, 5])

    def test_sf_symbols_case_and_registry(self):
        ws = self.workspace({
            "DESIGN_SYSTEM.md": DESIGN_SYSTEM,
            "desktop/Resources/ProviderIcons/provider-openai.pdf": "%PDF",
            "desktop/View.swift": (
                'Image(systemName: "ShippingBox")\n'
                'Label("Copy", systemImage: "doc.on.doc")\n'
                'Button("x", systemImage: "not.registered.here") {}\n'
                'Row(icon: "openai")\n'
                'Row(icon: "bolt.fill")\n'
            ),
        })
        findings = ws.scan("check-ui-slop")
        self.assertEqual([f["symbol"] for f in of(findings, "invalid_uppercase_sf_symbol")], ["ShippingBox"])
        self.assertEqual([f["symbol"] for f in of(findings, "unregistered_sf_symbol")],
                         ["not.registered.here", "bolt.fill"])

    def test_flat_menu_counts_items_per_menu_without_separators(self):
        items = "menu.addItem(item)\nmenu.addItem(.separator())\n"
        ws = self.workspace({"desktop/Menus.swift": (
            "let menu = NSMenu()\n" + items * 10 + "let menu = NSMenu()\n" + items * 21
        )})
        findings = of(ws.scan("check-ui-slop"), "flat_context_menu_dumping")
        self.assertEqual(len(findings), 1)
        self.assertIn("21 items", findings[0]["summary"])


class ProjectRuleTests(ScannerTestCase):
    def test_go_comments_skip_directives_cgo_and_license(self):
        ws = self.workspace({
            "core/main.go": (
                "// Copyright 2026 Example. Licensed under MIT.\n\n"
                "//go:build darwin\n\npackage main\n\n"
                "/*\n#include <stdlib.h>\n*/\nimport \"C\"\n\n"
                "//export Run\nfunc Run() {\n"
                "\tu := \"http://example.com\"\n"
                "\tr := '/'\n"
                "\tb := `// not a comment`\n"
                "\t// a real comment\n"
                "\t_ = u //nolint:errcheck\n"
                "}\n"
            ),
            "core/main_test.go": "package main\n\n// test comment\n",
        })
        findings = of(ws.scan("check-project-rules"), "source_comment")
        self.assertEqual([(f["file"], f["line"]) for f in findings], [("core/main.go", 17)])

    def test_swift_comments_and_lexer_edge_cases(self):
        ws = self.workspace({
            "desktop/View.swift": (
                "/// Doc comment\n"
                "// MARK: - Section\n"
                "let a = \"http://x\"\n"
                "let b = \"\\(flag ? \"x//y\" : \"z\")\" // trailing\n"
                "let c = #\"raw // text\"#\n"
                "let d = \"\"\"\n  // inside multi-line\n  \"\"\"\n"
                "/* block\n   still block */\n"
                "//\n"
            ),
            "desktop/Tests/ViewTests.swift": "// test comment\n",
        })
        lines = [f["line"] for f in of(ws.scan("check-project-rules"), "source_comment")]
        self.assertEqual(lines, [1, 2, 4, 9, 10])

    def test_plan_ids_outside_tests_and_smoke(self):
        ws = self.workspace({
            "include/Bridge.h": "// plans/261115-1720-devops-tools/phase-04-kubernetes.md\n",
            "core/agent/main.go": "package main\n\n// Kernel Telemetry (Wave 4 frame)\n// Phase 1: validate\n",
            "core/agent/wave_test.go": "package main\n\nfunc TestWave5(t *testing.T) {}\n",
            "scripts/smoke/run.sh": "echo phase-1\n",
        })
        findings = of(ws.scan("check-project-rules"), "plan_id_in_code")
        self.assertEqual(sorted((f["file"], f["symbol"]) for f in findings),
                         [("core/agent/main.go", "Wave 4"), ("include/Bridge.h", "plans/261115")])

    def test_todo_pseudo_fix(self):
        ws = self.workspace({"core/analysis/concurrency.go": (
            "package analysis\n\nfunc fix(indent string) string {\n"
            "\tguardComment := indent + \"// TODO(concurrency): ensure goroutine exits via ctx.Done()\"\n"
            "\ttitle := \"Use ctx Instead of context.TODO()\"\n"
            "\treturn guardComment + title\n}\n"
        )})
        findings = of(ws.scan("check-project-rules"), "todo_pseudo_fix")
        self.assertEqual([f["line"] for f in findings], [4])
        self.assertEqual(findings[0]["severity"], "High")


class ArchitectureTests(ScannerTestCase):
    def test_monolith_thresholds_skip_tests(self):
        ws = self.workspace({
            "desktop/Big.swift": "let x = 1\n" * 3000,
            "desktop/Small.swift": "let x = 1\n" * 1999,
            "core/big_test.go": "package x\n" * 6000,
        })
        findings = of(ws.scan("check-architecture"), "monolith_append_file")
        self.assertEqual([(f["file"], f["severity"]) for f in findings], [("desktop/Big.swift", "High")])


class GateTests(ScannerTestCase):
    def test_scan_uses_tracked_files_only_inside_git(self):
        ws = self.workspace({"docs/a.md": "plain\n"}, git=True)
        ws.write({"docs/untracked.md": "\u2705\n", ".claude/worktrees/x/docs/b.md": "\u2705\n"})
        self.assertEqual(of(ws.scan("check-ui-slop"), "prohibited_emoji"), [])

    def test_check_update_and_regression(self):
        ws = self.workspace({"docs/a.md": "\u2705\n"}, git=True)
        baseline = ws.root / "scripts/design/slop-baseline.json"
        self.assertEqual(ws.run("--check")[0], 1)
        self.assertEqual(ws.run("--update")[0], 0)
        self.assertEqual(json.loads(baseline.read_text())["prohibited_emoji"], 1)
        self.assertEqual(ws.run("--check")[0], 0)
        ws.write({"docs/a.md": "\u2705\n\u2705\n"})
        ws.commit()
        code, out = ws.run("--check")
        self.assertEqual(code, 1)
        self.assertIn("REGRESSED", out)
        self.assertEqual(ws.run("--update")[0], 1)
        self.assertEqual(json.loads(baseline.read_text())["prohibited_emoji"], 1)
        ws.write({"docs/a.md": "clean\n"})
        ws.commit()
        code, out = ws.run("--check")
        self.assertEqual(code, 0)
        self.assertIn("improved", out)
        self.assertEqual(ws.run("--update")[0], 0)
        self.assertEqual(json.loads(baseline.read_text())["prohibited_emoji"], 0)

    def test_diff_flags_added_lines_and_untracked_files_only(self):
        ws = self.workspace({
            "core/a.go": "package a\n\n// old comment\nfunc A() {}\n",
            "desktop/Big.swift": "let x = 1\n" * 1990,
        }, git=True)
        self.assertEqual(ws.run("--diff")[0], 0)
        ws.write({
            "core/a.go": "package a\n\n// old comment\nfunc A() {}\n\n// new comment\nfunc B() {}\n",
            "docs/new.md": "\u2705 shipped\n",
        })
        code, out = ws.run("--diff")
        self.assertEqual(code, 1)
        self.assertIn("core/a.go:6", out)
        self.assertIn("docs/new.md:1", out)
        self.assertNotIn("core/a.go:3", out)
        self.assertIn("2 slop finding(s)", out)

    def test_diff_file_level_counts_only_threshold_crossings(self):
        ws = self.workspace({
            "desktop/Big.swift": "let x = 1\n" * 1990,
            "desktop/Huge.swift": "let x = 1\n" * 2500,
        }, git=True)
        ws.write({
            "desktop/Big.swift": "let x = 1\n" * 2010,
            "desktop/Huge.swift": "let x = 1\n" * 2600,
        })
        code, out = ws.run("--diff")
        self.assertEqual(code, 1)
        self.assertIn("desktop/Big.swift", out)
        self.assertNotIn("desktop/Huge.swift", out)
        ws.commit()
        self.assertEqual(ws.run("--diff")[0], 0)
        self.assertEqual(ws.run("--diff", "HEAD~1")[0], 1)


if __name__ == "__main__":
    unittest.main()
