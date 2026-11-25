package core_e2e

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"golens/core/dap"
	"golens/core/testutil"
)

// ============================================================================
// Tier 4 - Real-World Application Scenarios (End-to-End User Workflows)
// ============================================================================

// Scenario 1: Realistic Microservice HTTP API Workflow
func TestTier4_Scenario1_MicroserviceHTTPWorkflow(t *testing.T) {
	serviceSource := `package main

import (
	"encoding/json"
	"net/http"
)

type AuthRequest struct {
	Username string
	Password string
}

type AuthResponse struct {
	Token  string ` + "`json:\"token\"`" + `
	Status string ` + "`json:\"status\"`" + `
}

func registerRoutes(mux *http.ServeMux) {
	mux.HandleFunc("POST /api/v1/auth/login", handleLogin)
}

func handleLogin(w http.ResponseWriter, r *http.Request) {
	var req AuthRequest
	_ = json.NewDecoder(r.Body).Decode(&req)
}
`
	// Step 1: Route discovery & Code Lens inference
	routes, err := ScanHTTPRoutes(serviceSource)
	if err != nil {
		t.Fatalf("Route scan failed: %v", err)
	}
	if len(routes) != 1 {
		t.Fatalf("Expected 1 route lens, got %d", len(routes))
	}
	if routes[0].Method != "POST" || routes[0].Path != "/api/v1/auth/login" {
		t.Errorf("Route mismatch: %s %s", routes[0].Method, routes[0].Path)
	}
	if !strings.Contains(routes[0].SampleRequestBodyJSON, `"username": "sample_username"`) {
		t.Errorf("Sample JSON body not properly inferred: %s", routes[0].SampleRequestBodyJSON)
	}

	// Step 2: Start local endpoint and execute request via exerciser
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"status":"authorized","token":"jwt-golens-secret-xyz"}`))
	}))
	defer server.Close()

	res, err := ExecuteLocalHTTPRequest(server.URL+"/api/v1/auth/login", "POST", map[string]string{
		"Content-Type": "application/json",
	}, routes[0].SampleRequestBodyJSON, 2*time.Second)
	if err != nil {
		t.Fatalf("Local HTTP execution failed: %v", err)
	}
	if res.StatusCode != 200 {
		t.Errorf("Status = %d; want 200", res.StatusCode)
	}

	// Step 3: Inspect response body in Debugger Raw Variable Inspector
	ins := dap.InspectRawVariablePayload("string", res.Body)
	if !strings.Contains(ins.Text, "jwt-golens-secret-xyz") {
		t.Errorf("Text payload missing token: %s", ins.Text)
	}
	if !strings.Contains(ins.JSON, "{\n  \"status\": \"authorized\",\n  \"token\": \"jwt-golens-secret-xyz\"\n}") {
		t.Errorf("Pretty JSON mismatch: %s", ins.JSON)
	}

	// Step 4: Verify streamlined menu retains JSON/Struct AST generators and prunes modal safety inspector bloat
	menu := GetReorganizedMenuHierarchy()
	if _, hasLegacyBloat := menu.InspectSubmenus["HTTP, Network & SQL"]; hasLegacyBloat {
		t.Fatalf("Legacy 'HTTP, Network & SQL' modal inspector submenu must be pruned in favor of inline AST quick fixes")
	}
	structActions, ok := menu.GenerateSubmenus["Structs & Constructors"]
	if !ok || len(structActions) == 0 {
		t.Fatalf("Structs & Constructors generate group missing or empty")
	}
}

// Scenario 2: Concurrent Pipeline Debugging & Contention Bottleneck Hunting
func TestTier4_Scenario2_ConcurrentPipelineContentionBottleneckHunting(t *testing.T) {
	// Step 1: Profiler collects contention profile from live pipeline
	profileLines := []string{
		"18000000 95 @ pipeline/queue.go:35 pipeline/worker.go:120",
		"4000000  20 @ pipeline/mutex.go:15 pipeline/worker.go:88",
	}
	samples := ParseContentionLines(profileLines)
	if len(samples) != 2 {
		t.Fatalf("Expected 2 contention samples, got %d", len(samples))
	}
	top := samples[0]
	if top.DelayMs != 18.0 || top.File != "pipeline/queue.go" || top.Line != 35 {
		t.Errorf("Top bottleneck mismatch: %s:%d (delay=%f)", top.File, top.Line, top.DelayMs)
	}

	// Step 2: Correlate with Execution Trace Timeline
	traceEvents := `
G 10 Running 0 1000
G 20 Blocked 1000 19000 Channel 10 pipeline/queue.go:35
G 10 Running 19000 20000
`
	lanes, edges, err := ParseExecutionTraceData(strings.NewReader(traceEvents))
	if err != nil {
		t.Fatalf("Trace parse failed: %v", err)
	}
	if len(lanes) != 2 || len(edges) != 1 {
		t.Fatalf("Trace lanes/edges mismatch: %d lanes, %d edges", len(lanes), len(edges))
	}
	if edges[0].FromG != 10 || edges[0].ToG != 20 {
		t.Errorf("Causation link mismatch: from G%d to G%d", edges[0].FromG, edges[0].ToG)
	}
	if edges[0].File != top.File || edges[0].Line != top.Line {
		t.Errorf("Trace unblock location does not match top profile bottleneck: %s:%d vs %s:%d",
			edges[0].File, edges[0].Line, top.File, top.Line)
	}

	// Step 3: Inspect pipeline control variables in Delve DAP
	queueLen := dap.Readable("sync/atomic.Int64", "sync/atomic.Int64 {v: 1500}")
	if queueLen != "atomic.Int64(1500)" {
		t.Errorf("Queue length format = %q; want atomic.Int64(1500)", queueLen)
	}
	isDraining := dap.Readable("sync/atomic.Bool", "sync/atomic.Bool {v: 0}")
	if isDraining != "atomic.Bool(false)" {
		t.Errorf("Draining flag format = %q; want atomic.Bool(false)", isDraining)
	}
}

// Scenario 3: Cross-File Signature Refactoring & Auto-Test Workflow
func TestTier4_Scenario3_CrossFileRefactoringAndAutoTestOnSave(t *testing.T) {
	files := map[string]string{
		"model.go": `package app

type UserConfig struct {
	MaxRetries int
}
`,
		"service.go": `package app

func ApplyConfig(cfg UserConfig) int {
	return cfg.MaxRetries
}
`,
		"handler.go": `package app

func Handle(cfg UserConfig) int {
	return ApplyConfig(cfg)
}
`,
	}

	// Step 1: Find References hits UserConfig across 3 files
	locs := []MatchLocation{
		{FilePath: "model.go", Line: 3},
		{FilePath: "service.go", Line: 3},
		{FilePath: "handler.go", Line: 3},
	}
	excerpts := BuildMultiBufferExcerpts(files, locs, 0)
	if len(excerpts) != 3 {
		t.Fatalf("Expected 3 excerpts across 3 files, got %d", len(excerpts))
	}

	// Step 2: User refactors UserConfig -> AppConfig in MultiBuffer editor
	for i := range excerpts {
		excerpts[i].Lines = strings.ReplaceAll(excerpts[i].Lines, "UserConfig", "AppConfig")
	}
	updated, undoSnapshot, err := ApplyMultiBufferEdits(files, excerpts)
	if err != nil {
		t.Fatalf("ApplyMultiBufferEdits failed: %v", err)
	}
	for f, content := range updated {
		if !strings.Contains(content, "AppConfig") {
			t.Errorf("File %s does not contain refactored AppConfig: %s", f, content)
		}
	}

	// Step 3: Auto-test on save debounced trigger
	debouncer := NewAutoTestDebouncer(50 * time.Millisecond)
	ranTest := false
	debouncer.Trigger(func() { ranTest = true })
	if !ranTest {
		t.Fatalf("Auto-test failed to trigger on file save")
	}

	// Step 4: Test failure occurs and is parsed into Got vs Want diff
	testOutput := []string{
		"=== RUN   TestHandlerConfig",
		"    handler_test.go:40: got 0, want 5",
		"--- FAIL: TestHandlerConfig (0.01s)",
	}
	ann := testutil.ParseTestFailureLocations("", "TestHandlerConfig", testOutput)
	if len(ann) != 1 || ann[0].Got != "0" || ann[0].Want != "5" {
		t.Fatalf("Failure diff capsule incorrect: %+v", ann)
	}

	// Step 5: Counterpart split resolves handler_test.go -> handler.go
	counterpart, isTest := ResolveCounterpart("handler_test.go")
	if counterpart != "handler.go" || isTest {
		t.Errorf("Counterpart resolution failed: got %s, isTest=%v", counterpart, isTest)
	}

	// Step 6: 1-step undo snapshot safely restores original files
	reverted, _, err := ApplyMultiBufferEdits(updated, undoSnapshot)
	if err != nil {
		t.Fatalf("Revert failed: %v", err)
	}
	for f, content := range reverted {
		if !strings.Contains(content, "UserConfig") {
			t.Errorf("Reverted file %s did not restore original UserConfig: %s", f, content)
		}
	}
}

// Scenario 4: Hot-Path Loop Optimization & Assembly Inspection
func TestTier4_Scenario4_HotPathLoopOptimizationAndDisassembly(t *testing.T) {
	ws := CreateTestWorkspace(t, map[string]string{
		"go.mod": "module hotpath\ngo 1.25.1\n",
		"compute.go": `package main

//go:noinline
func ProcessBuffer(buf []byte) int {
	sum := 0
	_ = buf[len(buf)-1] // BCE optimization hint
	for i := 0; i < len(buf); i++ {
		sum += int(buf[i])
	}
	return sum
}

func main() {
	b := []byte{1, 2, 3, 4, 5}
	println(ProcessBuffer(b))
}
`,
		"compute_test.go": `package main

import "testing"

func TestProcessBuffer(t *testing.T) {
	b := []byte{1, 2, 3, 4, 5}
	if ProcessBuffer(b) != 15 {
		t.Fail()
	}
}
`,
	})

	// Step 1: Compiler optimization analysis flags BCE and Inlining
	decisions, err := RunCompilerSSAAnalysis(ws)
	if err != nil {
		t.Fatalf("Compiler SSA analysis failed: %v", err)
	}
	_ = decisions // Output parsed successfully

	// Step 2: Live disassembly maps instructions to source lines
	disasm, err := DisassembleFunction(ws, "ProcessBuffer", "arm64")
	if err != nil {
		t.Fatalf("DisassembleFunction failed: %v", err)
	}
	if len(disasm.Instructions) == 0 {
		t.Fatalf("Expected disassembled instructions for ProcessBuffer")
	}

	// Step 3: Counterpart function navigation matches ProcessBuffer -> TestProcessBuffer
	srcContent, _ := os.ReadFile(ws + "/compute.go")
	testContent, _ := os.ReadFile(ws + "/compute_test.go")
	fnName, line, found := FindMatchingTestFunction(string(srcContent), string(testContent), 5)
	if !found || fnName != "TestProcessBuffer" || line < 1 {
		t.Errorf("Counterpart sync failed: %s at %d (found=%v)", fnName, line, found)
	}
}

// Scenario 5: Full Delve Debugging & Visual Diff Diagnosis Session
func TestTier4_Scenario5_FullDelveDebuggingAndVisualDiffDiagnosis(t *testing.T) {
	// Step 1: Developer inspects complex Delve variable state at breakpoint
	nowVal := uint64(1<<63) | (uint64(5000) << 30) | uint64(987654321)
	timeStr := dap.Readable("time.Time", fmt.Sprintf("time.Time {wall: %d, ext: 200, loc: nil}", nowVal))
	if timeStr == "" || strings.Contains(timeStr, "wall:") {
		t.Errorf("Readable time invalid: %s", timeStr)
	}

	sqlNull := dap.Readable("database/sql.NullString", `database/sql.NullString {String: "active_session", Valid: true}`)
	if sqlNull != "active_session" {
		t.Errorf("SQL NullString = %q; want active_session", sqlNull)
	}

	urlObj := dap.Readable("url.URL", `url.URL {Scheme: "https", Host: "auth.golens.local", Path: "/oauth/token", RawQuery: "scope=read", Fragment: ""}`)
	if urlObj != `url.URL("https://auth.golens.local/oauth/token?scope=read")` {
		t.Errorf("URL format = %q", urlObj)
	}

	// Step 2: Raw payload inspector on response bytes
	payloadData := `[123, 34, 117, 115, 101, 114, 73, 100, 34, 58, 34, 85, 45, 49, 48, 48, 49, 34, 125]` // `{"userId":"U-1001"}`
	ins := dap.InspectRawVariablePayload("[]byte", payloadData)
	if ins.Length != 19 || !strings.Contains(ins.Text, `{"userId":"U-1001"}`) {
		t.Errorf("Payload inspection text incorrect: %+v", ins)
	}
	if !strings.Contains(ins.HexDump, "7b 22 75 73 65 72 49 64") {
		t.Errorf("Hex dump incorrect: %s", ins.HexDump)
	}

	// Step 3: Parse test failure capsule with testify diff
	failureOutput := []string{
		"=== RUN   TestUserPermissions",
		"    perm_test.go:55:",
		"        \tError:      \tNot equal:",
		"        \t            \texpected: \"ROLE_ADMIN\"",
		"        \t            \tactual  : \"ROLE_GUEST\"",
		"--- FAIL: TestUserPermissions (0.01s)",
	}
	ann := testutil.ParseTestFailureLocations("", "TestUserPermissions", failureOutput)
	if len(ann) != 1 {
		t.Fatalf("Expected 1 test failure annotation, got %d", len(ann))
	}
	if ann[0].Want != `"ROLE_ADMIN"` || ann[0].Got != `"ROLE_GUEST"` {
		t.Errorf("Failure Got/Want mismatch: got %s, want %s", ann[0].Got, ann[0].Want)
	}
	if len(ann[0].DiffLines) == 0 {
		t.Errorf("DiffLines empty for testify failure")
	}
}
