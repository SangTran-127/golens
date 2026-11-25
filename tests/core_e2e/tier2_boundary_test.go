package core_e2e

import (
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"golens/core/dap"
	"golens/core/testutil"
)

// ============================================================================
// Tier 2 - Boundary & Corner Cases: Track 45.1 (Issue #125)
// ============================================================================

func TestTier2_Track45_1_NilPointers(t *testing.T) {
	if got := dap.Readable("*time.Time", "nil"); got != "<nil>" {
		t.Errorf("Readable nil time pointer = %q; want <nil>", got)
	}
	if got := dap.Readable("*time.Time", "(*time.Time)(nil)"); got != "<nil>" {
		t.Errorf("Readable typed nil time pointer = %q; want <nil>", got)
	}
	if got := dap.Readable("*url.URL", "nil"); got != "<nil>" {
		t.Errorf("Readable nil url pointer = %q; want <nil>", got)
	}
	if got := dap.Readable("*url.URL", "(*url.URL)(nil)"); got != "<nil>" {
		t.Errorf("Readable typed nil url pointer = %q; want <nil>", got)
	}
}

func TestTier2_Track45_1_CorruptedDelveValues(t *testing.T) {
	corrupted := "time.Time {wall: invalid, ext: none}"
	if got := dap.Readable("time.Time", corrupted); got != corrupted {
		t.Errorf("Corrupted delve string should return raw value fallback, got %q", got)
	}
	corruptedBytes := "[]uint8 len: 5, cap: 5, [999, -1, abc]"
	if got := dap.Readable("[]byte", corruptedBytes); got != corruptedBytes {
		t.Errorf("Corrupted byte list should return raw fallback, got %q", got)
	}
}

func TestTier2_Track45_1_PayloadTruncationAt64KB(t *testing.T) {
	hugeData := strings.Repeat("X", 80*1024)
	ins := dap.InspectRawVariablePayload("string", hugeData)
	if ins.Length != 80*1024 {
		t.Errorf("Length = %d; want 81920", ins.Length)
	}
	if !ins.Truncated {
		t.Errorf("Payload > 64KB must be marked Truncated")
	}
	if !strings.Contains(ins.Text, "... (truncated at 64 KB)") {
		t.Errorf("Text preview missing truncation marker: %q", ins.Text[len(ins.Text)-50:])
	}
}

func TestTier2_Track45_1_InvalidUTF8ByteSlice(t *testing.T) {
	// 0xff 0xfe are invalid UTF-8 start bytes
	raw := "[]uint8 len: 3, cap: 3, [255, 254, 0]"
	got := dap.Readable("[]byte", raw)
	if !strings.Contains(got, "0xfffe00") {
		t.Errorf("Invalid UTF-8 should format as hex dump, got %q", got)
	}
}

func TestTier2_Track45_1_NegativeAndBoundaryDurations(t *testing.T) {
	// Negative duration
	gotNeg := dap.Readable("time.Duration", "-1000000000")
	if gotNeg != "-1s" {
		t.Errorf("Readable negative duration = %q; want -1s", gotNeg)
	}
	// Zero duration
	gotZero := dap.Readable("time.Duration", "0")
	if gotZero != "0s" {
		t.Errorf("Readable zero duration = %q; want 0s", gotZero)
	}
}

// ============================================================================
// Tier 2 - Boundary & Corner Cases: Track 45.3 (Issue #127)
// ============================================================================

func TestTier2_Track45_3_EmptyOutputLines(t *testing.T) {
	ann := testutil.ParseTestFailureLocations("", "TestEmpty", []string{})
	if ann != nil && len(ann) != 0 {
		t.Errorf("Empty output lines must return empty annotations, got %+v", ann)
	}
}

func TestTier2_Track45_3_MaxAnnotationsHardCap100(t *testing.T) {
	var output []string
	for i := 1; i <= 150; i++ {
		output = append(output, fmt.Sprintf("    test_file.go:%d: got %d, want %d", i, i, i+1))
	}
	ann := testutil.ParseTestFailureLocations("", "TestSpam", output)
	if len(ann) > 100 {
		t.Errorf("Annotations exceeded hard cap of 100 items: got %d", len(ann))
	}
	if len(ann) != 100 {
		t.Errorf("Expected exactly 100 capped annotations, got %d", len(ann))
	}
}

func TestTier2_Track45_3_MalformedFileLineOutputs(t *testing.T) {
	output := []string{
		"    not_a_number.go:abc: failure",
		"    zero.go:0: zero line number",
		"    normal.go:50: got a, want b",
	}
	ann := testutil.ParseTestFailureLocations("", "TestMalformed", output)
	// Only normal.go:50 and zero.go:0 (if line parsed) should be accepted, not abc
	for _, a := range ann {
		if strings.Contains(a.File, "not_a_number.go") {
			t.Errorf("Malformed non-numeric line should be skipped")
		}
	}
}

func TestTier2_Track45_3_MultilineIndentedDiffText(t *testing.T) {
	output := []string{
		"    deep_test.go:77: got:",
		"        \t\t\t\tline 1",
		"        \t\t\t\tline 2",
		"    want:",
		"        \t\t\t\tline 1",
		"        \t\t\t\tline 3",
	}
	ann := testutil.ParseTestFailureLocations("", "TestDeepIndent", output)
	if len(ann) != 1 {
		t.Fatalf("Expected 1 annotation, got %d", len(ann))
	}
	if ann[0].File != "deep_test.go" || ann[0].Line != 77 {
		t.Errorf("File/line mismatch: %s:%d", ann[0].File, ann[0].Line)
	}
}

func TestTier2_Track45_3_NoFailurePatternsFound(t *testing.T) {
	output := []string{
		"    generic_test.go:12: unexpected panic occurred: nil pointer dereference",
	}
	ann := testutil.ParseTestFailureLocations("", "TestPanic", output)
	if len(ann) != 1 {
		t.Fatalf("Expected 1 annotation, got %d", len(ann))
	}
	if !strings.Contains(ann[0].Message, "unexpected panic occurred") {
		t.Errorf("Generic failure message was not preserved: %q", ann[0].Message)
	}
}

// ============================================================================
// Tier 2 - Boundary & Corner Cases: Track 46.2 (Issue #129)
// ============================================================================

func TestTier2_Track46_2_ASTParseSyntaxError(t *testing.T) {
	corruptedGo := "package main\nfunc Broken( { return"
	fixes, err := ScanContextualASTQuickFixes("broken.go", corruptedGo, 2)
	if err == nil {
		t.Errorf("Expected error on invalid Go syntax, got nil")
	}
	if fixes != nil {
		t.Errorf("Expected nil fixes on syntax error, got %+v", fixes)
	}
}

func TestTier2_Track46_2_LineOutOfBounds(t *testing.T) {
	src := "package main\nfunc Valid() {}\n"
	fixes, err := ScanContextualASTQuickFixes("valid.go", src, 99999)
	if err != nil {
		t.Fatalf("Scan failed: %v", err)
	}
	if len(fixes) != 0 {
		t.Errorf("Line out of bounds should yield 0 fixes, got %d", len(fixes))
	}
}

func TestTier2_Track46_2_ZeroQuickFixesAvailable(t *testing.T) {
	src := `package main

func CleanCode() int {
	x := 42
	return x
}
`
	fixes, err := ScanContextualASTQuickFixes("clean.go", src, 4)
	if err != nil {
		t.Fatalf("Scan failed: %v", err)
	}
	if len(fixes) != 0 {
		t.Errorf("Clean code line should have 0 fixes, got %d", len(fixes))
	}
}

func TestTier2_Track46_2_NoDuplicateMenuActionIDs(t *testing.T) {
	hierarchy := GetReorganizedMenuHierarchy()
	seen := make(map[string]string)
	inspectCount := 0
	generateCount := 0

	for submenu, items := range hierarchy.InspectSubmenus {
		for _, item := range items {
			if existing, found := seen[item]; found {
				t.Fatalf("Duplicate menu item %q in Inspect groups %q and %q", item, existing, submenu)
			}
			seen[item] = "Inspect:" + submenu
			inspectCount++
		}
	}

	for submenu, items := range hierarchy.GenerateSubmenus {
		for _, item := range items {
			if existing, found := seen[item]; found {
				t.Fatalf("Duplicate menu item %q in Generate groups %q and %q", item, existing, submenu)
			}
			seen[item] = "Generate:" + submenu
			generateCount++
		}
	}

	if inspectCount != 5 || generateCount != 9 {
		t.Fatalf("Streamlined menu counts = (%d inspect, %d generate); want (5 inspect, 9 generate)", inspectCount, generateCount)
	}
}

func TestTier2_Track46_2_ASTParseBudgetConstraint(t *testing.T) {
	// Construct 500-line Go file
	var sb strings.Builder
	sb.WriteString("package main\n\n")
	for i := 0; i < 200; i++ {
		sb.WriteString(fmt.Sprintf("func fn%d() int { return %d }\n", i, i))
	}

	start := time.Now()
	fixes, err := ScanContextualASTQuickFixes("big.go", sb.String(), 50)
	duration := time.Since(start)

	if err != nil {
		t.Fatalf("AST parse failed: %v", err)
	}
	_ = fixes
	if duration > 50*time.Millisecond {
		t.Errorf("In-memory AST parse exceeded 50ms budget: took %v", duration)
	}
}

// ============================================================================
// Tier 2 - Boundary & Corner Cases: Track 46.1 (Issue #128)
// ============================================================================

func TestTier2_Track46_1_EmptyFunctionDisassembly(t *testing.T) {
	ws := CreateTestWorkspace(t, map[string]string{
		"go.mod": "module testempty\ngo 1.25.1\n",
		"main.go": `package main
func main() {}
`,
	})
	res, err := DisassembleFunction(ws, "NonExistentFunction", "arm64")
	if err == nil && len(res.Instructions) > 0 {
		t.Errorf("Expected failure or empty instructions for non-existent function")
	}
}

func TestTier2_Track46_1_UnboundedSliceLoopBCE(t *testing.T) {
	output := `
slice.go:10:12: Found IsInBounds
slice.go:11:15: Found IsInBounds
slice.go:12:18: Found IsSliceInBounds
`
	decisions := ParseCompilerOptimizationOutput(output)
	if len(decisions) != 3 {
		t.Fatalf("Expected 3 BCE decisions, got %d", len(decisions))
	}
	for _, d := range decisions {
		if d.Category != "bce_check" {
			t.Errorf("Expected bce_check, got %q", d.Category)
		}
	}
}

func TestTier2_Track46_1_InvalidTargetArchitecture(t *testing.T) {
	ws := CreateTestWorkspace(t, map[string]string{
		"go.mod": "module testinvarch\ngo 1.25.1\n",
		"main.go": "package main\nfunc main() {}\n",
	})
	_, err := DisassembleFunction(ws, "main", "invalid_arch_xyz")
	if err == nil {
		t.Errorf("Expected error for invalid target architecture, got nil")
	}
}

func TestTier2_Track46_1_MalformedCompilerOutput(t *testing.T) {
	raw := `
# some comment line
fatal error: something went wrong
regular log without file line
`
	decisions := ParseCompilerOptimizationOutput(raw)
	if len(decisions) != 0 {
		t.Errorf("Expected 0 parsed decisions on malformed compiler lines, got %d", len(decisions))
	}
}

func TestTier2_Track46_1_CompilerBudgetExceededCost(t *testing.T) {
	output := `
heavy.go:50:6: cannot inline HeavyMath: function too complex: cost 240 > budget 80
`
	decisions := ParseCompilerOptimizationOutput(output)
	if len(decisions) != 1 {
		t.Fatalf("Expected 1 decision, got %d", len(decisions))
	}
	if decisions[0].Category != "inline_blocked" {
		t.Errorf("Category = %q; want inline_blocked", decisions[0].Category)
	}
	if !strings.Contains(decisions[0].Message, "cost 240 > budget 80") {
		t.Errorf("Expected message to describe cost 240 > budget 80, got %q", decisions[0].Message)
	}
}

// ============================================================================
// Tier 2 - Boundary & Corner Cases: Track 45.2 (Issue #126)
// ============================================================================

func TestTier2_Track45_2_ZeroContentionDelay(t *testing.T) {
	lines := []string{
		"0 0 @ channel.go:1",
	}
	samples := ParseContentionLines(lines)
	if len(samples) != 1 {
		t.Fatalf("Expected 1 sample, got %d", len(samples))
	}
	if samples[0].DelayNs != 0 || samples[0].DelayMs != 0 {
		t.Errorf("Zero delay sample parsed incorrectly: %+v", samples[0])
	}
}

func TestTier2_Track45_2_MaxContentionCap500(t *testing.T) {
	var lines []string
	for i := 1; i <= 600; i++ {
		lines = append(lines, fmt.Sprintf("%d 1 @ lock_%d.go:10", i*1000, i))
	}
	samples := ParseContentionLines(lines)
	if len(samples) > 500 {
		t.Errorf("Contention samples exceeded cap of 500 items: got %d", len(samples))
	}
	if len(samples) != 500 {
		t.Errorf("Expected exactly 500 capped samples, got %d", len(samples))
	}
}

func TestTier2_Track45_2_MalformedPprofLines(t *testing.T) {
	lines := []string{
		"not numbers",
		"",
		"1000 5 @ valid.go:20",
		"bad format line",
	}
	samples := ParseContentionLines(lines)
	if len(samples) != 1 {
		t.Fatalf("Expected only 1 valid sample, got %d", len(samples))
	}
	if samples[0].File != "valid.go" || samples[0].Line != 20 {
		t.Errorf("Sample location mismatch: %s:%d", samples[0].File, samples[0].Line)
	}
}

func TestTier2_Track45_2_NegativeOrExtremeDelayValues(t *testing.T) {
	// 3600 seconds = 3,600,000,000,000 ns
	extremeNs := int64(3600) * 1e9
	lines := []string{
		fmt.Sprintf("%d 1 @ deadlocked.go:99", extremeNs),
	}
	samples := ParseContentionLines(lines)
	if len(samples) != 1 {
		t.Fatalf("Expected 1 sample, got %d", len(samples))
	}
	if samples[0].DelayMs != 3600000.0 {
		t.Errorf("DelayMs = %f; want 3600000.0", samples[0].DelayMs)
	}
}

func TestTier2_Track45_2_EmptyContentionInput(t *testing.T) {
	samples := ParseContentionLines([]string{})
	if samples != nil && len(samples) != 0 {
		t.Errorf("Expected empty slice on empty input, got %+v", samples)
	}
}

// ============================================================================
// Tier 2 - Boundary & Corner Cases: Track 46.3 (Issue #130)
// ============================================================================

func TestTier2_Track46_3_NonGoFileCounterpart(t *testing.T) {
	cp, isTest := ResolveCounterpart("README.md")
	if cp != "" || isTest {
		t.Errorf("Non-Go file should not have counterpart: got %q, isTest=%v", cp, isTest)
	}
	cp2, isTest2 := ResolveCounterpart("styles.css")
	if cp2 != "" || isTest2 {
		t.Errorf("CSS file should not have counterpart: got %q, isTest=%v", cp2, isTest2)
	}
}

func TestTier2_Track46_3_AlreadyTestFileCounterpart(t *testing.T) {
	cp, isTest := ResolveCounterpart("/pkg/service_test.go")
	if cp != "/pkg/service.go" || isTest {
		t.Errorf("service_test.go counterpart = %q, isTest = %v; want /pkg/service.go, false", cp, isTest)
	}
}

func TestTier2_Track46_3_CaretOutsideAnyFunction(t *testing.T) {
	src := `package mathutil

// Package mathutil provides math utilities
import "fmt"
`
	testSrc := `package mathutil
import "testing"
`
	_, _, found := FindMatchingTestFunction(src, testSrc, 3)
	if found {
		t.Errorf("Caret on comment line should not match any function")
	}
}

func TestTier2_Track46_3_RapidSuccessiveSaveDebounce(t *testing.T) {
	debouncer := NewAutoTestDebouncer(100 * time.Millisecond)
	executed := 0
	action := func() { executed++ }

	for i := 0; i < 50; i++ {
		debouncer.Trigger(action)
	}
	if executed != 1 {
		t.Errorf("Rapid successive triggers within window should execute exactly once, got %d", executed)
	}
}

func TestTier2_Track46_3_NestedSubtestsMatching(t *testing.T) {
	src := `package mathutil
func Run() {}
func RunAll() {}
`
	testSrc := `package mathutil
import "testing"
func TestRunAll(t *testing.T) {}
func TestRun(t *testing.T) {}
`
	name, line, found := FindMatchingTestFunction(src, testSrc, 2)
	if !found || name != "TestRun" || line != 4 {
		t.Errorf("Expected exact match TestRun at line 4, got %s at line %d", name, line)
	}
}

// ============================================================================
// Tier 2 - Boundary & Corner Cases: Track 47.1 (Issue #131)
// ============================================================================

func TestTier2_Track47_1_TraceSizeExceeds16MBHardCap(t *testing.T) {
	// Construct simulated reader exceeding 16MB cap
	hugeReader := io.LimitReader(strings.NewReader(strings.Repeat("G 1 Running 0 100\n", 1000000)), 17*1024*1024)
	_, _, err := ParseExecutionTraceData(hugeReader)
	if err == nil {
		t.Errorf("Expected error when trace exceeds 16MB limit, got nil")
	}
	if !strings.Contains(err.Error(), "exceeds 16MB limit") {
		t.Errorf("Unexpected error message: %v", err)
	}
}

func TestTier2_Track47_1_MaxLanesHardCap200(t *testing.T) {
	var sb strings.Builder
	for i := 1; i <= 300; i++ {
		sb.WriteString(fmt.Sprintf("G %d Running 0 %d\n", i, i*10))
	}
	lanes, _, err := ParseExecutionTraceData(strings.NewReader(sb.String()))
	if err != nil {
		t.Fatalf("Parse failed: %v", err)
	}
	if len(lanes) > 200 {
		t.Errorf("Lanes exceeded 200 hard cap: got %d", len(lanes))
	}
	if len(lanes) != 200 {
		t.Errorf("Expected exactly 200 capped lanes, got %d", len(lanes))
	}
}

func TestTier2_Track47_1_EmptyTraceInput(t *testing.T) {
	lanes, edges, err := ParseExecutionTraceData(strings.NewReader(""))
	if err != nil {
		t.Fatalf("Empty trace should not error: %v", err)
	}
	if len(lanes) != 0 || len(edges) != 0 {
		t.Errorf("Expected 0 lanes and edges for empty input, got %d, %d", len(lanes), len(edges))
	}
}

func TestTier2_Track47_1_CorruptedTraceLines(t *testing.T) {
	data := `
this is completely corrupted
G 1
G 2 Running 100 500
some other random text
`
	lanes, _, err := ParseExecutionTraceData(strings.NewReader(data))
	if err != nil {
		t.Fatalf("Corrupted lines should be skipped: %v", err)
	}
	if len(lanes) != 1 || lanes[0].GoroutineID != 2 {
		t.Errorf("Expected only valid lane G2, got: %+v", lanes)
	}
}

func TestTier2_Track47_1_UnblockWithoutTargetGoroutine(t *testing.T) {
	data := `
G 10 Blocked 100 200 Channel 0 missing.go:1
`
	lanes, edges, err := ParseExecutionTraceData(strings.NewReader(data))
	if err != nil {
		t.Fatalf("Parse failed: %v", err)
	}
	if len(lanes) != 1 {
		t.Fatalf("Expected 1 lane, got %d", len(lanes))
	}
	// UnblockG is 0, so no edge should be formed
	if len(edges) != 0 {
		t.Errorf("Expected 0 edges for unblock by 0, got %d", len(edges))
	}
}

// ============================================================================
// Tier 2 - Boundary & Corner Cases: Track 47.2 (Issue #132)
// ============================================================================

func TestTier2_Track47_2_OverlappingExcerptEdits(t *testing.T) {
	files := map[string]string{
		"shared.go": "line 1\nline 2\nline 3\nline 4\nline 5\n",
	}
	// Matches on lines 2 and 3 -> should merge into single excerpt [2, 3]
	locs := []MatchLocation{
		{FilePath: "shared.go", Line: 2},
		{FilePath: "shared.go", Line: 3},
	}
	excerpts := BuildMultiBufferExcerpts(files, locs, 0)
	if len(excerpts) != 1 {
		t.Fatalf("Expected merged single excerpt for overlapping lines, got %d", len(excerpts))
	}
	if excerpts[0].StartLine != 2 || excerpts[0].EndLine != 3 {
		t.Errorf("Bounds mismatch: [%d, %d]; want [2, 3]", excerpts[0].StartLine, excerpts[0].EndLine)
	}
}

func TestTier2_Track47_2_ZeroEditsProvided(t *testing.T) {
	files := map[string]string{
		"test.go": "package main\n",
	}
	updated, undo, err := ApplyMultiBufferEdits(files, []MultiBufferExcerpt{})
	if err != nil {
		t.Fatalf("Apply zero edits failed: %v", err)
	}
	if updated["test.go"] != files["test.go"] || len(undo) != 0 {
		t.Errorf("Zero edits should produce identical files and empty undo")
	}
}

func TestTier2_Track47_2_EditStartLinePastEnd(t *testing.T) {
	files := map[string]string{
		"short.go": "line 1\nline 2\n",
	}
	badExcerpt := MultiBufferExcerpt{
		FilePath:  "short.go",
		StartLine: 10,
		EndLine:   12,
		Lines:     "new line",
	}
	_, _, err := ApplyMultiBufferEdits(files, []MultiBufferExcerpt{badExcerpt})
	if err == nil {
		t.Errorf("Expected error for out-of-bounds start line, got nil")
	}
}

func TestTier2_Track47_2_MultiLineReplacementExpandingFile(t *testing.T) {
	files := map[string]string{
		"expand.go": "package main\n\nfunc Marker() {}\n\nvar After = 1\n",
	}
	excerpts := BuildMultiBufferExcerpts(files, []MatchLocation{{FilePath: "expand.go", Line: 3}}, 0)
	// Replace 1 line with 5 new lines
	var expandedLines []string
	for i := 1; i <= 5; i++ {
		expandedLines = append(expandedLines, fmt.Sprintf("func Expanded%d() {}", i))
	}
	excerpts[0].Lines = strings.Join(expandedLines, "\n")

	updated, _, err := ApplyMultiBufferEdits(files, excerpts)
	if err != nil {
		t.Fatalf("Apply failed: %v", err)
	}
	for i := 1; i <= 5; i++ {
		if !strings.Contains(updated["expand.go"], fmt.Sprintf("Expanded%d", i)) {
			t.Errorf("Missing Expanded%d in expanded file", i)
		}
	}
	if !strings.Contains(updated["expand.go"], "var After = 1") {
		t.Errorf("Following content corrupted during expansion: %s", updated["expand.go"])
	}
}

func TestTier2_Track47_2_MultiLineDeletionShrinkingFile(t *testing.T) {
	var initialLines []string
	initialLines = append(initialLines, "package main")
	for i := 1; i <= 10; i++ {
		initialLines = append(initialLines, fmt.Sprintf("// comment %d", i))
	}
	initialLines = append(initialLines, "func Keeper() {}")

	files := map[string]string{
		"shrink.go": strings.Join(initialLines, "\n"),
	}
	// Excerpt covering lines 2 to 11
	excerpt := MultiBufferExcerpt{
		FilePath:  "shrink.go",
		StartLine: 2,
		EndLine:   11,
		Lines:     "// single collapsed comment",
	}

	updated, _, err := ApplyMultiBufferEdits(files, []MultiBufferExcerpt{excerpt})
	if err != nil {
		t.Fatalf("Apply shrinking edit failed: %v", err)
	}
	if !strings.Contains(updated["shrink.go"], "// single collapsed comment") {
		t.Errorf("Missing collapsed comment")
	}
	if !strings.Contains(updated["shrink.go"], "func Keeper() {}") {
		t.Errorf("Keeper function corrupted during shrinking: %s", updated["shrink.go"])
	}
}

// ============================================================================
// Tier 2 - Boundary & Corner Cases: Track 47.3 (Issue #133)
// ============================================================================

func TestTier2_Track47_3_InvalidHTTPMethod(t *testing.T) {
	src := `package main
func setup(m Mux) {
	m.HandleFunc("UNKNOWN /custom", handler)
}
`
	routes, err := ScanHTTPRoutes(src)
	if err != nil {
		t.Fatalf("Scan failed: %v", err)
	}
	if len(routes) != 1 {
		t.Fatalf("Expected 1 route, got %d", len(routes))
	}
	if routes[0].Method != "UNKNOWN" {
		t.Errorf("Method = %q; want UNKNOWN", routes[0].Method)
	}
}

func TestTier2_Track47_3_LocalRequestTimeoutExceeded(t *testing.T) {
	slowServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		time.Sleep(150 * time.Millisecond)
		w.WriteHeader(http.StatusOK)
	}))
	defer slowServer.Close()

	// Short timeout of 20ms
	_, err := ExecuteLocalHTTPRequest(slowServer.URL, "GET", nil, "", 20*time.Millisecond)
	if err == nil {
		t.Errorf("Expected timeout error for slow server, got nil")
	}
}

func TestTier2_Track47_3_EmptyRoutePath(t *testing.T) {
	src := `package main
func setup(m Mux) {
	m.HandleFunc("", handler)
}
`
	routes, err := ScanHTTPRoutes(src)
	if err != nil {
		t.Fatalf("Scan failed: %v", err)
	}
	if len(routes) != 0 {
		t.Errorf("Empty route path should not produce route lens, got %d", len(routes))
	}
}

func TestTier2_Track47_3_MalformedRouteSyntax(t *testing.T) {
	src := `package main
func setup(m Mux) {
	m.HandleFunc(12345, handler)
}
`
	routes, err := ScanHTTPRoutes(src)
	if err != nil {
		t.Fatalf("Scan failed: %v", err)
	}
	if len(routes) != 0 {
		t.Errorf("Non-string route registration should be skipped, got %d", len(routes))
	}
}

func TestTier2_Track47_3_NonExistentLocalPortConnectionRefused(t *testing.T) {
	// Local port 64999 unlikely to be open
	_, err := ExecuteLocalHTTPRequest("http://127.0.0.1:64999/probe", "GET", nil, "", 100*time.Millisecond)
	if err == nil {
		t.Errorf("Expected connection refused error, got nil")
	}
}
