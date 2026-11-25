package safety

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestAuditGoModFile_ToolchainReplaceVulnAndPin(t *testing.T) {
	goModPath := "/workspace/demo/go.mod"
	content := strings.Join([]string{
		"module example.com/demo",
		"",
		"go 1.21",
		"",
		"require (",
		"\tgolang.org/x/crypto v0.14.0",
		"\tgolang.org/x/net v0.17.0 // indirect",
		"\tgithub.com/dgrijalva/jwt-go v3.2.0+incompatible",
		"\texample.com/unpinned v0.0.0-20231105142200-123456789abc",
		"\tgolang.org/x/sync v0.10.0",
		")",
		"",
		"replace example.com/foo => ../local-foo",
		"",
		"replace (",
		"\texample.com/bar v1.0.0 => github.com/fork/bar v1.0.1-fork",
		")",
		"",
	}, "\n")

	findings, err := AuditGoModFile(goModPath, content)
	if err != nil {
		t.Fatalf("AuditGoModFile unexpected error: %v", err)
	}

	var (
		hasToolchain   bool
		hasLocalRepl   bool
		hasBlockRepl   bool
		hasCryptoVuln  bool
		hasNetVuln     bool
		hasJwtVuln     bool
		hasUnpinnedPin bool
	)

	for _, f := range findings {
		if f.File != goModPath {
			t.Errorf("expected File %q, got %q", goModPath, f.File)
		}
		if f.RelFile != "go.mod" {
			t.Errorf("expected RelFile 'go.mod', got %q", f.RelFile)
		}

		switch {
		case strings.HasPrefix(f.ID, "DEP_TOOLCHAIN:"):
			hasToolchain = true
			if f.Line != 3 {
				t.Errorf("expected [DEP_TOOLCHAIN] on line 3, got %d", f.Line)
			}
			if !strings.Contains(f.Detail, "1.22") || !strings.Contains(f.Detail, "1.23") {
				t.Errorf("expected [DEP_TOOLCHAIN] detail to mention loopvar/1.23 upgrade, got %q", f.Detail)
			}
		case strings.HasPrefix(f.ID, "DEP_REPLACE:") && strings.Contains(f.Title, "example.com/foo"):
			hasLocalRepl = true
			if f.Line != 13 {
				t.Errorf("expected local [DEP_REPLACE] on line 13, got %d", f.Line)
			}
			if !strings.Contains(f.Detail, "go.sum") {
				t.Errorf("expected [DEP_REPLACE] detail to mention go.sum, got %q", f.Detail)
			}
		case strings.HasPrefix(f.ID, "DEP_REPLACE:") && strings.Contains(f.Title, "example.com/bar"):
			hasBlockRepl = true
			if f.Line != 16 {
				t.Errorf("expected block [DEP_REPLACE] on line 16, got %d", f.Line)
			}
		case strings.HasPrefix(f.ID, "DEP_VULN:") && strings.Contains(f.Title, "golang.org/x/crypto"):
			hasCryptoVuln = true
			if f.Line != 6 || f.Severity != 1 || f.Kind != "vuln" {
				t.Errorf("unexpected crypto [DEP_VULN]: %+v", f)
			}
		case strings.HasPrefix(f.ID, "DEP_VULN:") && strings.Contains(f.Title, "golang.org/x/net"):
			hasNetVuln = true
			if f.Line != 7 || f.Severity != 1 {
				t.Errorf("unexpected net [DEP_VULN]: %+v", f)
			}
		case strings.HasPrefix(f.ID, "DEP_VULN:") && strings.Contains(f.Title, "github.com/dgrijalva/jwt-go"):
			hasJwtVuln = true
			if f.Line != 8 || f.Severity != 1 {
				t.Errorf("unexpected jwt-go [DEP_VULN]: %+v", f)
			}
		case strings.HasPrefix(f.ID, "DEP_PIN:") && strings.Contains(f.Title, "example.com/unpinned"):
			hasUnpinnedPin = true
			if f.Line != 9 {
				t.Errorf("expected [DEP_PIN] on line 9, got %d", f.Line)
			}
		}
	}

	if !hasToolchain {
		t.Errorf("missing [DEP_TOOLCHAIN] finding in %+v", findings)
	}
	if !hasLocalRepl {
		t.Errorf("missing single-line [DEP_REPLACE] finding in %+v", findings)
	}
	if !hasBlockRepl {
		t.Errorf("missing block [DEP_REPLACE] finding in %+v", findings)
	}
	if !hasCryptoVuln {
		t.Errorf("missing golang.org/x/crypto [DEP_VULN] finding in %+v", findings)
	}
	if !hasNetVuln {
		t.Errorf("missing golang.org/x/net [DEP_VULN] finding in %+v", findings)
	}
	if !hasJwtVuln {
		t.Errorf("missing jwt-go [DEP_VULN] finding in %+v", findings)
	}
	if !hasUnpinnedPin {
		t.Errorf("missing [DEP_PIN] finding in %+v", findings)
	}
}

func TestAuditGoModFile_CleanModernGoMod(t *testing.T) {
	goModPath := "/workspace/clean/go.mod"
	content := strings.Join([]string{
		"module example.com/clean",
		"",
		"go 1.24.0",
		"",
		"require (",
		"\tgolang.org/x/crypto v0.32.0",
		"\tgolang.org/x/net v0.34.0",
		"\tgolang.org/x/text v0.21.0",
		"\tgopkg.in/yaml.v3 v3.0.1",
		"\tgithub.com/golang-jwt/jwt/v5 v5.2.2",
		")",
		"",
	}, "\n")

	findings, err := AuditGoModFile(goModPath, content)
	if err != nil {
		t.Fatalf("AuditGoModFile unexpected error: %v", err)
	}
	if len(findings) != 0 {
		t.Fatalf("expected 0 findings for clean modern go.mod, got %d: %+v", len(findings), findings)
	}
}

func TestRunSafetyAudit_IntegratesGoModFindings(t *testing.T) {
	tmpDir := t.TempDir()
	goModFile := filepath.Join(tmpDir, "go.mod")
	goModContent := "module example.com/integrated\n\ngo 1.21\n\nrequire gopkg.in/yaml.v2 v2.2.2\nreplace example.com/local => ./local\n"
	if err := os.WriteFile(goModFile, []byte(goModContent), 0644); err != nil {
		t.Fatalf("write go.mod: %v", err)
	}

	mainFile := filepath.Join(tmpDir, "main.go")
	mainContent := "package main\n\nfunc main() {}\n"
	if err := os.WriteFile(mainFile, []byte(mainContent), 0644); err != nil {
		t.Fatalf("write main.go: %v", err)
	}

	rawJSON, err := RunSafetyAudit(tmpDir, "")
	if err != nil {
		t.Fatalf("RunSafetyAudit error: %v", err)
	}

	var report Report
	if err := json.Unmarshal([]byte(rawJSON), &report); err != nil {
		t.Fatalf("unmarshal report: %v", err)
	}

	var foundToolchain, foundVuln, foundReplace bool
	for _, f := range report.Findings {
		if f.RelFile == "go.mod" {
			if strings.HasPrefix(f.ID, "DEP_TOOLCHAIN:") && f.Line == 3 {
				foundToolchain = true
			}
			if strings.HasPrefix(f.ID, "DEP_VULN:") && f.Line == 5 {
				foundVuln = true
			}
			if strings.HasPrefix(f.ID, "DEP_REPLACE:") && f.Line == 6 {
				foundReplace = true
			}
		}
	}

	if !foundToolchain || !foundVuln || !foundReplace {
		t.Fatalf("expected integrated go.mod findings (toolchain=%v, vuln=%v, replace=%v), got: %+v",
			foundToolchain, foundVuln, foundReplace, report.Findings)
	}
}
