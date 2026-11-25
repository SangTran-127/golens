package safety

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestAuditWorkspaceGoModAndGoWorkMissingLocalReplace(t *testing.T) {
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "svc"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(root, "extra"), 0o755); err != nil {
		t.Fatal(err)
	}
	svcGoMod := filepath.Join(root, "svc", "go.mod")
	if err := os.WriteFile(svcGoMod, []byte("module example.com/svc\n\ngo 1.26.2\n\nreplace example.com/missing => ../nope\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "extra", "go.mod"), []byte("module example.com/extra\n\ngo 1.24.0\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	goWork := filepath.Join(root, "go.work")
	if err := os.WriteFile(goWork, []byte("go 1.24.0\n\nuse ./svc\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	findings := auditWorkspaceGoMod(root)
	var sawMissingReplace, sawMismatch, sawUnlisted bool
	for _, f := range findings {
		if strings.HasPrefix(f.ID, "DEP_REPLACE:") && f.RelFile == filepath.Join("svc", "go.mod") {
			if f.Severity == 1 && strings.Contains(f.Detail, "does not exist on disk") && strings.Contains(f.Detail, "go.sum") {
				sawMissingReplace = true
			}
		}
		if strings.HasPrefix(f.ID, "DEP_GOWORK:") && strings.Contains(f.Symbol, "version-mismatch") {
			sawMismatch = true
		}
		if strings.HasPrefix(f.ID, "DEP_GOWORK:") && strings.Contains(f.Symbol, "unlisted-module") {
			sawUnlisted = true
		}
	}
	if !sawMissingReplace || !sawMismatch || !sawUnlisted {
		t.Fatalf("missing expected findings: replace=%v mismatch=%v unlisted=%v findings=%+v", sawMissingReplace, sawMismatch, sawUnlisted, findings)
	}
}
