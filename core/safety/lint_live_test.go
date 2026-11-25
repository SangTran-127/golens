package safety

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"

	"golens/core/bridge"
)

const golangciV1Sample = `{"Issues":[{"FromLinter":"errcheck","Text":"Error return value of ` + "`os.Remove`" + ` is not checked","Severity":"","SourceLines":["\tos.Remove(path)"],"Replacement":null,"Pos":{"Filename":"pkg/clean/clean.go","Offset":52,"Line":6,"Column":11},"ExpectNoLint":false,"ExpectedNoLintLinter":""},{"FromLinter":"typecheck","Text":"undefined: y","Severity":"","Pos":{"Filename":"pkg/clean/clean.go","Line":1,"Column":0}}],"Report":{"Linters":[{"Name":"errcheck","Enabled":true}]}}`

const golangciV2Sample = `{"Issues":[{"FromLinter":"ineffassign","Text":"ineffectual assignment to x","Severity":"error","SourceLines":["\tx := 1"],"Pos":{"Filename":"pkg/clean/clean.go","Offset":80,"Line":10,"Column":2},"ExpectNoLint":false,"ExpectedNoLintLinter":""}],"Report":{"Linters":[{"Name":"ineffassign","Enabled":true}]}}
0 issues.`

func TestDecodeGolangCILintOutputShapes(t *testing.T) {
	v1, ok := decodeGolangCILintOutput([]byte(golangciV1Sample))
	if !ok || len(v1.Issues) != 2 || v1.Issues[0].FromLinter != "errcheck" || v1.Issues[0].Pos.Column != 11 {
		t.Fatalf("v1 decode: ok=%v %+v", ok, v1)
	}
	v2, ok := decodeGolangCILintOutput([]byte("level=warning msg=\"x\"\n" + golangciV2Sample))
	if !ok || len(v2.Issues) != 1 || v2.Issues[0].Severity != "error" {
		t.Fatalf("v2 decode: ok=%v %+v", ok, v2)
	}
	if _, ok := decodeGolangCILintOutput([]byte("Error: can't load config")); ok {
		t.Fatal("expected config error output to fail decoding")
	}
}

func TestParseGolangCIMajorVersion(t *testing.T) {
	cases := map[string]int{
		"golangci-lint has version 1.59.1 built with go1.22.3":           1,
		"golangci-lint has version v2.1.6 built with go1.24.2 from abcd": 2,
		"garbage": 1,
	}
	for in, want := range cases {
		if got := parseGolangCIMajorVersion(in); got != want {
			t.Errorf("%q: got %d want %d", in, got, want)
		}
	}
}

func TestLiveLintDiagnosticRange(t *testing.T) {
	src := []string{"package clean", "", "func Clean(path string) {", "", "", "\tos.Remove(path)"}
	issue := golangciLintIssue{FromLinter: "errcheck", Text: "Error return value is not checked", Pos: golangciLintPos{Line: 6, Column: 2}}
	d := liveLintDiagnostic(issue, src)
	if d.Line != 5 || d.Col != 1 || d.EndCol != 10 || d.Severity != 2 || d.Source != "golangci-lint" {
		t.Fatalf("unexpected diagnostic %+v", d)
	}
	whole := liveLintDiagnostic(golangciLintIssue{Text: "x", Severity: "error", Pos: golangciLintPos{Line: 6}}, src)
	if whole.Col != 1 || whole.EndCol != len("\tos.Remove(path)") || whole.Severity != 1 {
		t.Fatalf("unexpected whole-line diagnostic %+v", whole)
	}
	call := liveLintDiagnostic(golangciLintIssue{Text: "x", Pos: golangciLintPos{Line: 6, Column: 11}}, src)
	if call.Col != 1 || call.EndCol != 10 {
		t.Fatalf("expected the call before the column, got %+v", call)
	}
	wide := liveLintDiagnostic(golangciLintIssue{Text: "x", Pos: golangciLintPos{Line: 1, Column: 6}}, []string{"s := \"é\" + v"})
	if wide.Col != 5 || wide.EndCol != 6 {
		t.Fatalf("unexpected utf16 range %+v", wide)
	}
}

func TestFindGolangCIConfig(t *testing.T) {
	root := t.TempDir()
	pkg := filepath.Join(root, "a", "b")
	if err := os.MkdirAll(pkg, 0o755); err != nil {
		t.Fatal(err)
	}
	if got := FindGolangCIConfig(pkg, root); got != "" {
		t.Fatalf("expected no config, got %q", got)
	}
	cfg := filepath.Join(root, ".golangci.yaml")
	if err := os.WriteFile(cfg, []byte("version: \"2\"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if got := FindGolangCIConfig(pkg, root); got != cfg {
		t.Fatalf("expected %q, got %q", cfg, got)
	}
}

func TestRunPackageLintWithoutConfigIsUnavailable(t *testing.T) {
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "go.mod"), []byte("module example.com/x\n\ngo 1.22\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "x.go"), []byte("package x\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	res := runPackageLint(context.Background(), root, root, 5*time.Second)
	if res.Status != "unavailable" {
		t.Fatalf("expected unavailable, got %+v", res)
	}
}

func TestRunPackageLintReportsErrcheck(t *testing.T) {
	if bridge.GetVsockDialer() == nil {
		t.Skip("skipping in host-only environment without Micro-VM vsock dialer")
	}
	if ResolveGolangCILint() == "" {
		t.Skip("golangci-lint not installed")
	}
	if _, err := exec.LookPath("go"); err != nil {
		t.Skip("go not on PATH")
	}
	root := t.TempDir()
	pkg := filepath.Join(root, "pkg", "clean")
	if err := os.MkdirAll(pkg, 0o755); err != nil {
		t.Fatal(err)
	}
	files := map[string]string{
		filepath.Join(root, "go.mod"):        "module example.com/lintfix\n\ngo 1.22\n",
		filepath.Join(root, ".golangci.yml"): "linters:\n  disable-all: true\n  enable:\n    - errcheck\n",
		filepath.Join(pkg, "clean.go"):       "package clean\n\nimport \"os\"\n\nfunc Clean(path string) {\n\tos.Remove(path)\n}\n",
		filepath.Join(pkg, "ok.go"):          "package clean\n\nfunc OK() {}\n",
	}
	if golangciMajorVersion(ResolveGolangCILint()) >= 2 {
		files[filepath.Join(root, ".golangci.yml")] = "version: \"2\"\nlinters:\n  default: none\n  enable:\n    - errcheck\n"
	}
	for path, content := range files {
		if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	if msg := golangciToolchainMismatch(ResolveGolangCILint()); msg != "" {
		res := runPackageLint(context.Background(), root, pkg, liveLintTimeout)
		if res.Status != "error" || res.Error != msg {
			t.Fatalf("expected toolchain mismatch error, got %+v", res)
		}
		t.Skip(msg)
	}
	res := runPackageLint(context.Background(), root, pkg, liveLintTimeout)
	if res.Status != "ok" {
		t.Fatalf("expected ok, got %+v", res)
	}
	if _, ok := res.Files[filepath.Join(pkg, "ok.go")]; !ok {
		t.Fatalf("expected clean file listed, got %+v", res.Files)
	}
	diags := res.Files[filepath.Join(pkg, "clean.go")]
	if len(diags) == 0 {
		t.Skip("installed golangci-lint reported nothing; it may predate the local Go toolchain")
	}
	if diags[0].Code != "errcheck" || diags[0].Line != 5 || diags[0].Source != "golangci-lint" {
		t.Fatalf("unexpected errcheck diagnostic %+v", diags[0])
	}
}

func TestRunPackageLintReportsConfigError(t *testing.T) {
	if bridge.GetVsockDialer() == nil {
		t.Skip("skipping in host-only environment without Micro-VM vsock dialer")
	}
	if ResolveGolangCILint() == "" {
		t.Skip("golangci-lint not installed")
	}
	root := t.TempDir()
	for path, content := range map[string]string{
		filepath.Join(root, "go.mod"):        "module example.com/x\n\ngo 1.22\n",
		filepath.Join(root, ".golangci.yml"): "linters:\n  enable:\n    - doesnotexist\n",
		filepath.Join(root, "x.go"):          "package x\n",
	} {
		if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	res := runPackageLint(context.Background(), root, root, liveLintTimeout)
	if res.Status != "error" || res.Error == "" {
		t.Fatalf("expected a config error, got %+v", res)
	}
	t.Log(res.Error)
}

func TestGolangCIBuiltWithParsing(t *testing.T) {
	if got := parseBuiltWithGoMinor("golangci-lint has version 1.59.1 built with go1.22.3 from 1a55854a on 2024-06-09T18:08:33Z"); got != 22 {
		t.Fatalf("v1 built-with minor = %d, want 22", got)
	}
	if got := parseBuiltWithGoMinor("golangci-lint has version 2.15.0 built with go1.27.1 from abc on 2026-10-01"); got != 27 {
		t.Fatalf("v2 built-with minor = %d, want 27", got)
	}
	if got := parseBuiltWithGoMinor("golangci-lint has version 2.15.0"); got != 0 {
		t.Fatalf("missing built-with = %d, want 0", got)
	}
	if got := parseGoMinor("go1.27.1\n"); got != 27 {
		t.Fatalf("GOVERSION minor = %d, want 27", got)
	}
}
