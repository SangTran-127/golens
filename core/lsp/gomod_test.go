package lsp

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func TestGoModParseContentDirectivesAndBlocks(t *testing.T) {
	content := "module example.com/myproject\n" +
		"\n" +
		"go 1.23.0\n" +
		"\n" +
		"require example.com/single v0.1.0\n" +
		"\n" +
		"require (\n" +
		"\texample.com/foo v1.2.0\n" +
		"\texample.com/bar v0.5.3 // indirect\n" +
		")\n"

	report := ParseGoModContent(content, nil)

	if report.ModulePath != "example.com/myproject" {
		t.Fatalf("expected ModulePath example.com/myproject, got %q", report.ModulePath)
	}
	if report.ModuleLine != 1 {
		t.Fatalf("expected ModuleLine 1, got %d", report.ModuleLine)
	}
	if report.GoVersion != "1.23.0" {
		t.Fatalf("expected GoVersion 1.23.0, got %q", report.GoVersion)
	}
	if len(report.Requires) != 3 {
		t.Fatalf("expected 3 requires, got %d: %+v", len(report.Requires), report.Requires)
	}

	r0 := report.Requires[0]
	if r0.Line != 5 || r0.Module != "example.com/single" || r0.Version != "v0.1.0" || r0.Indirect {
		t.Fatalf("unexpected require[0]: %+v", r0)
	}

	r1 := report.Requires[1]
	if r1.Line != 8 || r1.Module != "example.com/foo" || r1.Version != "v1.2.0" || r1.Indirect {
		t.Fatalf("unexpected require[1]: %+v", r1)
	}

	r2 := report.Requires[2]
	if r2.Line != 9 || r2.Module != "example.com/bar" || r2.Version != "v0.5.3" || !r2.Indirect {
		t.Fatalf("unexpected require[2]: %+v", r2)
	}

	if len(report.Lenses) != 10 {
		t.Fatalf("expected 10 lenses (4 top-level + 3 why-used + 3 open-docs), got %d: %+v", len(report.Lenses), report.Lenses)
	}
	if report.Lenses[0].Line != 1 || report.Lenses[0].Command != "goModTidy" || report.Lenses[0].Title != "Run go mod tidy" || report.Lenses[0].CompactTitle != "Tidy" {
		t.Fatalf("unexpected lens[0]: %+v", report.Lenses[0])
	}
	if report.Lenses[1].Line != 1 || report.Lenses[1].Command != "goModCheckUpdates" || report.Lenses[1].Title != "Check Module Updates" || report.Lenses[1].CompactTitle != "Updates" {
		t.Fatalf("unexpected lens[1]: %+v", report.Lenses[1])
	}
	if report.Lenses[2].Line != 1 || report.Lenses[2].Command != "goModDownload" || report.Lenses[2].Title != "Download Modules" || report.Lenses[2].CompactTitle != "Download" {
		t.Fatalf("unexpected lens[2]: %+v", report.Lenses[2])
	}
	if report.Lenses[3].Line != 1 || report.Lenses[3].Command != "goModAdd" || report.Lenses[3].Title != "Add Module…" || report.Lenses[3].CompactTitle != "Add…" {
		t.Fatalf("unexpected lens[3]: %+v", report.Lenses[3])
	}
	if report.Lenses[4].Line != 5 || report.Lenses[4].Command != "goModWhy" || report.Lenses[4].Arg != "example.com/single" {
		t.Fatalf("unexpected lens[4]: %+v", report.Lenses[4])
	}
	if report.Lenses[5].Line != 5 || report.Lenses[5].Command != "goModOpenDocs" || report.Lenses[5].Title != "Open Documentation" || report.Lenses[5].CompactTitle != "Docs" || report.Lenses[5].Arg != "example.com/single" {
		t.Fatalf("unexpected lens[5]: %+v", report.Lenses[5])
	}
}

func TestGoModParseContentUpdatesAndUpgradeLenses(t *testing.T) {
	content := "module example.com/myproject\n" +
		"\n" +
		"go 1.23\n" +
		"\n" +
		"require (\n" +
		"\texample.com/foo v1.2.0\n" +
		"\texample.com/up-to-date v2.0.0\n" +
		")\n"

	updates := map[string]string{
		"example.com/foo":        "v1.4.0",
		"example.com/up-to-date": "v2.0.0",
	}

	report := ParseGoModContent(content, updates)

	if len(report.Requires) != 2 {
		t.Fatalf("expected 2 requires, got %d", len(report.Requires))
	}
	if report.Requires[0].Latest != "v1.4.0" {
		t.Fatalf("expected Latest v1.4.0 on example.com/foo, got %q", report.Requires[0].Latest)
	}
	if report.Requires[1].Latest != "" {
		t.Fatalf("expected empty Latest on up-to-date module, got %q", report.Requires[1].Latest)
	}

	if len(report.Lenses) != 9 {
		t.Fatalf("expected 9 lenses (4 top-level + 1 upgrade + 2 why-used + 2 open-docs), got %d: %+v", len(report.Lenses), report.Lenses)
	}
	upgrade := report.Lenses[4]
	if upgrade.Line != 6 {
		t.Fatalf("expected upgrade lens on line 6, got %d", upgrade.Line)
	}
	if upgrade.Title != "Upgrade to v1.4.0" {
		t.Fatalf("expected title 'Upgrade to v1.4.0', got %q", upgrade.Title)
	}
	if upgrade.Command != "goModGet" {
		t.Fatalf("expected command 'goModGet', got %q", upgrade.Command)
	}
	if upgrade.Arg != "example.com/foo@v1.4.0" {
		t.Fatalf("expected arg 'example.com/foo@v1.4.0', got %q", upgrade.Arg)
	}
}

func TestGoModInspectJSONFromTempFile(t *testing.T) {
	dir := t.TempDir()
	goModPath := filepath.Join(dir, "go.mod")
	content := "module example.com/tempmod\n\ngo 1.22\n\nrequire golang.org/x/sync v0.7.0 // indirect\n"
	if err := os.WriteFile(goModPath, []byte(content), 0o644); err != nil {
		t.Fatalf("failed to write temp go.mod: %v", err)
	}

	rawJSON := InspectGoModJSON(goModPath, "", false)
	var report GoModInspectReport
	if err := json.Unmarshal([]byte(rawJSON), &report); err != nil {
		t.Fatalf("failed to unmarshal InspectGoModJSON output: %v (raw=%s)", err, rawJSON)
	}

	if report.ModulePath != "example.com/tempmod" || report.ModuleLine != 1 {
		t.Fatalf("unexpected module info: %+v", report)
	}
	if report.GoVersion != "1.22" {
		t.Fatalf("unexpected goVersion: %q", report.GoVersion)
	}
	if len(report.Requires) != 1 {
		t.Fatalf("expected 1 require, got %d", len(report.Requires))
	}
	req := report.Requires[0]
	if req.Line != 5 || req.Module != "golang.org/x/sync" || req.Version != "v0.7.0" || !req.Indirect {
		t.Fatalf("unexpected require entry: %+v", req)
	}
	if len(report.Lenses) != 6 {
		t.Fatalf("expected 6 lenses (4 top-level + 1 why-used + 1 open-docs), got %d: %+v", len(report.Lenses), report.Lenses)
	}
}
