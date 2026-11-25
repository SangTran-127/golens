package core_e2e

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"golens/core/dap"
	"golens/core/testutil"
)

// ============================================================================
// Tier 3 - Cross-Feature Combinations (Pairwise Interaction Tests)
// ============================================================================

// 1. Test Failure Diff (Track 45.3) + Counterpart Split (Track 46.3)
func TestTier3_Pair1_FailureDiff_And_CounterpartSplit(t *testing.T) {
	testOutput := []string{
		"=== RUN   TestComputeScore",
		"    scorer_test.go:28: got 85, want 100",
		"--- FAIL: TestComputeScore (0.01s)",
	}

	ann := testutil.ParseTestFailureLocations("", "TestComputeScore", testOutput)
	if len(ann) != 1 {
		t.Fatalf("Expected 1 test failure annotation, got %d", len(ann))
	}

	// Resolve counterpart from test file back to production source
	prodFile, isTest := ResolveCounterpart(ann[0].File)
	if isTest || prodFile != "scorer.go" {
		t.Errorf("Counterpart resolution failed: got %s (isTest=%v); want scorer.go, false", prodFile, isTest)
	}

	// Synchronize caret from test failure back to production function
	prodSrc := `package score

func ComputeScore(base, bonus int) int {
	return base + bonus
}
`
	testSrc := `package score

import "testing"

func TestComputeScore(t *testing.T) {
	if ComputeScore(80, 5) != 100 { t.Fail() }
}
`
	// Match function
	fnName, line, found := FindMatchingTestFunction(prodSrc, testSrc, 3)
	if !found || fnName != "TestComputeScore" || line != 5 {
		t.Errorf("Function sync between counterpart files failed: got %s:%d, want TestComputeScore:5", fnName, line)
	}
}

// 2. Contention Profile (Track 45.2) + Live Disassembly (Track 46.1)
func TestTier3_Pair2_ContentionProfile_And_LiveDisassembly(t *testing.T) {
	lines := []string{
		"8000000 24 @ server.go:14 worker.go:50",
	}
	samples := ParseContentionLines(lines)
	if len(samples) != 1 {
		t.Fatalf("Expected 1 contention sample, got %d", len(samples))
	}
	if samples[0].File != "server.go" || samples[0].Line != 14 {
		t.Errorf("Contention location mismatch: %s:%d", samples[0].File, samples[0].Line)
	}

	// Verify disassembly mapping on that line
	ws := CreateTestWorkspace(t, map[string]string{
		"go.mod": "module testcontdisasm\ngo 1.25.1\n",
		"main.go": `package main

import "sync"

var mu sync.Mutex

//go:noinline
func CriticalSection() {
	mu.Lock()
	defer mu.Unlock()
}

func main() {
	CriticalSection()
}
`,
	})

	disasm, err := DisassembleFunction(ws, "CriticalSection", "arm64")
	if err != nil {
		t.Fatalf("DisassembleFunction failed: %v", err)
	}
	if len(disasm.Instructions) == 0 {
		t.Fatalf("Expected instructions in CriticalSection")
	}

	// Verify Lock call exists in disassembly
	foundCall := false
	for _, inst := range disasm.Instructions {
		if strings.Contains(inst.Operands, "Lock") || strings.Contains(inst.Mnemonic, "BL") || strings.Contains(inst.Mnemonic, "CALL") {
			foundCall = true
			break
		}
	}
	if !foundCall {
		t.Errorf("CriticalSection disassembly missing Lock call instruction: %+v", disasm.Instructions)
	}
}

// 3. Multi-Buffer Refactor (Track 47.2) + AST Quick-Fix (Track 46.2)
func TestTier3_Pair3_MultiBufferRefactor_And_ASTQuickFix(t *testing.T) {
	fileA := `package main

import (
	"context"
	"time"
)

func WorkerA() {
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	_ = ctx
}
`
	fileB := `package main

import (
	"context"
	"time"
)

func WorkerB() {
	ctx, cancel := context.WithCancel(context.Background())
	_ = ctx
}
`
	fixesA, errA := ScanContextualASTQuickFixes("worker_a.go", fileA, 9)
	fixesB, errB := ScanContextualASTQuickFixes("worker_b.go", fileB, 9)
	if errA != nil || errB != nil || len(fixesA) == 0 || len(fixesB) == 0 {
		t.Fatalf("Failed to scan fixes in WorkerA or WorkerB: %v, %v", errA, errB)
	}

	files := map[string]string{
		"worker_a.go": fileA,
		"worker_b.go": fileB,
	}

	locs := []MatchLocation{
		{FilePath: "worker_a.go", Line: 9},
		{FilePath: "worker_b.go", Line: 9},
	}
	excerpts := BuildMultiBufferExcerpts(files, locs, 0)
	if len(excerpts) != 2 {
		t.Fatalf("Expected 2 excerpts across both files, got %d", len(excerpts))
	}

	// Apply AST quick fixes into excerpts
	for i := range excerpts {
		if excerpts[i].FilePath == "worker_a.go" {
			excerpts[i].Lines = fixesA[0].NewText
		} else if excerpts[i].FilePath == "worker_b.go" {
			excerpts[i].Lines = fixesB[0].NewText
		}
	}

	updated, _, err := ApplyMultiBufferEdits(files, excerpts)
	if err != nil {
		t.Fatalf("Multi-buffer batch fix apply failed: %v", err)
	}
	if !strings.Contains(updated["worker_a.go"], "defer cancel()") || !strings.Contains(updated["worker_b.go"], "defer cancel()") {
		t.Errorf("Batch AST quick-fix failed to update both files properly: %+v", updated)
	}
}

// 4. HTTP Route Exerciser (Track 47.3) + Debugger Payload Inspector (Track 45.1)
func TestTier3_Pair4_HTTPRouteExerciser_And_DebuggerPayloadInspector(t *testing.T) {
	// Start mock HTTP server
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusCreated)
		_, _ = w.Write([]byte(`{"orderId": "ORD-9912", "amount": 250.50, "status": "confirmed"}`))
	}))
	defer ts.Close()

	// Execute HTTP request via exerciser
	res, err := ExecuteLocalHTTPRequest(ts.URL+"/api/v1/orders", "POST", map[string]string{"Content-Type": "application/json"}, "{}", 2*time.Second)
	if err != nil {
		t.Fatalf("HTTP exerciser failed: %v", err)
	}
	if res.StatusCode != 201 {
		t.Errorf("StatusCode = %d; want 201", res.StatusCode)
	}

	// Feed response body into DAP Raw Variable Payload Inspector
	ins := dap.InspectRawVariablePayload("string", res.Body)
	if !strings.Contains(ins.Text, "ORD-9912") {
		t.Errorf("Text payload missing orderId: %q", ins.Text)
	}
	if !strings.Contains(ins.JSON, "{\n  \"amount\": 250.5,\n  \"orderId\": \"ORD-9912\",\n  \"status\": \"confirmed\"\n}") &&
		!strings.Contains(ins.JSON, "\"orderId\": \"ORD-9912\"") {
		t.Errorf("Formatted JSON invalid: %s", ins.JSON)
	}
	if !strings.Contains(ins.HexDump, "7b 22 6f 72 64 65 72 49") {
		t.Errorf("Hex dump missing JSON byte header: %s", ins.HexDump)
	}
}

// 5. Execution Trace Timeline (Track 47.1) + Contention Profiler (Track 45.2)
func TestTier3_Pair5_ExecutionTraceTimeline_And_ContentionProfiler(t *testing.T) {
	traceData := `
G 1 Running 0 1000
G 2 Blocked 1000 6000 Channel 1 queue.go:35
G 1 Running 6000 7000
`
	lanes, edges, err := ParseExecutionTraceData(strings.NewReader(traceData))
	if err != nil {
		t.Fatalf("Parse trace failed: %v", err)
	}
	if len(lanes) != 2 || len(edges) != 1 {
		t.Fatalf("Expected 2 lanes and 1 edge, got %d, %d", len(lanes), len(edges))
	}

	// Correlate with BlockProfile entry
	profileLines := []string{
		"5000000 1 @ queue.go:35 worker.go:80",
	}
	samples := ParseContentionLines(profileLines)
	if len(samples) != 1 {
		t.Fatalf("Expected 1 contention sample, got %d", len(samples))
	}

	// Verification: trace unblock edge location matches block profile contention location
	if edges[0].File != samples[0].File || edges[0].Line != samples[0].Line {
		t.Errorf("Trace unblock location (%s:%d) does not match profile contention (%s:%d)",
			edges[0].File, edges[0].Line, samples[0].File, samples[0].Line)
	}
	// Total delay should match span duration (6000 - 1000 = 5000ns)
	if samples[0].DelayNs != 5000000 {
		t.Errorf("Contention delay = %d; want 5000000", samples[0].DelayNs)
	}
}

// 6. Compiler SSA BCE Analysis (Track 46.1) + Counterpart Test (Track 46.3)
func TestTier3_Pair6_CompilerBCEAnalysis_And_CounterpartTest(t *testing.T) {
	compilerOut := `
matrix.go:20:15: Found IsInBounds
`
	decisions := ParseCompilerOptimizationOutput(compilerOut)
	if len(decisions) != 1 || decisions[0].Category != "bce_check" {
		t.Fatalf("BCE check not detected properly")
	}

	// Check counterpart test file for matrix.go
	counterpart, isTest := ResolveCounterpart("matrix.go")
	if counterpart != "matrix_test.go" || !isTest {
		t.Errorf("Counterpart resolution failed: %s, %v", counterpart, isTest)
	}

	matrixSrc := `package matrix

func At(matrix []int, idx int) int {
	return matrix[idx]
}
`
	testSrc := `package matrix

import "testing"

func TestAt(t *testing.T) {
	s := []int{10, 20, 30}
	if At(s, 1) != 20 { t.Fail() }
}
`
	name, line, found := FindMatchingTestFunction(matrixSrc, testSrc, 3)
	if !found || name != "TestAt" || line != 5 {
		t.Errorf("Counterpart test sync failed: %s at %d", name, line)
	}
}

// 7. AST Quick-Fix (Track 46.2) + HTTP Route Handler (Track 47.3)
func TestTier3_Pair7_ASTQuickFix_And_HTTPRouteHandler(t *testing.T) {
	src := `package main

import "net/http"

func setup() {
	mux := http.NewServeMux()
	mux.HandleFunc("POST /api/v1/sync", handleSync)
}

func handleSync(w http.ResponseWriter, r *http.Request) {
	resp, err := http.Get("https://remote.internal/data")
	_ = resp
	_ = err
}
`
	routes, err := ScanHTTPRoutes(src)
	if err != nil || len(routes) != 1 {
		t.Fatalf("Expected 1 route, got %d (%v)", len(routes), err)
	}
	if routes[0].Path != "/api/v1/sync" {
		t.Errorf("Route mismatch: %s", routes[0].Path)
	}

	// Line 11 is `resp, err := http.Get(...)`
	fixes, err := ScanContextualASTQuickFixes("handler.go", src, 11)
	if err != nil || len(fixes) == 0 {
		t.Fatalf("Expected AST quick fix on route handler HTTP call, got none: %v", err)
	}
	if !strings.Contains(fixes[0].Title, "defer resp.Body.Close()") {
		t.Errorf("Expected defer resp.Body.Close() fix, got %q", fixes[0].Title)
	}
}

// 8. Test Failure Diff (Track 45.3) + Multi-Buffer Editor (Track 47.2)
func TestTier3_Pair8_TestFailureDiff_And_MultiBufferEditor(t *testing.T) {
	output := []string{
		"=== RUN   TestCalculations",
		"    calc_test.go:5: got 42, want 100",
		"    calc_test.go:12: got 500, want 1000",
		"--- FAIL: TestCalculations (0.01s)",
	}
	ann := testutil.ParseTestFailureLocations("", "TestCalculations", output)
	if len(ann) != 2 {
		t.Fatalf("Expected 2 failure annotations, got %d", len(ann))
	}

	files := map[string]string{
		"calc_test.go": `package main

import "testing"

func TestCalculations(t *testing.T) {
	wantA := 42
	// comment 7
	// comment 8
	// comment 9
	// comment 10
	// comment 11
	wantB := 500
}
`,
	}

	locs := []MatchLocation{
		{FilePath: "calc_test.go", Line: ann[0].Line},
		{FilePath: "calc_test.go", Line: ann[1].Line},
	}
	excerpts := BuildMultiBufferExcerpts(files, locs, 0)
	if len(excerpts) != 2 {
		t.Fatalf("Expected 2 excerpts for lines separated by >3 lines, got %d", len(excerpts))
	}

	// Update expected values in multi-buffer
	excerpts[0].Lines = "\twantA := 100"
	excerpts[1].Lines = "\twantB := 1000"

	updated, _, err := ApplyMultiBufferEdits(files, excerpts)
	if err != nil {
		t.Fatalf("ApplyMultiBufferEdits failed: %v", err)
	}
	if !strings.Contains(updated["calc_test.go"], "wantA := 100") || !strings.Contains(updated["calc_test.go"], "wantB := 1000") {
		t.Errorf("Multi-buffer did not update test expected values properly: %s", updated["calc_test.go"])
	}
}

// 9. Debugger Value Rendering (Track 45.1) + Trace Timeline (Track 47.1)
func TestTier3_Pair9_DebuggerReadableValue_And_TraceTimeline(t *testing.T) {
	traceData := `
G 10 Blocked 1000 2500 Mutex 5 mutex_sync.go:44
`
	lanes, _, err := ParseExecutionTraceData(strings.NewReader(traceData))
	if err != nil || len(lanes) != 1 {
		t.Fatalf("Trace parsing failed: %v", err)
	}

	// Inspect the atomic lock variable value that held the mutex
	atomicState := "sync/atomic.Int64 {v: 1}"
	readable := dap.Readable("sync/atomic.Int64", atomicState)
	if readable != "atomic.Int64(1)" {
		t.Errorf("Readable atomic lock state = %q; want atomic.Int64(1)", readable)
	}

	// Inspect sql.NullString variable in the holding frame
	sqlState := `sql.NullString {String: "locked_by_g5", Valid: true}`
	if got := dap.Readable("sql.NullString", sqlState); got != "locked_by_g5" {
		t.Errorf("Readable sql.NullString = %q; want locked_by_g5", got)
	}
}
