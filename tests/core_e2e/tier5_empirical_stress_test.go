package core_e2e

import (
	"fmt"
	"strings"
	"testing"
	"time"

	"golens/core/analysis"
	"golens/core/dap"
	"golens/core/testutil"
)

// ============================================================================
// PART 1: ContextualASTQuickFixes Stress & Pathological Testing
// ============================================================================

func TestAdversarial_ASTQuickFixes_PathologicalSyntax(t *testing.T) {
	cases := []struct {
		name    string
		content string
		line    int
	}{
		{
			name:    "truncated_decl",
			content: "package main\n\nfunc Foo(a int, b ",
			line:    3,
		},
		{
			name:    "unclosed_braces",
			content: "package main\n\nfunc Foo() {\n\t{\n\t\t{\n\t\t\t{\n\t\t\t\t{\n",
			line:    3,
		},
		{
			name:    "unterminated_string",
			content: "package main\n\nfunc Foo() {\n\ts := \"unclosed string\n}\n",
			line:    4,
		},
		{
			name:    "unterminated_raw_string",
			content: "package main\n\nfunc Foo() {\n\ts := `unclosed raw string\n",
			line:    4,
		},
		{
			name:    "unterminated_multiline_comment",
			content: "package main\n\n/* unclosed multiline comment\nfunc Foo() {}\n",
			line:    3,
		},
		{
			name:    "invalid_tokens_binary",
			content: "package main\n\x00\x01\x02\xff\xfe\x00\x00 func Foo() {}",
			line:    2,
		},
		{
			name:    "only_package_clause",
			content: "package main",
			line:    1,
		},
		{
			name:    "empty_content",
			content: "",
			line:    1,
		},
		{
			name:    "whitespace_only",
			content: "   \t\n  \t\r\n   ",
			line:    2,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			defer func() {
				if r := recover(); r != nil {
					t.Fatalf("PANIC on %s: %v", tc.name, r)
				}
			}()

			start := time.Now()
			fixes, err := analysis.ContextualASTQuickFixes("", "pathological.go", tc.content, tc.line)
			elapsed := time.Since(start)

			t.Logf("[%s] elapsed: %v, fixes: %d, err: %v", tc.name, elapsed, len(fixes), err)
			if elapsed > 50*time.Millisecond {
				t.Errorf("[%s] took too long: %v (budget 50ms for error recovery)", tc.name, elapsed)
			}
		})
	}
}

func TestAdversarial_ASTQuickFixes_UnicodeAndVietnamese(t *testing.T) {
	src := `package main

import (
	"context"
	"fmt"
	"time"
)

// Hàm xử lý nghiệp vụ với chuỗi tiếng Việt có dấu: Ứ, Ớ, Đ, ệ, ồ...
// Biểu tượng cảm xúc: ` + "\U0001F680 \U0001F525 \U0001F1FB\U0001F1F3 \U0001F4BB\n" + `func XửLýDữLiệu() error {
	tiêuĐề := "Kiểm tra AST quick-fix với Unicode tiếng Việt"
	fmt.Println(tiêuĐề)
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	_ = ctx
	return nil
}
`
	lines := strings.Split(src, "\n")
	targetLine := 0
	for i, l := range lines {
		if strings.Contains(l, "context.WithTimeout") {
			targetLine = i + 1
			break
		}
	}
	if targetLine == 0 {
		t.Fatalf("could not find target line in test fixture")
	}

	fixes, err := analysis.ContextualASTQuickFixes("", "vietnamese.go", src, targetLine)
	if err != nil {
		t.Fatalf("unexpected error with Unicode content: %v", err)
	}
	if len(fixes) == 0 {
		t.Fatalf("expected at least 1 fix for missing defer cancel(), got 0")
	}

	found := false
	for _, f := range fixes {
		if strings.Contains(f.UpdatedSource, "defer cancel()") {
			found = true
			if !strings.Contains(f.UpdatedSource, "Hàm xử lý nghiệp vụ với chuỗi tiếng Việt có dấu") {
				t.Errorf("Vietnamese comments corrupted in updated source!")
			}
			break
		}
	}
	if !found {
		t.Errorf("missing defer cancel() fix in Unicode source: %+v", fixes)
	}
}

func TestAdversarial_ASTQuickFixes_WindowsCRLF(t *testing.T) {
	crlfSrc := "package main\r\n\r\nimport (\r\n\t\"context\"\r\n\t\"time\"\r\n)\r\n\r\nfunc run() {\r\n\tctx, cancel := context.WithCancel(context.Background())\r\n\t_ = ctx\r\n}\r\n"

	fixes, err := analysis.ContextualASTQuickFixes("", "crlf.go", crlfSrc, 9)
	if err != nil {
		t.Fatalf("CRLF file error: %v", err)
	}
	if len(fixes) == 0 {
		t.Fatalf("expected quick fix for CRLF file, got 0")
	}
	t.Logf("CRLF fixes count: %d, title: %s", len(fixes), fixes[0].Title)
}

func TestAdversarial_ASTQuickFixes_HugeSingleLine(t *testing.T) {
	var sb strings.Builder
	sb.WriteString("package main\n\nvar x = []int{")
	for i := 0; i < 50000; i++ {
		sb.WriteString("1, ")
	}
	sb.WriteString("}\n")
	content := sb.String()

	start := time.Now()
	fixes, err := analysis.ContextualASTQuickFixes("", "huge_line.go", content, 3)
	elapsed := time.Since(start)

	t.Logf("Huge single line (50k elements, %d bytes) elapsed: %v, fixes: %d, err: %v", len(content), elapsed, len(fixes), err)
	if elapsed > 200*time.Millisecond {
		t.Errorf("Huge single line took too long: %v", elapsed)
	}
}

func TestAdversarial_ASTQuickFixes_LargeFile10kLines(t *testing.T) {
	var sb strings.Builder
	sb.WriteString("package main\n\nimport (\n\t\"context\"\n\t\"time\"\n)\n\n")
	for i := 1; i <= 5000; i++ {
		fmt.Fprintf(&sb, "func helper%d() int { return %d }\n", i, i)
	}
	sb.WriteString("func worker() {\n\tctx, cancel := context.WithTimeout(context.Background(), time.Second)\n\t_ = ctx\n}\n")
	for i := 5001; i <= 10000; i++ {
		fmt.Fprintf(&sb, "func helper%d() int { return %d }\n", i, i)
	}
	content := sb.String()
	lines := strings.Split(content, "\n")
	targetLine := 0
	for i, l := range lines {
		if strings.Contains(l, "context.WithTimeout") {
			targetLine = i + 1
			break
		}
	}

	start := time.Now()
	fixes, err := analysis.ContextualASTQuickFixes("", "large.go", content, targetLine)
	elapsed := time.Since(start)

	t.Logf("Large file (10,000 lines, %d bytes) elapsed: %v, fixes: %d, err: %v", len(content), elapsed, len(fixes), err)
}

func TestAdversarial_ASTQuickFixes_StrictLatencyBenchmark(t *testing.T) {
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
	// Warm up
	for i := 0; i < 5; i++ {
		_, _ = analysis.ContextualASTQuickFixes("", "worker.go", src, 9)
	}

	const iterations = 50
	var durations []time.Duration
	var total time.Duration

	for i := 0; i < iterations; i++ {
		start := time.Now()
		_, err := analysis.ContextualASTQuickFixes("", "worker.go", src, 9)
		elapsed := time.Since(start)
		if err != nil {
			t.Fatalf("iteration %d failed: %v", i, err)
		}
		durations = append(durations, elapsed)
		total += elapsed
	}

	avg := total / time.Duration(iterations)
	min := durations[0]
	max := durations[0]
	for _, d := range durations {
		if d < min {
			min = d
		}
		if d > max {
			max = d
		}
	}

	t.Logf("AST Quick Fix latency across %d runs: avg=%v, min=%v, max=%v", iterations, avg, min, max)

	// Guardrail check: R4 specifies < 2ms for in-memory AST check on small active file
	if avg > 2*time.Millisecond {
		t.Logf("WARNING/FINDING: Average AST quick-fix time (%v) exceeds 2ms guardrail!", avg)
	}
}

func TestAdversarial_ASTQuickFixes_MultipleFormatVerbsTrap(t *testing.T) {
	// Adversarial test: fmt.Errorf with multiple %v format verbs
	// Line 11: fmt.Errorf("user %v failed: %v", username, err)
	src := `package main

import (
	"fmt"
	"errors"
)

func process(username string) error {
	err := errors.New("io timeout")
	if err != nil {
		return fmt.Errorf("user %v failed: %v", username, err)
	}
	return nil
}
`
	fixes, err := analysis.ContextualASTQuickFixes("", "trap.go", src, 11)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	t.Logf("Multiple verbs fixes count: %d", len(fixes))
	for _, f := range fixes {
		t.Logf("Fix Title: %s", f.Title)
		t.Logf("Fix Updated Source:\n%s", f.UpdatedSource)
		// Check whether %v on username was erroneously replaced by %w
		if strings.Contains(f.UpdatedSource, `user %w failed: %v`) {
			t.Errorf("DEFECT FOUND: Replaced the non-error argument %%v with %%w! Code: %s", f.UpdatedSource)
		}
	}
}

// ============================================================================
// PART 2: Got vs Want failure diff parser Stress Testing
// ============================================================================

func TestAdversarial_FailureDiff_GoCmpTabsIndentation(t *testing.T) {
	// Standard go-cmp diff using tabs instead of double-spaces
	lines := []string{
		"=== RUN   TestGoCmpTabs",
		"    cmp_test.go:30: diff (-got +want):",
		"\t\tConfig{",
		"\t\t- Host: \"localhost:8080\",",
		"\t\t+ Host: \"production:443\",",
		"\t\t  Timeout: 30,",
		"\t\t}",
		"--- FAIL: TestGoCmpTabs (0.00s)",
	}

	anns := testutil.ParseTestFailureLocations("/tmp", "TestGoCmpTabs", lines)
	if len(anns) != 1 {
		t.Fatalf("expected 1 annotation, got %d", len(anns))
	}
	ann := anns[0]
	t.Logf("GoCmpTabs ann: Got=%q Want=%q DiffLines=%d", ann.Got, ann.Want, len(ann.DiffLines))
	if len(ann.DiffLines) == 0 {
		t.Errorf("DEFECT: Failed to parse go-cmp diff when indented with tabs!")
	}
}

func TestAdversarial_FailureDiff_PathWithSpaces(t *testing.T) {
	lines := []string{
		"=== RUN   TestPathSpaces",
		"    /Users/gopher/My Projects/GoLens IDE/core/calc_test.go:42: got 100, want 200",
		"--- FAIL: TestPathSpaces (0.00s)",
	}

	anns := testutil.ParseTestFailureLocations("/tmp", "TestPathSpaces", lines)
	if len(anns) != 1 {
		t.Logf("FINDING: ParseTestFailureLocations returned %d annotations for path with spaces", len(anns))
		if len(anns) == 0 {
			t.Errorf("DEFECT: Failed to parse test failure when file path contains spaces!")
		}
	} else {
		t.Logf("Parsed file path: %q, line: %d", anns[0].File, anns[0].Line)
	}
}

func TestAdversarial_FailureDiff_TestifyComplexMultiline(t *testing.T) {
	lines := []string{
		"=== RUN   TestUserAuthComplex",
		"    auth_test.go:120:",
		"        	Error:      Not equal:",
		"        	            expected: map[string]interface {}{\"active\":true, \"roles\":[]string{\"admin\", \"dev\"}}",
		"        	            actual  : map[string]interface {}{\"active\":false, \"roles\":[]string{\"guest\"}}",
		"        	Test:       TestUserAuthComplex",
		"--- FAIL: TestUserAuthComplex (0.01s)",
	}

	anns := testutil.ParseTestFailureLocations("/tmp", "TestUserAuthComplex", lines)
	if len(anns) != 1 {
		t.Fatalf("expected 1 annotation, got %d", len(anns))
	}
	ann := anns[0]
	t.Logf("Testify complex Got=%q, Want=%q", ann.Got, ann.Want)
	if !strings.Contains(ann.Want, "admin") || !strings.Contains(ann.Got, "guest") {
		t.Errorf("Testify complex map diff did not extract expected/actual properly")
	}
}

func TestAdversarial_FailureDiff_GoCmpReverseOrder(t *testing.T) {
	// go-cmp with (-want +got) order
	lines := []string{
		"=== RUN   TestGoCmpReverse",
		"    cmp_test.go:45: diff (-want +got):",
		"          Person{",
		"        -     Name: \"Alice\",",
		"        +     Name: \"Bob\",",
		"              Age: 30,",
		"          }",
		"--- FAIL: TestGoCmpReverse (0.00s)",
	}

	anns := testutil.ParseTestFailureLocations("/tmp", "TestGoCmpReverse", lines)
	if len(anns) != 1 {
		t.Fatalf("expected 1 annotation, got %d", len(anns))
	}
	ann := anns[0]
	t.Logf("GoCmp reverse Got=%q, Want=%q", ann.Got, ann.Want)
	if !strings.Contains(ann.Got, "Bob") {
		t.Errorf("expected Got to contain Bob, got %q", ann.Got)
	}
	if !strings.Contains(ann.Want, "Alice") {
		t.Errorf("expected Want to contain Alice, got %q", ann.Want)
	}
}

func TestAdversarial_FailureDiff_CRLFFailureOutput(t *testing.T) {
	lines := []string{
		"=== RUN   TestCRLF\r",
		"    calc_test.go:15: got 99, want 100\r",
		"--- FAIL: TestCRLF (0.00s)\r",
	}

	anns := testutil.ParseTestFailureLocations("/tmp", "TestCRLF", lines)
	if len(anns) != 1 {
		t.Fatalf("expected 1 annotation with CRLF lines, got %d", len(anns))
	}
	if anns[0].Got != "99" || anns[0].Want != "100" {
		t.Errorf("CRLF got/want mismatch: got=%q want=%q", anns[0].Got, anns[0].Want)
	}
}

func TestAdversarial_FailureDiff_EmptyAndNonMatchingLines(t *testing.T) {
	if anns := testutil.ParseTestFailureLocations("/tmp", "TestEmpty", nil); len(anns) != 0 {
		t.Errorf("expected 0 annotations for nil lines, got %d", len(anns))
	}

	if anns := testutil.ParseTestFailureLocations("/tmp", "TestMalformed", []string{"not a failure line", "broken:abc:def"}); len(anns) != 0 {
		t.Errorf("expected 0 annotations for non-matching lines, got %d", len(anns))
	}
}

func TestAdversarial_FailureDiff_1000AnnotationsCapped(t *testing.T) {
	var lines []string
	for i := 1; i <= 1000; i++ {
		lines = append(lines, fmt.Sprintf("    mass_test.go:%d: got %d, want %d", i, i, i+1))
	}

	anns := testutil.ParseTestFailureLocations("/tmp", "TestMass", lines)
	if len(anns) != 100 {
		t.Errorf("expected strictly capped at 100 annotations, got %d", len(anns))
	}
}

// ============================================================================
// PART 3: Track 45.1 Debugger Readable & Payload Truncation Stress
// ============================================================================

func TestAdversarial_Debugger_PayloadTruncation64KB(t *testing.T) {
	bigPayload := strings.Repeat("A", 128*1024) // 128 KB
	res := dap.InspectRawVariablePayload("string", `"`+bigPayload+`"`)

	if !res.Truncated {
		t.Errorf("expected Truncated=true for 128KB payload")
	}
	if len(res.Text) > 65*1024+500 {
		t.Errorf("Text payload exceeded truncation limit: len=%d", len(res.Text))
	}
	if !strings.Contains(res.Text, "truncated at 64 KB") {
		t.Errorf("missing truncation notice in Text")
	}
}

func TestAdversarial_Debugger_NonUTF8Payload(t *testing.T) {
	// Raw binary bytes containing invalid UTF-8 sequences
	rawBytesValue := "[]uint8 [255, 254, 0, 1, 128, 129]"
	res := dap.InspectRawVariablePayload("[]uint8", rawBytesValue)

	if res.Length != 6 {
		t.Errorf("expected length 6, got %d", res.Length)
	}
	if !strings.Contains(res.HexDump, "ff fe 00 01 80 81") {
		t.Errorf("HexDump did not format correctly: %s", res.HexDump)
	}
}

func TestAdversarial_Debugger_MalformedTimeAndURL(t *testing.T) {
	// Malformed Delve values should not panic
	out1 := dap.Readable("time.Time", "corrupted wall ext format")
	if out1 != "corrupted wall ext format" {
		t.Errorf("expected fallback to raw string, got %q", out1)
	}

	out2 := dap.Readable("url.URL", "corrupted url structure")
	if out2 != "corrupted url structure" {
		t.Errorf("expected fallback to raw string, got %q", out2)
	}
}

func TestAdversarial_FailureDiff_GoCmpTrailerPollution(t *testing.T) {
	lines := []string{
		"=== RUN   TestGoCmpTrailer",
		"    cmp_test.go:55: unexpected config (-got +want):",
		"          Config{",
		"        -     Port: 8080,",
		"        +     Port: 9090,",
		"              Debug: true,",
		"          }",
		"--- FAIL: TestGoCmpTrailer (0.00s)",
	}

	anns := testutil.ParseTestFailureLocations("/tmp", "TestGoCmpTrailer", lines)
	if len(anns) != 1 {
		t.Fatalf("expected 1 annotation, got %d", len(anns))
	}
	ann := anns[0]
	for _, dl := range ann.DiffLines {
		t.Logf("DiffLine: [%s] %q", dl.Type, dl.Text)
		if strings.Contains(dl.Text, "FAIL: TestGoCmpTrailer") {
			t.Errorf("DEFECT FOUND: '--- FAIL' test runner trailer line was erroneously parsed as a diff line: %+v", dl)
		}
	}
}

func TestAdversarial_FailureDiff_WindowsDrivePath(t *testing.T) {
	lines := []string{
		"=== RUN   TestWinDrive",
		`    C:\Users\runner\repo\calc_test.go:42: got 1, want 2`,
		"--- FAIL: TestWinDrive (0.00s)",
	}

	anns := testutil.ParseTestFailureLocations("", "TestWinDrive", lines)
	if len(anns) == 0 {
		t.Errorf("DEFECT: Failed to parse Windows drive path with colon: C:\\...")
	} else {
		t.Logf("Windows drive path parsed: %s:%d", anns[0].File, anns[0].Line)
	}
}

func TestAdversarial_FailureDiff_MultilineGotWantBlocks(t *testing.T) {
	lines := []string{
		"=== RUN   TestMultilineGotWant",
		"    calc_test.go:50:",
		"        got:",
		"        line 1",
		"        line 2",
		"        want:",
		"        line 1",
		"        line 3",
		"--- FAIL: TestMultilineGotWant (0.00s)",
	}

	anns := testutil.ParseTestFailureLocations("/tmp", "TestMultilineGotWant", lines)
	if len(anns) != 1 {
		t.Fatalf("expected 1 annotation, got %d", len(anns))
	}
	ann := anns[0]
	t.Logf("Multiline Got=%q Want=%q DiffLines=%d", ann.Got, ann.Want, len(ann.DiffLines))
	if ann.Got == "" || ann.Want == "" {
		t.Logf("FINDING: Multiline got/want blocks on separate lines are not recognized by single-line regex (Got=%q, Want=%q)", ann.Got, ann.Want)
	}
}

func TestAdversarial_FailureDiff_TestifyDiffBlock(t *testing.T) {
	lines := []string{
		"=== RUN   TestTestifyDiff",
		"    diff_test.go:60:",
		"        	Error:      Not equal:",
		"        	            Diff:",
		"        	            --- Expected",
		"        	            +++ Actual",
		"        	            @@ -1,3 +1,3 @@",
		"        	             line 1",
		"        	            -line 2 expected",
		"        	            +line 2 actual",
		"        	             line 3",
		"        	Test:       TestTestifyDiff",
		"--- FAIL: TestTestifyDiff (0.00s)",
	}

	anns := testutil.ParseTestFailureLocations("/tmp", "TestTestifyDiff", lines)
	if len(anns) != 1 {
		t.Fatalf("expected 1 annotation, got %d", len(anns))
	}
	ann := anns[0]
	t.Logf("Testify Diff block: Got=%q Want=%q DiffLines=%d", ann.Got, ann.Want, len(ann.DiffLines))
}

