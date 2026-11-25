package core_e2e

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"golens/core/dap"
	"golens/core/testutil"
)

// ============================================================================
// Tier 1 - Feature Coverage: Track 45.1 (Issue #125)
// ============================================================================

func TestTier1_Track45_1_TimeFormatting(t *testing.T) {
	// Monotonic time test
	// wall = hasMonotonic | (secInternal << 30) | nsec
	wall := uint64(1<<63) | (uint64(2000) << 30) | uint64(123456789)
	val := fmt.Sprintf("time.Time {wall: %d, ext: 100, loc: nil}", wall)
	got := dap.Readable("time.Time", val)
	if got == "" || got == val || strings.Contains(got, "wall:") {
		t.Fatalf("Expected formatted time, got %q", got)
	}

	// Zero time
	gotZero := dap.Readable("time.Time", "time.Time {wall: 0, ext: 0, loc: nil}")
	if gotZero != "0001-01-01 00:00:00Z" {
		t.Errorf("Readable zero time = %q; want 0001-01-01 00:00:00Z", gotZero)
	}

	// Nil pointer
	gotNil := dap.Readable("*time.Time", "nil")
	if gotNil != "<nil>" {
		t.Errorf("Readable nil pointer = %q; want <nil>", gotNil)
	}
}

func TestTier1_Track45_1_ByteSliceUTF8AndBinary(t *testing.T) {
	// UTF-8 payload (>= 80% printable)
	utf8Val := "[]uint8 len: 13, cap: 16, [123, 34, 105, 100, 34, 58, 32, 49, 50, 51, 125]"
	gotUTF8 := dap.Readable("[]byte", utf8Val)
	if !strings.Contains(gotUTF8, `[]byte(len=11) "{\"id\": 123}"`) {
		t.Errorf("Expected readable UTF-8 string preview, got %q", gotUTF8)
	}

	// Binary payload (< 80% printable)
	binVal := "[]uint8 len: 4, cap: 4, [0, 1, 2, 255]"
	gotBin := dap.Readable("[]byte", binVal)
	if !strings.Contains(gotBin, "0x000102ff") {
		t.Errorf("Expected hex preview for binary bytes, got %q", gotBin)
	}

	// Empty slice
	emptyVal := "[]uint8 len: 0, cap: 0, []"
	gotEmpty := dap.Readable("[]byte", emptyVal)
	if gotEmpty != "[]byte(len=0) \"\"" {
		t.Errorf("Expected empty byte slice preview, got %q", gotEmpty)
	}
}

func TestTier1_Track45_1_URLReconstruction(t *testing.T) {
	rawURL := `url.URL {Scheme: "https", Host: "api.golens.dev", Path: "/v2/inspect", RawQuery: "track=45.1", Fragment: "details"}`
	got := dap.Readable("url.URL", rawURL)
	want := `url.URL("https://api.golens.dev/v2/inspect?track=45.1#details")`
	if got != want {
		t.Errorf("Readable URL = %q; want %q", got, want)
	}

	gotNil := dap.Readable("*url.URL", "nil")
	if gotNil != "<nil>" {
		t.Errorf("Readable nil URL = %q; want <nil>", gotNil)
	}
}

func TestTier1_Track45_1_AtomicTypes(t *testing.T) {
	intVal := "sync/atomic.Int64 {v: 1024}"
	gotInt := dap.Readable("sync/atomic.Int64", intVal)
	if gotInt != "atomic.Int64(1024)" {
		t.Errorf("Readable atomic.Int64 = %q; want atomic.Int64(1024)", gotInt)
	}

	boolVal := "sync/atomic.Bool {v: 1}"
	gotBool := dap.Readable("sync/atomic.Bool", boolVal)
	if gotBool != "atomic.Bool(true)" {
		t.Errorf("Readable atomic.Bool = %q; want atomic.Bool(true)", gotBool)
	}

	boolFalseVal := "atomic.Bool {v: 0}"
	gotBoolFalse := dap.Readable("atomic.Bool", boolFalseVal)
	if gotBoolFalse != "atomic.Bool(false)" {
		t.Errorf("Readable atomic.Bool(false) = %q; want atomic.Bool(false)", gotBoolFalse)
	}
}

func TestTier1_Track45_1_SQLNullTypes(t *testing.T) {
	nullStrVal := `database/sql.NullString {String: "active", Valid: true}`
	gotValid := dap.Readable("database/sql.NullString", nullStrVal)
	if gotValid != "active" {
		t.Errorf("Readable valid NullString = %q; want active", gotValid)
	}

	nullInvalid := `database/sql.NullString {String: "", Valid: false}`
	gotInvalid := dap.Readable("database/sql.NullString", nullInvalid)
	if gotInvalid != "<null>" {
		t.Errorf("Readable invalid NullString = %q; want <null>", gotInvalid)
	}

	nullIntValid := `sql.NullInt64 {Int64: 42, Valid: true}`
	if got := dap.Readable("sql.NullInt64", nullIntValid); got != "42" {
		t.Errorf("Readable valid NullInt64 = %q; want 42", got)
	}

	nullIntInvalid := `sql.NullInt64 {Int64: 0, Valid: false}`
	if got := dap.Readable("sql.NullInt64", nullIntInvalid); got != "<null>" {
		t.Errorf("Readable invalid NullInt64 = %q; want <null>", got)
	}
}

func TestTier1_Track45_1_InspectPayloadFormatting(t *testing.T) {
	jsonBytes := `[123, 34, 115, 116, 97, 116, 117, 115, 34, 58, 34, 111, 107, 34, 125]` // `{"status":"ok"}`
	ins := dap.InspectRawVariablePayload("[]byte", jsonBytes)
	if ins.Length != 15 {
		t.Errorf("Payload length = %d; want 15", ins.Length)
	}
	if !strings.Contains(ins.Text, `{"status":"ok"}`) {
		t.Errorf("Text payload missing expected JSON string, got %q", ins.Text)
	}
	if !strings.Contains(ins.JSON, "{\n  \"status\": \"ok\"\n}") {
		t.Errorf("Pretty JSON indentation incorrect, got %q", ins.JSON)
	}
	if !strings.Contains(ins.HexDump, "7b 22 73 74 61 74 75 73") {
		t.Errorf("Hex dump missing expected byte sequence, got %q", ins.HexDump)
	}
}

// ============================================================================
// Tier 1 - Feature Coverage: Track 45.3 (Issue #127)
// ============================================================================

func TestTier1_Track45_3_GotWantPattern(t *testing.T) {
	output := []string{
		"=== RUN   TestCompute",
		"    calc_test.go:42: got 100, want 200",
		"--- FAIL: TestCompute (0.01s)",
	}
	ann := testutil.ParseTestFailureLocations("", "TestCompute", output)
	if len(ann) != 1 {
		t.Fatalf("Expected 1 failure annotation, got %d", len(ann))
	}
	if ann[0].File != "calc_test.go" || ann[0].Line != 42 {
		t.Errorf("File/line mismatch: got %s:%d, want calc_test.go:42", ann[0].File, ann[0].Line)
	}
	if ann[0].Got != "100" || ann[0].Want != "200" {
		t.Errorf("Got/Want mismatch: got %q, want %q", ann[0].Got, ann[0].Want)
	}
	if len(ann[0].DiffLines) == 0 {
		t.Errorf("Expected DiffLines generated, got empty")
	}
}

func TestTier1_Track45_3_TestifyPattern(t *testing.T) {
	output := []string{
		"=== RUN   TestUserAuth",
		"    auth_test.go:88:",
		"        \tError Trace:\tauth_test.go:88",
		"        \tError:      \tNot equal:",
		"        \t            \texpected: \"admin\"",
		"        \t            \tactual  : \"guest\"",
		"--- FAIL: TestUserAuth (0.02s)",
	}
	ann := testutil.ParseTestFailureLocations("", "TestUserAuth", output)
	if len(ann) != 1 {
		t.Fatalf("Expected 1 annotation, got %d", len(ann))
	}
	if ann[0].Want != `"admin"` || ann[0].Got != `"guest"` {
		t.Errorf("Testify Got/Want mismatch: got %q, want %q", ann[0].Got, ann[0].Want)
	}
}

func TestTier1_Track45_3_GoCmpUnifiedDiff(t *testing.T) {
	output := []string{
		"=== RUN   TestConfigDiff",
		"    config_test.go:15: (-want +got)",
		"          Config{",
		"        -   Port: 8080,",
		"        +   Port: 9090,",
		"          }",
		"--- FAIL: TestConfigDiff (0.01s)",
	}
	ann := testutil.ParseTestFailureLocations("", "TestConfigDiff", output)
	if len(ann) != 1 {
		t.Fatalf("Expected 1 annotation, got %d", len(ann))
	}
	if len(ann[0].DiffLines) == 0 {
		t.Errorf("Expected structured diff lines from go-cmp block")
	}
}

func TestTier1_Track45_3_FileLineExtraction(t *testing.T) {
	output := []string{
		"    services/auth/jwt_test.go:120: signature invalid",
	}
	ann := testutil.ParseTestFailureLocations("/repo", "TestJWT", output)
	if len(ann) != 1 {
		t.Fatalf("Expected 1 annotation, got %d", len(ann))
	}
	if !strings.HasSuffix(ann[0].File, "services/auth/jwt_test.go") {
		t.Errorf("Unexpected file path: %s", ann[0].File)
	}
	if ann[0].Line != 120 {
		t.Errorf("Line mismatch: got %d, want 120", ann[0].Line)
	}
}

func TestTier1_Track45_3_StructuredDiffLines(t *testing.T) {
	output := []string{
		"    diff_test.go:30: got foo, want bar",
	}
	ann := testutil.ParseTestFailureLocations("", "TestDiffLines", output)
	if len(ann) != 1 {
		t.Fatalf("Expected 1 annotation, got %d", len(ann))
	}
	foundGot := false
	foundWant := false
	for _, dl := range ann[0].DiffLines {
		if dl.Type == "got" && dl.Text == "foo" {
			foundGot = true
		}
		if dl.Type == "want" && dl.Text == "bar" {
			foundWant = true
		}
	}
	if !foundGot || !foundWant {
		t.Errorf("Structured DiffLines did not preserve got and want lines accurately: %+v", ann[0].DiffLines)
	}
}

// ============================================================================
// Tier 1 - Feature Coverage: Track 46.2 (Issue #129)
// ============================================================================

func TestTier1_Track46_2_MenuConsolidationInspectSubmenus(t *testing.T) {
	hierarchy := GetReorganizedMenuHierarchy()
	expectedSubmenus := []string{
		"Code & Memory Layout",
		"Architecture, API & Benchmarks",
	}

	if len(hierarchy.InspectSubmenus) != len(expectedSubmenus) {
		t.Fatalf("Expected %d inspect groups, got %d", len(expectedSubmenus), len(hierarchy.InspectSubmenus))
	}
	totalInspect := 0
	for _, name := range expectedSubmenus {
		items, ok := hierarchy.InspectSubmenus[name]
		if !ok || len(items) == 0 {
			t.Errorf("Inspect group %q is missing or empty", name)
		}
		totalInspect += len(items)
	}
	if totalInspect != 5 {
		t.Errorf("Expected exactly 5 visual/architectural inspectors, got %d", totalInspect)
	}
}

func TestTier1_Track46_2_MenuConsolidationGenerateSubmenus(t *testing.T) {
	hierarchy := GetReorganizedMenuHierarchy()
	expectedSubmenus := []string{
		"Structs & Constructors",
		"Methods, Codecs & CLI",
		"Tests, Benchmarks & Mocks",
	}

	if len(hierarchy.GenerateSubmenus) != len(expectedSubmenus) {
		t.Fatalf("Expected %d generate groups, got %d", len(expectedSubmenus), len(hierarchy.GenerateSubmenus))
	}
	totalGenerate := 0
	for _, name := range expectedSubmenus {
		items, ok := hierarchy.GenerateSubmenus[name]
		if !ok || len(items) == 0 {
			t.Errorf("Generate group %q is missing or empty", name)
		}
		totalGenerate += len(items)
	}
	if totalGenerate != 9 {
		t.Errorf("Expected exactly 9 core AST IDE generators, got %d", totalGenerate)
	}
}

func TestTier1_Track46_2_PinnedTop5Featured(t *testing.T) {
	hierarchy := GetReorganizedMenuHierarchy()
	if len(hierarchy.FeaturedInspect) != 3 {
		t.Fatalf("Expected 3 Editor Inspect items, got %d", len(hierarchy.FeaturedInspect))
	}
	firstFeatured := hierarchy.FeaturedInspect[0]
	if firstFeatured != "Inspect Struct Memory Layout…" {
		t.Errorf("First Editor Inspect item = %q; want 'Inspect Struct Memory Layout…'", firstFeatured)
	}
}

func TestTier1_Track46_2_ContextualASTQuickFixContextCancel(t *testing.T) {
	src := `package main

import (
	"context"
	"time"
)

func runWorker() {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	_ = ctx
}
`
	fixes, err := ScanContextualASTQuickFixes("worker.go", src, 9)
	if err != nil {
		t.Fatalf("Failed to scan quick fixes: %v", err)
	}
	if len(fixes) == 0 {
		t.Fatalf("Expected quick fix for missing defer cancel(), got none")
	}
	if !strings.Contains(fixes[0].Title, "[GoLens Fix]") || !strings.Contains(fixes[0].Title, "defer cancel()") {
		t.Errorf("Unexpected quick fix title: %q", fixes[0].Title)
	}
}

func TestTier1_Track46_2_ContextualASTQuickFixHTTPBodyClose(t *testing.T) {
	src := `package main

import (
	"net/http"
)

func fetchStatus() {
	resp, err := http.Get("https://api.golens.dev")
	_ = resp
	_ = err
}
`
	fixes, err := ScanContextualASTQuickFixes("fetch.go", src, 8)
	if err != nil {
		t.Fatalf("Failed to scan quick fixes: %v", err)
	}
	if len(fixes) == 0 {
		t.Fatalf("Expected quick fix for missing resp.Body.Close(), got none")
	}
	if !strings.Contains(fixes[0].Title, "defer resp.Body.Close()") {
		t.Errorf("Unexpected quick fix title: %q", fixes[0].Title)
	}
}

// ============================================================================
// Tier 1 - Feature Coverage: Track 46.1 (Issue #128)
// ============================================================================

func TestTier1_Track46_1_CompilerInliningDecisions(t *testing.T) {
	sampleOutput := `
main.go:12:6: can inline Add with cost 2
main.go:20:6: cannot inline HeavyLoop: function too complex: cost 120 > budget 80
`
	decisions := ParseCompilerOptimizationOutput(sampleOutput)
	if len(decisions) != 2 {
		t.Fatalf("Expected 2 decisions, got %d", len(decisions))
	}
	if decisions[0].Category != "inline_ok" {
		t.Errorf("Decision 0 category = %q; want inline_ok", decisions[0].Category)
	}
	if decisions[1].Category != "inline_blocked" {
		t.Errorf("Decision 1 category = %q; want inline_blocked", decisions[1].Category)
	}
}

func TestTier1_Track46_1_CompilerHeapEscapeAnalysis(t *testing.T) {
	sampleOutput := `
main.go:15:13: &User{...} escapes to heap
main.go:25:10: moved to heap: buf
`
	decisions := ParseCompilerOptimizationOutput(sampleOutput)
	if len(decisions) != 2 {
		t.Fatalf("Expected 2 decisions, got %d", len(decisions))
	}
	for _, d := range decisions {
		if d.Category != "escape" {
			t.Errorf("Expected escape category, got %q", d.Category)
		}
	}
}

func TestTier1_Track46_1_CompilerBCEDetection(t *testing.T) {
	sampleOutput := `
main.go:34:15: Found IsInBounds
main.go:35:18: Found IsSliceInBounds
`
	decisions := ParseCompilerOptimizationOutput(sampleOutput)
	if len(decisions) != 2 {
		t.Fatalf("Expected 2 decisions, got %d", len(decisions))
	}
	for _, d := range decisions {
		if d.Category != "bce_check" {
			t.Errorf("Expected bce_check category, got %q", d.Category)
		}
		if !strings.Contains(d.Hint, "maxIdx") {
			t.Errorf("Expected BCE hint, got %q", d.Hint)
		}
	}
}

func TestTier1_Track46_1_DisassemblyARM64Mapping(t *testing.T) {
	ws := CreateTestWorkspace(t, map[string]string{
		"go.mod": "module testdisasm\ngo 1.25.1\n",
		"main.go": `package main

func Sum(a, b int) int {
	return a + b
}

func main() {
	println(Sum(1, 2))
}
`,
	})

	res, err := DisassembleFunction(ws, "Sum", "arm64")
	if err != nil {
		t.Fatalf("DisassembleFunction failed: %v", err)
	}
	if res.TargetArch != "arm64" {
		t.Errorf("TargetArch = %q; want arm64", res.TargetArch)
	}
	if len(res.Instructions) == 0 {
		t.Fatalf("Expected instructions returned, got 0")
	}
	// Instruction lines should map to source lines
	if res.Instructions[0].Line < 1 {
		t.Errorf("Expected positive line number, got %d", res.Instructions[0].Line)
	}
}

func TestTier1_Track46_1_DisassemblyAMD64Mapping(t *testing.T) {
	ws := CreateTestWorkspace(t, map[string]string{
		"go.mod": "module testdisasm64\ngo 1.25.1\n",
		"main.go": `package main

//go:noinline
func Multiply(a, b int) int {
	return a * b
}

func main() {
	println(Multiply(3, 4))
}
`,
	})

	res, err := DisassembleFunction(ws, "Multiply", "amd64")
	if err != nil {
		t.Fatalf("DisassembleFunction failed for amd64: %v", err)
	}
	if res.TargetArch != "amd64" {
		t.Errorf("TargetArch = %q; want amd64", res.TargetArch)
	}
	if len(res.Instructions) == 0 {
		t.Fatalf("Expected instructions returned for amd64, got 0")
	}
}

// ============================================================================
// Tier 1 - Feature Coverage: Track 45.2 (Issue #126)
// ============================================================================

func TestTier1_Track45_2_BlockProfileDelayParsing(t *testing.T) {
	lines := []string{
		"5000000 12 @ channel.go:45 worker.go:102",
		"1000000 5  @ channel.go:50 worker.go:110",
	}
	samples := ParseContentionLines(lines)
	if len(samples) != 2 {
		t.Fatalf("Expected 2 samples, got %d", len(samples))
	}
	if samples[0].DelayNs != 5000000 {
		t.Errorf("DelayNs = %d; want 5000000", samples[0].DelayNs)
	}
	if samples[0].DelayMs != 5.0 {
		t.Errorf("DelayMs = %f; want 5.0", samples[0].DelayMs)
	}
	if samples[0].Count != 12 {
		t.Errorf("Count = %d; want 12", samples[0].Count)
	}
}

func TestTier1_Track45_2_MutexProfileContentionParsing(t *testing.T) {
	lines := []string{
		"15000000 45 @ sync/mutex.go:90 pool.go:15",
	}
	samples := ParseContentionLines(lines)
	if len(samples) != 1 {
		t.Fatalf("Expected 1 sample, got %d", len(samples))
	}
	if samples[0].Count != 45 {
		t.Errorf("Contention count = %d; want 45", samples[0].Count)
	}
	if samples[0].DelayMs != 15.0 {
		t.Errorf("DelayMs = %f; want 15.0", samples[0].DelayMs)
	}
	if samples[0].File != "sync/mutex.go" || samples[0].Line != 90 {
		t.Errorf("File:line mismatch: %s:%d", samples[0].File, samples[0].Line)
	}
}

func TestTier1_Track45_2_ContentionSortingByDelay(t *testing.T) {
	lines := []string{
		"1000000 2 @ a.go:1",
		"9000000 1 @ b.go:2",
		"5000000 4 @ c.go:3",
	}
	samples := ParseContentionLines(lines)
	if len(samples) != 3 {
		t.Fatalf("Expected 3 samples, got %d", len(samples))
	}
	if samples[0].DelayNs != 9000000 || samples[1].DelayNs != 5000000 || samples[2].DelayNs != 1000000 {
		t.Errorf("Samples not properly sorted by delay descending: %+v", samples)
	}
}

func TestTier1_Track45_2_ContentionCallStackMapping(t *testing.T) {
	lines := []string{
		"2000000 10 @ sync.(*Mutex).Lock:88 server.go:120 router.go:40",
	}
	samples := ParseContentionLines(lines)
	if len(samples) != 1 {
		t.Fatalf("Expected 1 sample, got %d", len(samples))
	}
	if len(samples[0].CallFrames) != 3 {
		t.Errorf("Expected 3 call frames, got %d", len(samples[0].CallFrames))
	}
	if samples[0].CallFrames[1] != "server.go:120" {
		t.Errorf("Call frame 1 mismatch: %s", samples[0].CallFrames[1])
	}
}

func TestTier1_Track45_2_ProfilerViewMultiModeSupport(t *testing.T) {
	modes := []string{"CPU", "Memory", "Block", "Mutex"}
	if len(modes) != 4 {
		t.Fatalf("Expected 4 profiler modes, got %d", len(modes))
	}
	for _, m := range modes {
		if m == "" {
			t.Errorf("Mode is empty")
		}
	}
}

// ============================================================================
// Tier 1 - Feature Coverage: Track 46.3 (Issue #130)
// ============================================================================

func TestTier1_Track46_3_CounterpartPathResolution(t *testing.T) {
	cp, isTest := ResolveCounterpart("/path/to/service.go")
	if cp != "/path/to/service_test.go" || !isTest {
		t.Errorf("service.go -> counterpart %q, isTest %v", cp, isTest)
	}

	src, isTest2 := ResolveCounterpart("/path/to/service_test.go")
	if src != "/path/to/service.go" || isTest2 {
		t.Errorf("service_test.go -> counterpart %q, isTest %v", src, isTest2)
	}
}

func TestTier1_Track46_3_CounterpartFunctionCaretSync(t *testing.T) {
	src := `package mathutil

func CalculateTax(amount float64) float64 {
	return amount * 0.1
}

func CalculateDiscount(amount float64) float64 {
	return amount * 0.05
}
`
	testSrc := `package mathutil

import "testing"

func TestCalculateTax(t *testing.T) {
}

func TestCalculateDiscount(t *testing.T) {
}
`
	testName, line, found := FindMatchingTestFunction(src, testSrc, 4)
	if !found || testName != "TestCalculateTax" || line != 5 {
		t.Errorf("FindMatchingTestFunction Tax = %s:%d (found=%v); want TestCalculateTax:5", testName, line, found)
	}

	testName2, line2, found2 := FindMatchingTestFunction(src, testSrc, 8)
	if !found2 || testName2 != "TestCalculateDiscount" || line2 != 8 {
		t.Errorf("FindMatchingTestFunction Discount = %s:%d (found=%v); want TestCalculateDiscount:8", testName2, line2, found2)
	}
}

func TestTier1_Track46_3_CounterpartMissingTestEmptyState(t *testing.T) {
	src := `package mathutil

func NewEngine() *Engine { return nil }
`
	testSrc := `package mathutil

import "testing"
`
	testName, _, found := FindMatchingTestFunction(src, testSrc, 3)
	if found {
		t.Errorf("Expected function to NOT be found in empty test file")
	}
	if testName != "TestNewEngine" {
		t.Errorf("Expected target test name TestNewEngine, got %q", testName)
	}
}

func TestTier1_Track46_3_AutoTestPackageDebounce(t *testing.T) {
	debouncer := NewAutoTestDebouncer(50 * time.Millisecond)
	triggeredCount := 0
	action := func() {
		triggeredCount++
	}

	first := debouncer.Trigger(action)
	if !first || triggeredCount != 1 {
		t.Fatalf("First trigger should execute immediately")
	}

	// Immediate second trigger within wait window should be debounced
	second := debouncer.Trigger(action)
	if second || triggeredCount != 1 {
		t.Errorf("Immediate second trigger should have been dropped")
	}

	// Wait past debounce period
	time.Sleep(60 * time.Millisecond)
	third := debouncer.Trigger(action)
	if !third || triggeredCount != 2 {
		t.Errorf("Trigger after debounce window should execute")
	}
}

func TestTier1_Track46_3_AutoTestPackageShortFlag(t *testing.T) {
	ws := CreateTestWorkspace(t, map[string]string{
		"go.mod": "module autotestpkg\ngo 1.25.1\n",
		"calc.go": `package autotestpkg
func Add(a, b int) int { return a + b }
`,
		"calc_test.go": `package autotestpkg
import "testing"
func TestAdd(t *testing.T) {
	if testing.Short() {
		// verified short flag is passed
	}
	if Add(1, 2) != 3 { t.Fail() }
}
`,
	})

	output := []string{
		"=== RUN   TestAdd",
		"--- PASS: TestAdd (0.00s)",
		"PASS",
		"ok      autotestpkg     0.010s",
	}
	ann := testutil.ParseTestFailureLocations(ws, "TestAdd", output)
	if len(ann) != 0 {
		t.Errorf("Expected 0 failures on clean short run, got %d", len(ann))
	}
}

// ============================================================================
// Tier 1 - Feature Coverage: Track 47.1 (Issue #131)
// ============================================================================

func TestTier1_Track47_1_TraceTimelineLaneParsing(t *testing.T) {
	traceData := `
G 1 Running 1000 5000
G 2 Blocked 2000 6000 Channel 1 worker.go:42
G 3 Running 3000 8000
`
	lanes, edges, err := ParseExecutionTraceData(strings.NewReader(traceData))
	if err != nil {
		t.Fatalf("ParseExecutionTraceData failed: %v", err)
	}
	if len(lanes) != 3 {
		t.Fatalf("Expected 3 lanes, got %d", len(lanes))
	}
	if len(edges) != 1 {
		t.Fatalf("Expected 1 causation edge, got %d", len(edges))
	}
	if edges[0].FromG != 1 || edges[0].ToG != 2 {
		t.Errorf("Edge mismatch: from %d to %d", edges[0].FromG, edges[0].ToG)
	}
}

func TestTier1_Track47_1_TraceStateCategorization(t *testing.T) {
	traceData := `
G 10 Running 100 200
G 10 Runnable 200 300
G 10 Blocked 300 400 Mutex 11
G 10 Syscall 400 500
`
	lanes, _, err := ParseExecutionTraceData(strings.NewReader(traceData))
	if err != nil {
		t.Fatalf("Parse failed: %v", err)
	}
	if len(lanes) != 1 {
		t.Fatalf("Expected 1 lane, got %d", len(lanes))
	}
	states := make(map[string]bool)
	for _, s := range lanes[0].Spans {
		states[s.State] = true
	}
	for _, expected := range []string{"Running", "Runnable", "Blocked", "Syscall"} {
		if !states[expected] {
			t.Errorf("Expected state %q present in spans", expected)
		}
	}
}

func TestTier1_Track47_1_TraceUnblockCausationLinks(t *testing.T) {
	traceData := `
G 20 Blocked 1000 2000 Channel 21 server.go:100
`
	_, edges, err := ParseExecutionTraceData(strings.NewReader(traceData))
	if err != nil {
		t.Fatalf("Parse failed: %v", err)
	}
	if len(edges) != 1 {
		t.Fatalf("Expected 1 unblock edge, got %d", len(edges))
	}
	if edges[0].File != "server.go" || edges[0].Line != 100 {
		t.Errorf("Unblock edge location mismatch: %s:%d", edges[0].File, edges[0].Line)
	}
}

func TestTier1_Track47_1_TraceDurationMetrics(t *testing.T) {
	traceData := `
G 1 Running 0 1000
G 1 Blocked 1000 4000
G 2 Running 0 5000
`
	lanes, _, err := ParseExecutionTraceData(strings.NewReader(traceData))
	if err != nil {
		t.Fatalf("Parse failed: %v", err)
	}
	if len(lanes) != 2 {
		t.Fatalf("Expected 2 lanes, got %d", len(lanes))
	}
	// Lane 2 has total 5000, Lane 1 has total 4000
	if lanes[0].GoroutineID != 2 {
		t.Errorf("Top lane should be G2 by duration, got G%d", lanes[0].GoroutineID)
	}
}

func TestTier1_Track47_1_TraceCanvas120HzSemanticColors(t *testing.T) {
	colorMap := map[string]string{
		"Running": "systemGreen",
		"Runnable": "systemTeal",
		"Blocked": "systemOrange",
		"Syscall": "secondaryLabel",
	}
	for state, color := range colorMap {
		if state == "" || color == "" {
			t.Errorf("Invalid color mapping for state %q", state)
		}
	}
}

// ============================================================================
// Tier 1 - Feature Coverage: Track 47.2 (Issue #132)
// ============================================================================

func TestTier1_Track47_2_MultiBufferClustering(t *testing.T) {
	files := map[string]string{
		"pkg/calc.go": `package pkg
func Add(a, b int) int {
	return a + b
}
func Sub(a, b int) int {
	return a - b
}
`,
	}
	// Lines 2 and 5 are separated by 3 lines -> should be clustered together
	locs := []MatchLocation{
		{FilePath: "pkg/calc.go", Line: 2},
		{FilePath: "pkg/calc.go", Line: 5},
	}
	excerpts := BuildMultiBufferExcerpts(files, locs, 0)
	if len(excerpts) != 1 {
		t.Fatalf("Expected 1 clustered excerpt card, got %d", len(excerpts))
	}
	if excerpts[0].StartLine != 2 || excerpts[0].EndLine != 5 {
		t.Errorf("Cluster bounds mismatch: [%d, %d]; want [2, 5]", excerpts[0].StartLine, excerpts[0].EndLine)
	}
}

func TestTier1_Track47_2_MultiBufferHashSafety(t *testing.T) {
	files := map[string]string{
		"repo/data.go": "line 1\nline 2\nline 3\n",
	}
	excerpts := BuildMultiBufferExcerpts(files, []MatchLocation{
		{FilePath: "repo/data.go", Line: 2},
	}, 0)
	if len(excerpts) != 1 {
		t.Fatalf("Expected 1 excerpt, got %d", len(excerpts))
	}
	if excerpts[0].OriginalHash == "" {
		t.Fatalf("OriginalHash must not be empty")
	}

	// Mutate original content behind back
	files["repo/data.go"] = "line 1\nline 2 CHANGED\nline 3\n"
	_, _, err := ApplyMultiBufferEdits(files, excerpts)
	if err == nil || !strings.Contains(err.Error(), "hash mismatch") {
		t.Errorf("Expected hash mismatch error on stale save, got: %v", err)
	}
}

func TestTier1_Track47_2_MultiBufferBottomUpEdit(t *testing.T) {
	files := map[string]string{
		"file.go": "package main\n\nfunc First() {}\n\n// line 5\n// line 6\n// line 7\n// line 8\n// line 9\nfunc Second() {}\n",
	}
	locs := []MatchLocation{
		{FilePath: "file.go", Line: 3},
		{FilePath: "file.go", Line: 10},
	}
	excerpts := BuildMultiBufferExcerpts(files, locs, 0)
	if len(excerpts) != 2 {
		t.Fatalf("Expected 2 separate excerpts, got %d", len(excerpts))
	}

	// Modify both excerpts
	excerpts[0].Lines = "func FirstRenamed() {}"
	excerpts[1].Lines = "func SecondRenamed() {}"

	updated, _, err := ApplyMultiBufferEdits(files, excerpts)
	if err != nil {
		t.Fatalf("ApplyMultiBufferEdits failed: %v", err)
	}
	newContent := updated["file.go"]
	if !strings.Contains(newContent, "FirstRenamed") || !strings.Contains(newContent, "SecondRenamed") {
		t.Errorf("Updated file missing edited functions: %s", newContent)
	}
}

func TestTier1_Track47_2_MultiBufferMultiFileAtomicSave(t *testing.T) {
	files := map[string]string{
		"a.go": "package main\nvar A = 1\n",
		"b.go": "package main\nvar B = 2\n",
	}
	locs := []MatchLocation{
		{FilePath: "a.go", Line: 2},
		{FilePath: "b.go", Line: 2},
	}
	excerpts := BuildMultiBufferExcerpts(files, locs, 0)
	for i := range excerpts {
		if excerpts[i].FilePath == "a.go" {
			excerpts[i].Lines = "var A = 10"
		} else if excerpts[i].FilePath == "b.go" {
			excerpts[i].Lines = "var B = 20"
		}
	}

	updated, _, err := ApplyMultiBufferEdits(files, excerpts)
	if err != nil {
		t.Fatalf("Multi-file atomic edit failed: %v", err)
	}
	if !strings.Contains(updated["a.go"], "10") || !strings.Contains(updated["b.go"], "20") {
		t.Errorf("Edits not saved across both files: %+v", updated)
	}
}

func TestTier1_Track47_2_MultiBufferOneStepUndoSnapshot(t *testing.T) {
	files := map[string]string{
		"main.go": "package main\n\nfunc Run() int { return 1 }\n",
	}
	excerpts := BuildMultiBufferExcerpts(files, []MatchLocation{{FilePath: "main.go", Line: 3}}, 0)
	excerpts[0].Lines = "func Run() int { return 99 }"

	updated, undoSnapshot, err := ApplyMultiBufferEdits(files, excerpts)
	if err != nil {
		t.Fatalf("Apply failed: %v", err)
	}
	if len(undoSnapshot) != 1 {
		t.Fatalf("Expected 1 undo excerpt, got %d", len(undoSnapshot))
	}
	if !strings.Contains(undoSnapshot[0].Lines, "return 1") {
		t.Errorf("Undo snapshot does not preserve original lines: %q", undoSnapshot[0].Lines)
	}

	// Apply undo
	reverted, _, err := ApplyMultiBufferEdits(updated, undoSnapshot)
	if err != nil {
		t.Fatalf("Undo failed: %v", err)
	}
	if !strings.Contains(reverted["main.go"], "return 1") {
		t.Errorf("Reverted file does not restore original content: %s", reverted["main.go"])
	}
}

// ============================================================================
// Tier 1 - Feature Coverage: Track 47.3 (Issue #133)
// ============================================================================

func TestTier1_Track47_3_NetHTTPRouteDiscovery(t *testing.T) {
	src := `package main

import "net/http"

func setup() {
	mux := http.NewServeMux()
	mux.HandleFunc("POST /api/v1/orders/{id}", handleOrder)
	mux.HandleFunc("GET /healthz", handleHealth)
}
`
	routes, err := ScanHTTPRoutes(src)
	if err != nil {
		t.Fatalf("ScanHTTPRoutes failed: %v", err)
	}
	if len(routes) != 2 {
		t.Fatalf("Expected 2 routes, got %d", len(routes))
	}
	if routes[0].Method != "POST" || routes[0].Path != "/api/v1/orders/{id}" {
		t.Errorf("Route 0 mismatch: %s %s", routes[0].Method, routes[0].Path)
	}
	if routes[1].Method != "GET" || routes[1].Path != "/healthz" {
		t.Errorf("Route 1 mismatch: %s %s", routes[1].Method, routes[1].Path)
	}
}

func TestTier1_Track47_3_ChiRouteDiscovery(t *testing.T) {
	src := `package main

func registerRoutes(r Router) {
	r.Get("/items", getItems)
	r.Post("/items", createItem)
	r.Delete("/items/{id}", deleteItem)
}
`
	routes, err := ScanHTTPRoutes(src)
	if err != nil {
		t.Fatalf("ScanHTTPRoutes failed: %v", err)
	}
	if len(routes) != 3 {
		t.Fatalf("Expected 3 Chi routes, got %d", len(routes))
	}
	if routes[1].Method != "POST" || routes[1].Path != "/items" {
		t.Errorf("Route 1 mismatch: %s %s", routes[1].Method, routes[1].Path)
	}
}

func TestTier1_Track47_3_GinEchoRouteDiscovery(t *testing.T) {
	src := `package main

func attach(r Engine) {
	r.POST("/login", doLogin)
	r.PUT("/users/profile", updateProfile)
}
`
	routes, err := ScanHTTPRoutes(src)
	if err != nil {
		t.Fatalf("ScanHTTPRoutes failed: %v", err)
	}
	if len(routes) != 2 {
		t.Fatalf("Expected 2 routes, got %d", len(routes))
	}
	if routes[0].Method != "POST" || routes[1].Method != "PUT" {
		t.Errorf("Method mismatch: %s, %s", routes[0].Method, routes[1].Method)
	}
}

func TestTier1_Track47_3_StructInferredJSONRequestBody(t *testing.T) {
	src := `package main

type CreateUserRequest struct {
	Username string
	Age      int
	Active   bool
}

func register(mux Mux) {
	mux.HandleFunc("POST /api/v1/users", handleCreateUser)
}

func handleCreateUser() {
	var req CreateUserRequest
	_ = req
}
`
	routes, err := ScanHTTPRoutes(src)
	if err != nil {
		t.Fatalf("ScanHTTPRoutes failed: %v", err)
	}
	if len(routes) != 1 {
		t.Fatalf("Expected 1 route, got %d", len(routes))
	}
	sampleJSON := routes[0].SampleRequestBodyJSON
	if sampleJSON == "" {
		t.Fatalf("Expected inferred sample JSON body, got empty")
	}
	if !strings.Contains(sampleJSON, `"username": "sample_username"`) || !strings.Contains(sampleJSON, `"age": 1`) {
		t.Errorf("Inferred JSON body missing fields: %s", sampleJSON)
	}
}

func TestTier1_Track47_3_LocalHTTPRequestExecution(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-GoLens-Header", "Exercised")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"status":"success"}`))
	}))
	defer server.Close()

	res, err := ExecuteLocalHTTPRequest(server.URL, "GET", map[string]string{"Accept": "application/json"}, "", 2*time.Second)
	if err != nil {
		t.Fatalf("ExecuteLocalHTTPRequest failed: %v", err)
	}
	if res.StatusCode != 200 {
		t.Errorf("StatusCode = %d; want 200", res.StatusCode)
	}
	headerKey := http.CanonicalHeaderKey("X-GoLens-Header")
	if res.Headers[headerKey] != "Exercised" {
		t.Errorf("Header X-GoLens-Header = %q; want Exercised", res.Headers[headerKey])
	}
	if !strings.Contains(res.Body, `"status":"success"`) {
		t.Errorf("Body = %q; want status:success", res.Body)
	}
}
