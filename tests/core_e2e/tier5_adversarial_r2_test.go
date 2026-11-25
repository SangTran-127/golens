package core_e2e

import (
	"go/parser"
	"go/token"
	"strings"
	"testing"

	"golens/core/analysis"
	"golens/core/testutil"
)

// ============================================================================
// CHALLENGER GROUP A R2: EMPIRICAL ADVERSARIAL STRESS TEST SUITE
// ============================================================================

// 1. Multiple format verbs with non-error %v before and after error
func TestAdversarial_R2_ASTQuickFixes_FiveVerbsComplex(t *testing.T) {
	src := `package main

import (
	"errors"
	"fmt"
)

func query(user string, id int, active bool, queryStr string) error {
	err := errors.New("db disconnect")
	if err != nil {
		return fmt.Errorf("user %s (id: %d, active: %t) query %v failed: %v", user, id, active, queryStr, err)
	}
	return nil
}
`
	// Line 11 has fmt.Errorf
	fixes, err := analysis.ContextualASTQuickFixes("", "complex.go", src, 11)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(fixes) == 0 {
		t.Fatalf("expected at least 1 quick fix, got 0")
	}

	foundWrapFix := false
	for _, f := range fixes {
		t.Logf("Fix Title: %s", f.Title)
		t.Logf("Updated Source:\n%s", f.UpdatedSource)

		if strings.Contains(f.Title, "%w") {
			foundWrapFix = true

			// Ensure valid Go code
			fset := token.NewFileSet()
			_, parseErr := parser.ParseFile(fset, "test.go", f.UpdatedSource, parser.AllErrors)
			if parseErr != nil {
				t.Fatalf("DEFECT: Updated source cannot parse: %v\nCode:\n%s", parseErr, f.UpdatedSource)
			}

			// Verify queryStr (%v) was NOT replaced with %w
			if strings.Contains(f.UpdatedSource, "query %w failed") {
				t.Fatalf("DEFECT: non-error argument queryStr was wrapped with %%w!")
			}

			// Verify err (%v) WAS replaced with %w
			if !strings.Contains(f.UpdatedSource, "failed: %w") {
				t.Fatalf("DEFECT: error argument err was NOT wrapped with %%w! Code: %s", f.UpdatedSource)
			}
		}
	}

	if !foundWrapFix {
		t.Errorf("DEFECT: expected ERRWRAP_VERB quick fix, none found")
	}
}

// 2. Format string containing literal %% before error %v
func TestAdversarial_R2_ASTQuickFixes_LiteralPercentEscape(t *testing.T) {
	src := `package main

import (
	"errors"
	"fmt"
)

func runTask(taskName string) error {
	err := errors.New("oom")
	if err != nil {
		return fmt.Errorf("task %s at 100%% failed: %v", taskName, err)
	}
	return nil
}
`
	fixes, err := analysis.ContextualASTQuickFixes("", "escape.go", src, 11)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(fixes) == 0 {
		t.Fatalf("expected at least 1 quick fix, got 0")
	}

	for _, f := range fixes {
		if strings.Contains(f.Title, "ERRWRAP_VERB") {
			// Ensure valid Go code
			fset := token.NewFileSet()
			_, parseErr := parser.ParseFile(fset, "test.go", f.UpdatedSource, parser.AllErrors)
			if parseErr != nil {
				t.Fatalf("DEFECT: Parse error: %v", parseErr)
			}

			if !strings.Contains(f.UpdatedSource, "failed: %w") {
				t.Fatalf("DEFECT: %% was not preserved or err was not wrapped: %s", f.UpdatedSource)
			}
			if !strings.Contains(f.UpdatedSource, "100%%") {
				t.Fatalf("DEFECT: 100%% was mangled: %s", f.UpdatedSource)
			}
		}
	}
}

// 3. Explicit argument indices: %[2]v: %[1]s
func TestAdversarial_R2_ASTQuickFixes_ExplicitArgIndices(t *testing.T) {
	src := `package main

import (
	"errors"
	"fmt"
)

func run(name string) error {
	err := errors.New("timeout")
	if err != nil {
		return fmt.Errorf("caller %[1]s failed with error: %[2]v", name, err)
	}
	return nil
}
`
	fixes, err := analysis.ContextualASTQuickFixes("", "explicit.go", src, 11)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(fixes) == 0 {
		t.Fatalf("expected quick fix for %%[2]v error wrap, got 0")
	}

	for _, f := range fixes {
		if strings.Contains(f.Title, "ERRWRAP_VERB") {
			t.Logf("Explicit index fix source:\n%s", f.UpdatedSource)
			if !strings.Contains(f.UpdatedSource, "%[2]w") {
				t.Fatalf("DEFECT: expected %%[2]w replacement, got:\n%s", f.UpdatedSource)
			}
			if strings.Contains(f.UpdatedSource, "%[1]w") {
				t.Fatalf("DEFECT: wrongly replaced non-error argument with %%[1]w!")
			}
		}
	}
}

// 4. Printf verb with flag: %+v on error
func TestAdversarial_R2_ASTQuickFixes_PlusFlagVerb(t *testing.T) {
	src := `package main

import (
	"errors"
	"fmt"
)

func run() error {
	err := errors.New("timeout")
	if err != nil {
		return fmt.Errorf("operation failed: %+v", err)
	}
	return nil
}
`
	fixes, err := analysis.ContextualASTQuickFixes("", "plus.go", src, 11)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(fixes) == 0 {
		t.Fatalf("expected quick fix for %%+v, got 0")
	}

	for _, f := range fixes {
		if strings.Contains(f.Title, "ERRWRAP_VERB") {
			t.Logf("Plus flag fix source:\n%s", f.UpdatedSource)
			// Go does NOT allow %+w! It must be replaced by %w
			if strings.Contains(f.UpdatedSource, "%+w") {
				t.Fatalf("DEFECT: replaced with invalid %%+w! Must be %%w")
			}
			if !strings.Contains(f.UpdatedSource, "%w") {
				t.Fatalf("DEFECT: expected %%w in updated source: %s", f.UpdatedSource)
			}
		}
	}
}

// 5. Raw string literal format string
func TestAdversarial_R2_ASTQuickFixes_RawStringLiteral(t *testing.T) {
	src := "package main\n\nimport (\n\t\"errors\"\n\t\"fmt\"\n)\n\nfunc run() error {\n\terr := errors.New(\"timeout\")\n\tif err != nil {\n\t\treturn fmt.Errorf(`failure: %v`, err)\n\t}\n\treturn nil\n}\n"

	fixes, err := analysis.ContextualASTQuickFixes("", "raw.go", src, 11)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(fixes) == 0 {
		t.Fatalf("expected quick fix for raw string format, got 0")
	}

	for _, f := range fixes {
		if strings.Contains(f.Title, "ERRWRAP_VERB") {
			t.Logf("Raw string fix source:\n%s", f.UpdatedSource)
			if !strings.Contains(f.UpdatedSource, "`failure: %w`") {
				t.Fatalf("DEFECT: failed to wrap error inside raw string literal: %s", f.UpdatedSource)
			}
		}
	}
}

// 6. Test Failure Parser: Unicode & Vietnamese project paths
func TestAdversarial_R2_FailureDiff_VietnameseAndUnicodePaths(t *testing.T) {
	lines := []string{
		"=== RUN   TestTínhToán",
		"    /Users/gopher/Dự Án GoLens/bộ_kiểm_thử/tính_toán_test.go:55: got 42, want 84",
		"--- FAIL: TestTínhToán (0.00s)",
	}

	anns := testutil.ParseTestFailureLocations("", "TestTínhToán", lines)
	if len(anns) != 1 {
		t.Fatalf("DEFECT: expected 1 annotation for Vietnamese path, got %d", len(anns))
	}
	ann := anns[0]
	t.Logf("Parsed Vietnamese path: File=%s Line=%d Got=%s Want=%s", ann.File, ann.Line, ann.Got, ann.Want)
	if ann.Line != 55 {
		t.Errorf("expected line 55, got %d", ann.Line)
	}
	if ann.Got != "42" || ann.Want != "84" {
		t.Errorf("got/want mismatch: got=%q want=%q", ann.Got, ann.Want)
	}
}

// 7. Test Failure Parser: Deeply nested subtest hierarchy
func TestAdversarial_R2_FailureDiff_NestedSubtestHierarchy(t *testing.T) {
	lines := []string{
		"=== RUN   TestTree",
		"=== RUN   TestTree/Level1",
		"=== RUN   TestTree/Level1/Level2_A",
		"    tree_test.go:101: got false, want true",
		"--- FAIL: TestTree/Level1/Level2_A (0.01s)",
		"=== RUN   TestTree/Level1/Level2_B",
		"    tree_test.go:105: got \"err\", want \"nil\"",
		"--- FAIL: TestTree/Level1/Level2_B (0.02s)",
		"--- FAIL: TestTree/Level1 (0.03s)",
		"--- FAIL: TestTree (0.04s)",
	}

	anns := testutil.ParseTestFailureLocations("/tmp", "TestTree", lines)
	if len(anns) != 2 {
		t.Fatalf("DEFECT: expected exactly 2 subtest failure annotations, got %d", len(anns))
	}

	if anns[0].Line != 101 || anns[0].Got != "false" || anns[0].Want != "true" {
		t.Errorf("Annotation 0 mismatch: %+v", anns[0])
	}
	if anns[1].Line != 105 || anns[1].Got != `"err"` || anns[1].Want != `"nil"` {
		t.Errorf("Annotation 1 mismatch: %+v", anns[1])
	}
}

// 8. Test Failure Parser: ANSI color escape sequences in failure location and diff
func TestAdversarial_R2_FailureDiff_ANSIColorPollution(t *testing.T) {
	lines := []string{
		"\x1b[31m=== RUN   TestColors\x1b[0m",
		"\x1b[34m    color_test.go:88:\x1b[0m \x1b[31mgot red\x1b[0m, \x1b[32mwant green\x1b[0m",
		"\x1b[31m--- FAIL: TestColors (0.00s)\x1b[0m",
	}

	anns := testutil.ParseTestFailureLocations("/tmp", "TestColors", lines)
	if len(anns) != 1 {
		t.Fatalf("DEFECT: failed to parse test failure containing ANSI escape sequences! got %d annotations", len(anns))
	}
	ann := anns[0]
	t.Logf("Parsed ANSI: File=%s Line=%d Got=%q Want=%q", ann.File, ann.Line, ann.Got, ann.Want)
	if ann.Line != 88 {
		t.Errorf("expected line 88, got %d", ann.Line)
	}
	if ann.Got != "red" {
		t.Errorf("expected clean Got 'red', got %q", ann.Got)
	}
	if ann.Want != "green" {
		t.Errorf("expected clean Want 'green', got %q", ann.Want)
	}
}

// 9. Test Failure Parser: Windows path with forward slashes C:/repo/test.go:20
func TestAdversarial_R2_FailureDiff_WindowsForwardSlashPath(t *testing.T) {
	lines := []string{
		"=== RUN   TestWinForward",
		"    C:/Users/runner/work/calc_test.go:77: got -1, want 1",
		"--- FAIL: TestWinForward (0.00s)",
	}

	anns := testutil.ParseTestFailureLocations("", "TestWinForward", lines)
	if len(anns) != 1 {
		t.Fatalf("DEFECT: failed to parse Windows path with forward slashes C:/... got %d", len(anns))
	}
	ann := anns[0]
	t.Logf("Parsed Windows forward slash: File=%s Line=%d", ann.File, ann.Line)
	if ann.Line != 77 || ann.Got != "-1" || ann.Want != "1" {
		t.Errorf("mismatch: %+v", ann)
	}
}

// 10. Test Failure Parser: Struct diff with minus/plus characters inside string content
func TestAdversarial_R2_FailureDiff_GoCmpContentWithArithmeticSigns(t *testing.T) {
	lines := []string{
		"=== RUN   TestMathExpr",
		"    math_test.go:40: diff (-got +want):",
		"          Expr{",
		"        -     Formula: \"a - b + c\",",
		"        +     Formula: \"a + b - c\",",
		"              Valid: true,",
		"          }",
		"--- FAIL: TestMathExpr (0.00s)",
	}

	anns := testutil.ParseTestFailureLocations("/tmp", "TestMathExpr", lines)
	if len(anns) != 1 {
		t.Fatalf("expected 1 annotation, got %d", len(anns))
	}
	ann := anns[0]
	t.Logf("Math expr DiffLines count: %d", len(ann.DiffLines))
	if len(ann.DiffLines) != 5 {
		t.Errorf("expected 5 diff lines, got %d: %+v", len(ann.DiffLines), ann.DiffLines)
	}
}

// 11. Multiple errors in fmt.Errorf: first %v, second %v
func TestAdversarial_R2_ASTQuickFixes_MultipleErrorsInCall(t *testing.T) {
	src := `package main

import (
	"errors"
	"fmt"
)

func combine() error {
	err1 := errors.New("err 1")
	err2 := errors.New("err 2")
	return fmt.Errorf("operation failed: %v, secondary: %v", err1, err2)
}
`
	fixes, err := analysis.ContextualASTQuickFixes("", "combine.go", src, 11)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(fixes) == 0 {
		t.Fatalf("expected quick fix, got 0")
	}

	for _, f := range fixes {
		if strings.Contains(f.Title, "ERRWRAP_VERB") {
			t.Logf("Multiple errors fix source:\n%s", f.UpdatedSource)
			fset := token.NewFileSet()
			_, parseErr := parser.ParseFile(fset, "test.go", f.UpdatedSource, parser.AllErrors)
			if parseErr != nil {
				t.Fatalf("DEFECT: Updated source cannot parse: %v", parseErr)
			}
			// One of the errors should be wrapped with %w
			if !strings.Contains(f.UpdatedSource, "%w") {
				t.Fatalf("DEFECT: expected at least one %%w wrap in %s", f.UpdatedSource)
			}
		}
	}
}

// 12. Multiline fmt.Errorf call
func TestAdversarial_R2_ASTQuickFixes_MultilineCall(t *testing.T) {
	src := `package main

import (
	"errors"
	"fmt"
)

func run(name string) error {
	err := errors.New("timeout")
	if err != nil {
		return fmt.Errorf(
			"user %s failed: %v",
			name,
			err,
		)
	}
	return nil
}
`
	// Line 11 is "return fmt.Errorf("
	fixes, err := analysis.ContextualASTQuickFixes("", "multiline.go", src, 11)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(fixes) == 0 {
		t.Fatalf("expected quick fix on multiline call, got 0")
	}

	for _, f := range fixes {
		if strings.Contains(f.Title, "ERRWRAP_VERB") {
			t.Logf("Multiline fix source:\n%s", f.UpdatedSource)
			if !strings.Contains(f.UpdatedSource, "user %s failed: %w") {
				t.Fatalf("DEFECT: failed to wrap error on multiline call: %s", f.UpdatedSource)
			}
		}
	}
}

// 13. Mixed stdout log lines between test failures
func TestAdversarial_R2_FailureDiff_MixedStdoutLogs(t *testing.T) {
	lines := []string{
		"=== RUN   TestMixedLogs",
		"2026/11/03 19:40:00 INFO: starting test runner",
		"    calc_test.go:20: got 10, want 20",
		"2026/11/03 19:40:01 WARN: retrying connection...",
		"    calc_test.go:35: got 30, want 40",
		"--- FAIL: TestMixedLogs (0.01s)",
	}

	anns := testutil.ParseTestFailureLocations("/tmp", "TestMixedLogs", lines)
	if len(anns) != 2 {
		t.Fatalf("DEFECT: expected 2 failure annotations despite mixed logs, got %d", len(anns))
	}
	if anns[0].Line != 20 || anns[0].Got != "10" || anns[0].Want != "20" {
		t.Errorf("Annotation 0 mismatch: %+v", anns[0])
	}
	if anns[1].Line != 35 || anns[1].Got != "30" || anns[1].Want != "40" {
		t.Errorf("Annotation 1 mismatch: %+v", anns[1])
	}
}

// 14. Huge failure block with 500 lines
func TestAdversarial_R2_FailureDiff_HugeOutput500Lines(t *testing.T) {
	lines := []string{
		"=== RUN   TestHugeOutput",
		"    large_test.go:100: unexpected failure",
	}
	for i := 0; i < 500; i++ {
		lines = append(lines, "    some extra debug trace line that could be very long...")
	}
	lines = append(lines, "--- FAIL: TestHugeOutput (0.05s)")

	anns := testutil.ParseTestFailureLocations("/tmp", "TestHugeOutput", lines)
	if len(anns) != 1 {
		t.Fatalf("expected 1 annotation, got %d", len(anns))
	}
	ann := anns[0]
	if ann.Line != 100 {
		t.Errorf("expected line 100, got %d", ann.Line)
	}
	// The message should contain all the accumulated lines
	if !strings.Contains(ann.Message, "unexpected failure") {
		t.Errorf("Message missing 'unexpected failure'")
	}
}
