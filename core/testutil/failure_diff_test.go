package testutil

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestParseTestFailureLocations_GotWant(t *testing.T) {
	lines := []string{
		"=== RUN   TestCalculator",
		"    calculator_test.go:42: got 123, want 456",
		"--- FAIL: TestCalculator (0.00s)",
	}

	anns := ParseTestFailureLocations("/tmp/proj", "TestCalculator", lines)
	if len(anns) != 1 {
		t.Fatalf("expected 1 annotation, got %d", len(anns))
	}

	ann := anns[0]
	if !strings.HasSuffix(ann.File, "calculator_test.go") {
		t.Errorf("File = %q; want calculator_test.go", ann.File)
	}
	if ann.Line != 42 {
		t.Errorf("Line = %d; want 42", ann.Line)
	}
	if ann.Got != "123" {
		t.Errorf("Got = %q; want 123", ann.Got)
	}
	if ann.Want != "456" {
		t.Errorf("Want = %q; want 456", ann.Want)
	}
	if len(ann.DiffLines) != 2 {
		t.Errorf("expected 2 diff lines, got %d", len(ann.DiffLines))
	}
}

func TestParseTestFailureLocations_Testify(t *testing.T) {
	lines := []string{
		"=== RUN   TestUserAuth",
		"    auth_test.go:88:",
		"        	Error:      Not equal:",
		"        	            expected: \"admin\"",
		"        	            actual  : \"guest\"",
		"        	Test:       TestUserAuth",
		"--- FAIL: TestUserAuth (0.01s)",
	}

	anns := ParseTestFailureLocations("/tmp/proj", "TestUserAuth", lines)
	if len(anns) != 1 {
		t.Fatalf("expected 1 annotation, got %d", len(anns))
	}

	ann := anns[0]
	if ann.Line != 88 {
		t.Errorf("Line = %d; want 88", ann.Line)
	}
	if ann.Want != `"admin"` {
		t.Errorf("Want = %q; want \"admin\"", ann.Want)
	}
	if ann.Got != `"guest"` {
		t.Errorf("Got = %q; want \"guest\"", ann.Got)
	}
}

func TestParseTestFailureLocations_GoCmp(t *testing.T) {
	lines := []string{
		"=== RUN   TestConfigDiff",
		"    config_test.go:55: unexpected config (-got +want):",
		"          Config{",
		"        -     Port: 8080,",
		"        +     Port: 9090,",
		"              Debug: true,",
		"          }",
		"--- FAIL: TestConfigDiff (0.00s)",
	}

	anns := ParseTestFailureLocations("/tmp/proj", "TestConfigDiff", lines)
	if len(anns) != 1 {
		t.Fatalf("expected 1 annotation, got %d", len(anns))
	}

	ann := anns[0]
	if ann.Line != 55 {
		t.Errorf("Line = %d; want 55", ann.Line)
	}
	if len(ann.DiffLines) == 0 {
		t.Fatalf("expected go-cmp diff lines, got none")
	}

	hasGot := false
	hasWant := false
	for _, dl := range ann.DiffLines {
		if dl.Type == "got" && strings.Contains(dl.Text, "Port: 8080") {
			hasGot = true
		}
		if dl.Type == "want" && strings.Contains(dl.Text, "Port: 9090") {
			hasWant = true
		}
	}
	if !hasGot || !hasWant {
		t.Errorf("expected got and want diff lines for Port, got: %+v", ann.DiffLines)
	}
}

func TestParseTestFailureLocations_PlainError(t *testing.T) {
	lines := []string{
		"=== RUN   TestDatabaseConnect",
		"    db_test.go:19: connection refused to localhost:5432",
		"--- FAIL: TestDatabaseConnect (0.00s)",
	}

	anns := ParseTestFailureLocations("/tmp/proj", "TestDatabaseConnect", lines)
	if len(anns) != 1 {
		t.Fatalf("expected 1 annotation, got %d", len(anns))
	}

	ann := anns[0]
	if ann.Line != 19 {
		t.Errorf("Line = %d; want 19", ann.Line)
	}
	if !strings.Contains(ann.Message, "connection refused") {
		t.Errorf("Message = %q; expected to contain 'connection refused'", ann.Message)
	}
	if ann.Got != "" || ann.Want != "" {
		t.Errorf("Plain error should have empty Got and Want, got: got=%q want=%q", ann.Got, ann.Want)
	}
}

func TestParseTestFailureLocations_CapGuardrail(t *testing.T) {
	var lines []string
	for i := 1; i <= 150; i++ {
		lines = append(lines, fmt.Sprintf("    bulk_test.go:%d: got %d, want %d", i, i, i+1))
	}

	anns := ParseTestFailureLocations("/tmp/proj", "TestBulk", lines)
	if len(anns) != 100 {
		t.Errorf("expected capped at 100 annotations, got %d", len(anns))
	}
}

func TestParseTestFailureLocations_TestifyErrorTraceAndDiff(t *testing.T) {
	dir := t.TempDir()
	userTest := filepath.Join(dir, "service_test.go")
	helperTest := filepath.Join(dir, "helper_test.go")
	if err := os.WriteFile(userTest, []byte("package svc\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(helperTest, []byte("package svc\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	lines := []string{
		"=== RUN   TestCreateUser/admin",
		"    helper_test.go:14:",
		"        \tError Trace:\t" + helperTest + ":14",
		"        \t            \t\t\t" + userTest + ":63",
		"        \t            \t\t\t/go/pkg/mod/github.com/stretchr/testify@v1.9.0/suite/suite.go:202",
		"        \tError:      \tNot equal:",
		"        \t            \texpected: service.User{Name:\"alice\", Role:\"admin\"}",
		"        \t            \tactual  : service.User{Name:\"alice\", Role:\"guest\"}",
		"        \t            \tDiff:",
		"        \t            \t--- Expected",
		"        \t            \t+++ Actual",
		"        \t            \t@@ -1,4 +1,4 @@",
		"        \t            \t (service.User) {",
		"        \t            \t  Name: (string) \"alice\",",
		"        \t            \t- Role: (string) \"admin\"",
		"        \t            \t+ Role: (string) \"guest\"",
		"        \t            \t }",
		"        \t            \t",
		"        \tTest:       \tTestCreateUser/admin",
		"--- FAIL: TestCreateUser/admin (0.00s)",
	}

	anns := ParseTestFailureLocations(dir, "TestCreateUser/admin", lines)
	if len(anns) != 1 {
		t.Fatalf("expected 1 annotation, got %d", len(anns))
	}
	ann := anns[0]
	if ann.File != userTest || ann.Line != 63 {
		t.Fatalf("resolved location = %s:%d, want %s:63", ann.File, ann.Line, userTest)
	}
	if ann.DiffTruncated {
		t.Fatalf("did not expect DiffTruncated for 5-line diff")
	}
	if len(ann.DiffLines) != 5 {
		t.Fatalf("diffLines len = %d, want 5: %+v", len(ann.DiffLines), ann.DiffLines)
	}
	if ann.DiffLines[0].Type != "same" || ann.DiffLines[2].Type != "want" || ann.DiffLines[3].Type != "got" {
		t.Fatalf("unexpected diff line types: %+v", ann.DiffLines)
	}
	if !strings.Contains(ann.DiffLines[2].Text, `"admin"`) || !strings.Contains(ann.DiffLines[3].Text, `"guest"`) {
		t.Fatalf("unexpected diff text: %+v", ann.DiffLines)
	}
}

func TestParseTestFailureLocations_MultiLineGotWantAndBoundedLCS(t *testing.T) {
	lines := []string{
		"    formatter_test.go:29: output mismatch:",
		"        want:",
		"            alpha",
		"            beta",
		"            gamma",
		"        got:",
		"            alpha",
		"            delta",
		"            gamma",
	}
	anns := ParseTestFailureLocations("/tmp/proj", "TestFormatter", lines)
	if len(anns) != 1 {
		t.Fatalf("expected 1 annotation, got %d", len(anns))
	}
	dl := anns[0].DiffLines
	if len(dl) != 4 {
		t.Fatalf("expected 4 LCS-aligned diff lines (same, want, got, same), got %d: %+v", len(dl), dl)
	}
	if dl[0].Type != "same" || dl[0].Text != "alpha" ||
		dl[1].Type != "want" || dl[1].Text != "beta" ||
		dl[2].Type != "got" || dl[2].Text != "delta" ||
		dl[3].Type != "same" || dl[3].Text != "gamma" {
		t.Fatalf("unexpected LCS alignment: %+v", dl)
	}

	var wantLarge, gotLarge []string
	for i := 0; i < 650; i++ {
		wantLarge = append(wantLarge, fmt.Sprintf("field_%03d: %d", i, i))
		if i == 50 {
			gotLarge = append(gotLarge, fmt.Sprintf("field_%03d: 9999", i))
		} else {
			gotLarge = append(gotLarge, fmt.Sprintf("field_%03d: %d", i, i))
		}
	}
	largeDiff, truncated, total := computeBoundedLCSDiff(strings.Join(gotLarge, "\n"), strings.Join(wantLarge, "\n"))
	if !truncated {
		t.Fatalf("expected truncated=true for 650-line diff")
	}
	if len(largeDiff) > maxDiffOutputLines {
		t.Fatalf("expected len <= %d, got %d", maxDiffOutputLines, len(largeDiff))
	}
	if total <= len(largeDiff) {
		t.Fatalf("expected DiffTotalLines (%d) > len (%d)", total, len(largeDiff))
	}
}

func TestParseTestFailureLocations_StandaloneTestifyErrorTraceWithoutHeader(t *testing.T) {
	pkgDir := t.TempDir()
	helperPath := filepath.Join(pkgDir, "helper_test.go")
	callerPath := filepath.Join(pkgDir, "calc_test.go")
	if err := os.WriteFile(helperPath, []byte("package calc\n"), 0644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(callerPath, []byte("package calc\n"), 0644); err != nil {
		t.Fatal(err)
	}
	lines := []string{
		"\tError Trace:\t" + helperPath + ":13",
		"\t            \t" + callerPath + ":30",
		"\tError:      \tNot equal:",
		"\t            \texpected: {\"alpha\"}",
		"\t            \tactual  : {\"beta\"}",
		"\t            \tDiff:",
		"\t            \t--- Expected",
		"\t            \t+++ Actual",
		"\t            \t@@ -1,3 +1,3 @@",
		"\t            \t {",
		"\t            \t-  Name: \"alpha\",",
		"\t            \t+  Name: \"beta\",",
		"\t            \t }",
		"\tTest:       \tTestSuite/group/deep_fail",
	}
	anns := ParseTestFailureLocations(pkgDir, "TestSuite/group/deep_fail", lines)
	if len(anns) != 1 {
		t.Fatalf("expected 1 annotation from standalone Error Trace, got %d: %+v", len(anns), anns)
	}
	if anns[0].File != callerPath || anns[0].Line != 30 {
		t.Fatalf("expected unwrapped caller %s:30, got %s:%d", callerPath, anns[0].File, anns[0].Line)
	}
	if anns[0].Message != "Not equal" {
		t.Fatalf("expected summary message 'Not equal', got %q", anns[0].Message)
	}
	if len(anns[0].DiffLines) < 3 {
		t.Fatalf("expected parsed diff lines, got %+v", anns[0].DiffLines)
	}
}
