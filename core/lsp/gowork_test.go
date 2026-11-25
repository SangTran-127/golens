package lsp

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"golens/core/vmexec"
)

func TestGoModLocalReplaceLensesAndDiagnostics(t *testing.T) {
	root := t.TempDir()
	localTarget := filepath.Join(root, "sibling")
	if err := os.MkdirAll(localTarget, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(localTarget, "go.mod"), []byte("module example.com/sibling\n\ngo 1.24.0\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	appDir := filepath.Join(root, "app")
	if err := os.MkdirAll(appDir, 0o755); err != nil {
		t.Fatal(err)
	}
	goModPath := filepath.Join(appDir, "go.mod")
	content := strings.Join([]string{
		"module example.com/app",
		"",
		"go 1.24.0",
		"",
		"replace example.com/sibling => ../sibling",
		"",
		"replace (",
		"\texample.com/missing => ../does-not-exist",
		"\texample.com/fork v1.0.0 => example.com/fork-fix v1.0.1",
		")",
	}, "\n")
	if err := os.WriteFile(goModPath, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}

	raw := InspectGoModJSON(goModPath, "", false)
	var report GoModInspectReport
	if err := json.Unmarshal([]byte(raw), &report); err != nil {
		t.Fatalf("decode error: %v", err)
	}

	if len(report.Replaces) != 3 {
		t.Fatalf("expected 3 replaces, got %d: %+v", len(report.Replaces), report.Replaces)
	}
	if !report.Replaces[0].IsLocal || !report.Replaces[0].TargetExists || !report.Replaces[0].TargetHasGoMod {
		t.Fatalf("expected existing local replace with go.mod: %+v", report.Replaces[0])
	}
	if !report.Replaces[1].IsLocal || report.Replaces[1].TargetExists {
		t.Fatalf("expected missing local replace: %+v", report.Replaces[1])
	}
	if report.Replaces[2].IsLocal {
		t.Fatalf("expected remote fork replace not to be marked local: %+v", report.Replaces[2])
	}

	var hasDrop5, hasOpen5, hasDrop8, hasOpen8 bool
	for _, l := range report.Lenses {
		switch {
		case l.Line == 5 && l.Command == "goModDropReplace":
			hasDrop5 = true
		case l.Line == 5 && l.Command == "goModOpenReplace" && l.Arg == localTarget:
			hasOpen5 = true
		case l.Line == 8 && l.Command == "goModDropReplace":
			hasDrop8 = true
		case l.Line == 8 && l.Command == "goModOpenReplace":
			hasOpen8 = true
		}
	}
	if !hasDrop5 || !hasOpen5 || !hasDrop8 || hasOpen8 {
		t.Fatalf("unexpected replace lenses: %+v", report.Lenses)
	}

	var hasWarn5, hasErr8 bool
	for _, d := range report.Diagnostics {
		if d.Line == 5 && d.Code == "local-replace" && d.Severity == 2 {
			hasWarn5 = true
		}
		if d.Line == 8 && d.Code == "local-replace-missing" && d.Severity == 1 {
			hasErr8 = true
		}
	}
	if !hasWarn5 || !hasErr8 {
		t.Fatalf("unexpected diagnostics: %+v", report.Diagnostics)
	}
}

func TestGoWorkDoctorDetectsMismatchUnlistedMissingAndSkew(t *testing.T) {
	root := t.TempDir()

	writeFile := func(rel, data string) {
		t.Helper()
		full := filepath.Join(root, rel)
		if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(full, []byte(data), 0o644); err != nil {
			t.Fatal(err)
		}
	}

	writeFile("api/go.mod", "module example.com/api\n\ngo 1.24.0\n\nrequire golang.org/x/sync v0.8.0\n")
	writeFile("worker/go.mod", "module example.com/worker\n\ngo 1.26.2\n\nrequire golang.org/x/sync v0.10.0\n")
	writeFile("cli/go.mod", "module example.com/cli\n\ngo 1.24.0\n")

	goWorkPath := filepath.Join(root, "go.work")
	goWorkContent := strings.Join([]string{
		"go 1.24.0",
		"",
		"use (",
		"\t./api",
		"\t./worker",
		"\t./ghost",
		")",
		"",
		"replace example.com/shared => ./cli",
	}, "\n")
	writeFile("go.work", goWorkContent)

	raw := InspectGoModJSON(goWorkPath, "", false)
	var report GoModInspectReport
	if err := json.Unmarshal([]byte(raw), &report); err != nil {
		t.Fatalf("decode error: %v", err)
	}
	if report.GoWork == nil {
		t.Fatalf("expected non-nil GoWork report")
	}
	if report.GoWork.HighestChildGoVersion != "1.26.2" {
		t.Fatalf("expected HighestChildGoVersion 1.26.2, got %q", report.GoWork.HighestChildGoVersion)
	}
	if !report.GoWork.NeedsSync {
		t.Fatalf("expected NeedsSync=true when api and worker disagree on golang.org/x/sync")
	}
	if len(report.GoWork.UnlistedModules) != 1 || report.GoWork.UnlistedModules[0].RelPath != "./cli" {
		t.Fatalf("expected unlisted ./cli, got %+v", report.GoWork.UnlistedModules)
	}

	hasCmd := func(cmd, arg string) bool {
		for _, l := range report.Lenses {
			if l.Command == cmd && (arg == "" || l.Arg == arg) {
				return true
			}
		}
		return false
	}
	if !hasCmd("goWorkSync", "") {
		t.Fatalf("missing goWorkSync lens in %+v", report.Lenses)
	}
	if !hasCmd("goWorkUpdateGoVersion", "1.26.2") {
		t.Fatalf("missing goWorkUpdateGoVersion lens in %+v", report.Lenses)
	}
	if !hasCmd("goWorkAddModule", "./cli") {
		t.Fatalf("missing goWorkAddModule ./cli lens in %+v", report.Lenses)
	}
	if !hasCmd("goWorkDropUse", "./ghost") {
		t.Fatalf("missing goWorkDropUse ./ghost lens in %+v", report.Lenses)
	}
	if !hasCmd("goModDropReplace", "9") || !hasCmd("goModOpenReplace", filepath.Join(root, "cli")) {
		t.Fatalf("missing replace lenses in %+v", report.Lenses)
	}
}

func TestParseGoModWhyOutputNeededAndUnused(t *testing.T) {
	neededRaw := strings.Join([]string{
		"# golang.org/x/sync/errgroup",
		"example.com/app",
		"example.com/app/internal/jobs",
		"golang.org/x/sync/errgroup",
	}, "\n")
	rep := ParseGoModWhyOutput("golang.org/x/sync", neededRaw)
	if !rep.Needed {
		t.Fatalf("expected Needed=true: %+v", rep)
	}
	if len(rep.Stanzas) != 1 || len(rep.Stanzas[0].Chain) != 3 {
		t.Fatalf("unexpected stanzas: %+v", rep.Stanzas)
	}
	if !strings.Contains(rep.Summary, "example.com/app -> example.com/app/internal/jobs -> golang.org/x/sync/errgroup") {
		t.Fatalf("unexpected summary: %q", rep.Summary)
	}

	unusedRaw := "# example.com/unused\n(main module does not need module example.com/unused)\n"
	unused := ParseGoModWhyOutput("example.com/unused", unusedRaw)
	if unused.Needed {
		t.Fatalf("expected Needed=false: %+v", unused)
	}
	if !strings.Contains(unused.Summary, "does not need module") {
		t.Fatalf("unexpected unused summary: %q", unused.Summary)
	}
}

func TestGoModWhyJSONRealModuleFixture(t *testing.T) {
	dir := t.TempDir()
	goModPath := filepath.Join(dir, "go.mod")
	if err := os.WriteFile(goModPath, []byte("module example.com/whytest\n\ngo 1.24.0\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	mainGo := "package main\n\nimport _ \"embed\"\n\nfunc main() {}\n"
	if err := os.WriteFile(filepath.Join(dir, "main.go"), []byte(mainGo), 0o644); err != nil {
		t.Fatal(err)
	}
	raw := GoModWhyJSON(goModPath, "example.com/notpresent")
	var rep GoModWhyReport
	if err := json.Unmarshal([]byte(raw), &rep); err != nil {
		t.Fatalf("decode error: %v (raw=%s)", err, raw)
	}
	if rep.Module != "example.com/notpresent" {
		t.Fatalf("unexpected module: %+v", rep)
	}
	if rep.Needed {
		t.Fatalf("expected Needed=false for unused module: %+v", rep)
	}
}

func TestResolveWorkspaceGuestDirForChildModuleAndOutsideDir(t *testing.T) {
	life.mu.Lock()
	prevRoot := life.root
	root := filepath.Join(t.TempDir(), "ws")
	child := filepath.Join(root, "app_a")
	outside := t.TempDir()
	life.root = root
	life.mu.Unlock()
	defer func() {
		life.mu.Lock()
		life.root = prevRoot
		life.mu.Unlock()
	}()

	gotChild := resolveWorkspaceGuestDir(child)
	wantChild := vmexec.HostToGuestPath(root, child)
	if gotChild != wantChild || !strings.HasSuffix(gotChild, "/app_a") {
		t.Fatalf("expected child guest path %q, got %q", wantChild, gotChild)
	}
	if unmounted := vmexec.HostToGuestPath(child, child); gotChild == unmounted {
		t.Fatalf("child guest path %q should not use child-only slug %q", gotChild, unmounted)
	}
	gotOutside := resolveWorkspaceGuestDir(outside)
	if strings.Contains(gotOutside, "/app_a") || strings.Contains(gotOutside, filepath.Base(root)) {
		t.Fatalf("expected outside path not to map under workspace root slug, got %q", gotOutside)
	}
}

func TestInspectGoModJSONPropagatesUpdateError(t *testing.T) {
	dir := t.TempDir()
	goModPath := filepath.Join(dir, "go.mod")
	if err := os.WriteFile(goModPath, []byte("module example.com/errtest\n\ngo 1.24.0\n\nrequire example.com/nonexistent-mod v1.0.0\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "main.go"), []byte("package main\nfunc main() {}\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	raw := InspectGoModJSON(goModPath, "", true)
	var rep GoModInspectReport
	if err := json.Unmarshal([]byte(raw), &rep); err != nil {
		t.Fatalf("decode error: %v", err)
	}
	if strings.TrimSpace(rep.UpdateError) == "" {
		t.Fatalf("expected non-empty UpdateError when go list -m -u fails, got %+v", rep)
	}
}
