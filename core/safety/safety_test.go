package safety

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestAnalyzeDeadcode_UnreferencedUnexportedFunctions(t *testing.T) {
	tmpDir := t.TempDir()

	src := `package sample

func main() {
	usedHelper()
}

func init() {}

func usedHelper() int {
	return 42
}

func testedOnlyHelper() string {
	return "ok"
}

func orphanHelper() int {
	return 99
}

func ExportedUnused() {}
`
	testSrc := `package sample

import "testing"

func TestSomething(t *testing.T) {
	_ = testedOnlyHelper()
}
`
	mainFile := filepath.Join(tmpDir, "main.go")
	testFile := filepath.Join(tmpDir, "main_test.go")

	if err := os.WriteFile(mainFile, []byte(src), 0644); err != nil {
		t.Fatalf("write main.go: %v", err)
	}
	if err := os.WriteFile(testFile, []byte(testSrc), 0644); err != nil {
		t.Fatalf("write main_test.go: %v", err)
	}

	findings := analyzeASTDeadcode(tmpDir)
	if len(findings) != 1 {
		t.Fatalf("expected exactly 1 deadcode finding, got %d: %+v", len(findings), findings)
	}

	got := findings[0]
	if got.Kind != "deadcode" {
		t.Errorf("expected Kind 'deadcode', got %q", got.Kind)
	}
	if got.Symbol != "orphanHelper" {
		t.Errorf("expected Symbol 'orphanHelper', got %q", got.Symbol)
	}
	if got.Line != 17 {
		t.Errorf("expected Line 17, got %d", got.Line)
	}
	if got.RelFile != "main.go" {
		t.Errorf("expected RelFile 'main.go', got %q", got.RelFile)
	}
	if got.Title != "Unreachable function 'orphanHelper'" {
		t.Errorf("unexpected Title: %q", got.Title)
	}
}

func TestAnalyzeASTHazards_ConcurrencyAndSecurity(t *testing.T) {
	tmpDir := t.TempDir()

	src := `package hazardpkg

import (
	"crypto/tls"
	"net/http"
	"os/exec"
	"sync"
)

func RunHazards(items []string) {
	var wg sync.WaitGroup
	var mu sync.Mutex

	go func() {
		wg.Add(1)
		defer wg.Done()
	}()

	for _, item := range items {
		mu.Lock()
		defer mu.Unlock()
		_ = item
	}

	cfg := &tls.Config{
		InsecureSkipVerify: true,
	}
	_ = cfg

	_, _ = http.Get("https://example.com")
	_ = exec.Command("sh", "-c", "echo hello")
}
`
	file := filepath.Join(tmpDir, "hazards.go")
	if err := os.WriteFile(file, []byte(src), 0644); err != nil {
		t.Fatalf("write hazards.go: %v", err)
	}

	findings := analyzeASTHazards(tmpDir)

	foundIDs := make(map[string]Finding)
	for _, f := range findings {
		parts := strings.SplitN(f.ID, ":", 2)
		foundIDs[parts[0]] = f
	}

	requiredRules := map[string]int{
		"GO-CONC-WAITGROUP":   15,
		"GO-CONC-LOCK-COPY":   21,
		"GO-SEC-TLS-INSECURE": 26,
		"GO-SEC-HTTP-DEFAULT": 30,
		"GO-SEC-EXEC-SHELL":   31,
	}

	for rule, wantLine := range requiredRules {
		f, ok := foundIDs[rule]
		if !ok {
			t.Errorf("missing expected hazard rule %q in findings: %+v", rule, findings)
			continue
		}
		if f.Kind != "hazard" {
			t.Errorf("rule %s: expected Kind 'hazard', got %q", rule, f.Kind)
		}
		if f.Line != wantLine {
			t.Errorf("rule %s: expected Line %d, got %d", rule, wantLine, f.Line)
		}
		if f.RelFile != "hazards.go" {
			t.Errorf("rule %s: expected RelFile 'hazards.go', got %q", rule, f.RelFile)
		}
	}
}

func TestParseRaceAndPanic_ExactFileAndLine(t *testing.T) {
	workspaceDir := "/workspace/project"
	workerFile := filepath.Join(workspaceDir, "pkg", "worker.go")
	serverFile := filepath.Join(workspaceDir, "cmd", "server.go")

	consoleOutput := `==================
WARNING: DATA RACE
Write at 0x00c0000180b0 by goroutine 8:
  project/pkg.Increment()
      /workspace/project/pkg/worker.go:42 +0x44
  project/pkg.Run.func1()
      /workspace/project/pkg/worker.go:30 +0x28

Previous read at 0x00c0000180b0 by goroutine 7:
  project/pkg.ReadCounter()
      /workspace/project/pkg/worker.go:55 +0x3c
==================
panic: runtime error: invalid memory address or nil pointer dereference
[signal SIGSEGV: segmentation violation code=0x2 addr=0x0 pc=0x100a4b2c0]

goroutine 1 [running]:
runtime.gopanic(0x100b12340, 0x100c98760)
	/usr/local/go/src/runtime/panic.go:770 +0x124
project/cmd.handleRequest(0x0)
	/workspace/project/cmd/server.go:88 +0x64
main.main()
	/workspace/project/cmd/server.go:19 +0x20
`

	findings := ParseRaceAndPanic(workspaceDir, consoleOutput)
	if len(findings) != 2 {
		t.Fatalf("expected 2 findings (1 race, 1 panic), got %d: %+v", len(findings), findings)
	}

	raceFinding := findings[0]
	if raceFinding.Kind != "race" {
		t.Errorf("expected Kind 'race', got %q", raceFinding.Kind)
	}
	if raceFinding.Title != "Data race detected" {
		t.Errorf("expected Title 'Data race detected', got %q", raceFinding.Title)
	}
	if raceFinding.File != workerFile {
		t.Errorf("expected race File %q, got %q", workerFile, raceFinding.File)
	}
	if raceFinding.RelFile != "pkg/worker.go" {
		t.Errorf("expected race RelFile 'pkg/worker.go', got %q", raceFinding.RelFile)
	}
	if raceFinding.Line != 42 {
		t.Errorf("expected race Line 42, got %d", raceFinding.Line)
	}
	if len(raceFinding.CallChain) == 0 {
		t.Errorf("expected non-empty CallChain on race finding")
	}

	panicFinding := findings[1]
	if panicFinding.Kind != "race" {
		t.Errorf("expected Kind 'race' for panic, got %q", panicFinding.Kind)
	}
	if !strings.HasPrefix(panicFinding.Title, "Runtime panic: runtime error: invalid memory address") {
		t.Errorf("unexpected panic Title: %q", panicFinding.Title)
	}
	if panicFinding.File != serverFile {
		t.Errorf("expected panic File %q, got %q", serverFile, panicFinding.File)
	}
	if panicFinding.RelFile != "cmd/server.go" {
		t.Errorf("expected panic RelFile 'cmd/server.go', got %q", panicFinding.RelFile)
	}
	if panicFinding.Line != 88 {
		t.Errorf("expected panic Line 88, got %d", panicFinding.Line)
	}
}

func TestParseGovulncheckJSON(t *testing.T) {
	workspaceDir := "/workspace/project"
	stream := `{"osv":{"id":"GO-2026-0001","summary":"HTTP2 rapid reset DoS in golang.org/x/net","details":"An attacker can cause excessive resource consumption."}}
{"finding":{"osv":"GO-2026-0001","fixed_version":"v0.23.0","trace":[{"module":"golang.org/x/net","package":"golang.org/x/net/http2","function":"ServeConn"},{"module":"project","package":"project/server","function":"Start","position":{"filename":"/workspace/project/server/http.go","line":34,"column":12}}]}}
`
	findings := parseGovulncheckJSON(workspaceDir, []byte(stream))
	if len(findings) != 1 {
		t.Fatalf("expected 1 vuln finding, got %d", len(findings))
	}
	got := findings[0]
	if got.Kind != "vuln" || got.Severity != 1 {
		t.Errorf("unexpected kind/severity: %+v", got)
	}
	if got.RelFile != "server/http.go" || got.Line != 34 || got.Col != 12 {
		t.Errorf("unexpected location: %s:%d:%d", got.RelFile, got.Line, got.Col)
	}
	if len(got.CallChain) != 2 {
		t.Errorf("expected 2-frame callChain, got %v", got.CallChain)
	}
}

func TestRunAudit_EndToEndJSONReport(t *testing.T) {
	tmpDir := t.TempDir()
	code := `package main

import "net/http"

func main() {
	_, _ = http.Get("https://example.com")
}

func unusedInternal() {}
`
	mainPath := filepath.Join(tmpDir, "main.go")
	if err := os.WriteFile(mainPath, []byte(code), 0644); err != nil {
		t.Fatalf("write main.go: %v", err)
	}

	trace := "panic: boom\n\ngoroutine 1 [running]:\nmain.main()\n\t" + mainPath + ":6 +0x20\n"
	rawJSON, err := RunAudit(tmpDir, trace)
	if err != nil {
		t.Fatalf("RunAudit error: %v", err)
	}

	var report Report
	if err := json.Unmarshal([]byte(rawJSON), &report); err != nil {
		t.Fatalf("unmarshal report: %v", err)
	}

	if len(report.Findings) < 3 {
		t.Fatalf("expected at least 3 findings (panic, http hazard, deadcode), got %d: %+v", len(report.Findings), report.Findings)
	}
	if report.Findings[0].Severity != 1 {
		t.Errorf("expected highest severity (1) sorted first, got %d", report.Findings[0].Severity)
	}
	if report.Summary == "" {
		t.Errorf("expected non-empty summary")
	}
}

func TestScanPackageCapabilities_DetectsAllCapabilityTypes(t *testing.T) {
	tmpDir := t.TempDir()

	src := `package caps

import (
	"net"
	"net/http"
	"os"
	"os/exec"
	"reflect"
	"unsafe"
)

func UseCapabilities(ptr *int) {
	_, _ = net.Listen("tcp", "127.0.0.1:0")
	_, _ = http.NewRequest("GET", "https://example.com", nil)
	_ = exec.Command("ls", "-la")
	_ = os.WriteFile("/tmp/test.txt", []byte("hi"), 0644)
	_ = unsafe.Pointer(ptr)
	_ = reflect.ValueOf(ptr)
}
`
	capFile := filepath.Join(tmpDir, "caps.go")
	if err := os.WriteFile(capFile, []byte(src), 0644); err != nil {
		t.Fatalf("write caps.go: %v", err)
	}

	findings := scanPackageCapabilities(tmpDir, nil, nil)
	if len(findings) == 0 {
		t.Fatalf("expected capability findings, got none")
	}

	foundTypes := make(map[string]Finding)
	for _, f := range findings {
		if f.Kind != "capability" {
			t.Errorf("expected Kind 'capability', got %q", f.Kind)
		}
		if f.Severity != 3 {
			t.Errorf("expected Severity 3, got %d", f.Severity)
		}
		parts := strings.SplitN(f.ID, ":", 2)
		foundTypes[parts[0]] = f
	}

	requiredCaps := []string{
		CapabilityNetwork,
		CapabilityExec,
		CapabilityFilesystem,
		CapabilityUnsafe,
		CapabilityReflect,
	}

	for _, req := range requiredCaps {
		f, ok := foundTypes[req]
		if !ok {
			t.Errorf("missing expected capability %q in findings: %+v", req, findings)
			continue
		}
		if f.RelFile != "caps.go" {
			t.Errorf("capability %s: expected RelFile 'caps.go', got %q", req, f.RelFile)
		}
		if f.Title == "" || f.Detail == "" {
			t.Errorf("capability %s: expected non-empty Title and Detail, got %+v", req, f)
		}
		if strings.Contains(f.Title, "[") || strings.Contains(f.Title, "]") {
			t.Errorf("capability %s: user-visible Title should not contain internal bracketed codes: %q", req, f.Title)
		}
	}

	summary := formatSummary(findings)
	if !strings.Contains(summary, "capabilities") {
		t.Errorf("expected formatSummary to mention capabilities, got %q", summary)
	}
}

func TestParseGolangCILintJSON(t *testing.T) {
	workspaceDir := "/workspace/project"
	sample := `{"Issues":[{"FromLinter":"errcheck","Text":"Error return value of os.Remove is not checked","Pos":{"Filename":"pkg/clean.go","Line":18,"Column":5}}]}`

	findings := parseGolangCILintJSON(workspaceDir, []byte(sample))
	if len(findings) != 1 {
		t.Fatalf("expected 1 finding from golangci-lint JSON, got %d", len(findings))
	}
	got := findings[0]
	if got.Kind != "hazard" || got.Severity != 2 {
		t.Errorf("unexpected kind/severity: %+v", got)
	}
	if got.Title != "[golangci-lint] errcheck" {
		t.Errorf("unexpected Title: %q", got.Title)
	}
	if got.RelFile != "pkg/clean.go" || got.Line != 18 || got.Col != 5 {
		t.Errorf("unexpected location: %s:%d:%d", got.RelFile, got.Line, got.Col)
	}
}
