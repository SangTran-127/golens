package analysis

import (
	"encoding/json"
	"go/format"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestInspectGoTestingSafety_AllCategories(t *testing.T) {
	src := `package sample_test

import (
	"os"
	"testing"
)

func assertReady(t *testing.T, ok bool) {
	if !ok {
		t.Fatalf("service not ready")
	}
}

func requireTB(tb testing.TB, err error) {
	if err != nil {
		tb.Error(err)
	}
}

func properHelper(t *testing.T, err error) {
	t.Helper()
	if err != nil {
		t.Fatal(err)
	}
}

func TestWorkerAndEnv(t *testing.T) {
	t.Parallel()
	t.Setenv("MODE", "test")

	go func() {
		t.Fatal("worker failed")
		t.Fatalf("code: %d", 500)
		t.FailNow()
	}()

	t.Run("sub_os_env", func(t *testing.T) {
		t.Parallel()
		_ = os.Setenv("SUB_MODE", "1")
	})
}
`

	res, err := InspectGoTestingSafety(src, "sample_test.go")
	if err != nil {
		t.Fatalf("InspectGoTestingSafety returned unexpected error: %v", err)
	}
	if res.Error != "" {
		t.Fatalf("expected empty error string, got %q", res.Error)
	}

	if res.FatalInGoroutineCount != 3 {
		t.Fatalf("expected FatalInGoroutineCount = 3, got %d", res.FatalInGoroutineCount)
	}
	if res.ParallelSetenvCount != 2 {
		t.Fatalf("expected ParallelSetenvCount = 2, got %d", res.ParallelSetenvCount)
	}
	if res.MissingHelperCount != 2 {
		t.Fatalf("expected MissingHelperCount = 2, got %d", res.MissingHelperCount)
	}
	if len(res.Issues) != 7 {
		t.Fatalf("expected 7 total issues, got %d", len(res.Issues))
	}

	for _, iss := range res.Issues {
		if !iss.CanAutoFix {
			t.Errorf("expected issue %+v to be auto-fixable", iss)
		}
		if iss.ID == "" || iss.FixTitle == "" || iss.ReplacementPreview == "" {
			t.Errorf("expected complete metadata on issue: %+v", iss)
		}
		switch iss.Category {
		case "t_fatal_in_goroutine", "parallel_setenv_conflict":
			if iss.Severity != "error" {
				t.Errorf("expected error severity for %s, got %s", iss.Category, iss.Severity)
			}
		case "missing_test_helper":
			if iss.Severity != "warning" {
				t.Errorf("expected warning severity for %s, got %s", iss.Category, iss.Severity)
			}
		default:
			t.Errorf("unexpected issue category: %s", iss.Category)
		}
	}
}

func TestInspectGoTestingSafety_SingleAndApplyAllFixes(t *testing.T) {
	src := `package sample_test

import (
	"os"
	"testing"
)

func checkValue(t *testing.T, v int) {
	if v < 0 {
		t.Fatalf("negative value: %d", v)
	}
}

func TestConcurrentAndEnv(t *testing.T) {
	t.Parallel()
	t.Setenv("API_KEY", "secret")

	go func() {
		t.Fatal("boom")
		t.Fatalf("bad status %d", 404)
		t.FailNow()
	}()

	t.Run("sub", func(t *testing.T) {
		t.Parallel()
		_ = os.Setenv("SUB", "yes")
	})
}
`

	initial, err := InspectGoTestingSafety(src, "sample_test.go")
	if err != nil {
		t.Fatalf("InspectGoTestingSafety failed: %v", err)
	}
	if len(initial.Issues) != 6 {
		t.Fatalf("expected 6 initial issues, got %d", len(initial.Issues))
	}

	// 1. Apply single fix for missing_test_helper
	var helperIssueID string
	for _, iss := range initial.Issues {
		if iss.Category == "missing_test_helper" {
			helperIssueID = iss.ID
			break
		}
	}
	if helperIssueID == "" {
		t.Fatalf("missing_test_helper issue not found")
	}

	singleFix, err := ApplyGoTestingSafetyFixes(src, "sample_test.go", helperIssueID, false)
	if err != nil {
		t.Fatalf("ApplyGoTestingSafetyFixes (single) failed: %v", err)
	}
	if singleFix.FixedCount != 1 {
		t.Fatalf("expected FixedCount = 1, got %d", singleFix.FixedCount)
	}
	if !strings.Contains(singleFix.NewContent, "t.Helper()") {
		t.Fatalf("expected t.Helper() in single-fixed content:\n%s", singleFix.NewContent)
	}

	// 2. Apply all fixes
	allFix, err := ApplyGoTestingSafetyFixes(src, "sample_test.go", "", true)
	if err != nil {
		t.Fatalf("ApplyGoTestingSafetyFixes (all) failed: %v", err)
	}
	if allFix.FixedCount != 6 {
		t.Fatalf("expected FixedCount = 6, got %d", allFix.FixedCount)
	}

	// Verify go/parser & go/format validity
	fset := token.NewFileSet()
	if _, parseErr := parser.ParseFile(fset, "sample_test.go", allFix.NewContent, parser.ParseComments); parseErr != nil {
		t.Fatalf("fixed Go code failed to parse: %v\n%s", parseErr, allFix.NewContent)
	}
	formatted, fmtErr := format.Source([]byte(allFix.NewContent))
	if fmtErr != nil {
		t.Fatalf("fixed Go code failed go/format: %v", fmtErr)
	}
	if string(formatted) != allFix.NewContent {
		t.Fatalf("expected fixed content to be gofmt-formatted")
	}

	if !strings.Contains(allFix.NewContent, "t.Error(\"boom\")\n\t\treturn") {
		t.Errorf("expected t.Fatal to be rewritten to t.Error + return:\n%s", allFix.NewContent)
	}
	if !strings.Contains(allFix.NewContent, "t.Errorf(\"bad status %d\", 404)\n\t\treturn") {
		t.Errorf("expected t.Fatalf to be rewritten to t.Errorf + return:\n%s", allFix.NewContent)
	}
	if !strings.Contains(allFix.NewContent, "t.Fail()\n\t\treturn") {
		t.Errorf("expected t.FailNow() to be rewritten to t.Fail() + return:\n%s", allFix.NewContent)
	}
	if strings.Contains(allFix.NewContent, "t.Parallel()") {
		t.Errorf("expected conflicting t.Parallel() calls to be removed:\n%s", allFix.NewContent)
	}

	// Re-inspect fixed content and verify 0 remaining issues
	reinspect, err := InspectGoTestingSafety(allFix.NewContent, "sample_test.go")
	if err != nil {
		t.Fatalf("re-inspect failed: %v", err)
	}
	if len(reinspect.Issues) != 0 {
		t.Fatalf("expected 0 remaining issues after applyAll, got %d: %+v", len(reinspect.Issues), reinspect.Issues)
	}
}

func TestInspectGoTestingSafety_JSONWrappers(t *testing.T) {
	src := `package sample_test

import "testing"

func badHelper(t *testing.T) { t.Fatal("fail") }

func TestGoroutine(t *testing.T) {
	t.Parallel()
	t.Setenv("K", "V")
	go func() {
		t.FailNow()
	}()
}
`

	reqBytes, err := json.Marshal(TestingSafetyInspectRequest{
		Content:  src,
		FilePath: "json_test.go",
	})
	if err != nil {
		t.Fatalf("marshal inspect request: %v", err)
	}

	respJSON := InspectTestingSafety(string(reqBytes))
	var inspectRes TestingSafetyInspectResult
	if err := json.Unmarshal([]byte(respJSON), &inspectRes); err != nil {
		t.Fatalf("unmarshal inspect response: %v", err)
	}
	if inspectRes.FatalInGoroutineCount != 1 || inspectRes.ParallelSetenvCount != 1 || inspectRes.MissingHelperCount != 1 {
		t.Fatalf("unexpected counts in JSON response: %+v", inspectRes)
	}

	fixReqBytes, err := json.Marshal(TestingSafetyFixRequest{
		Content:  src,
		FilePath: "json_test.go",
		All:      true,
	})
	if err != nil {
		t.Fatalf("marshal fix request: %v", err)
	}

	fixRespJSON := ApplyTestingSafetyFix(string(fixReqBytes))
	var fixRes TestingSafetyFixResult
	if err := json.Unmarshal([]byte(fixRespJSON), &fixRes); err != nil {
		t.Fatalf("unmarshal fix response: %v", err)
	}
	if fixRes.Error != "" {
		t.Fatalf("unexpected fix error: %s", fixRes.Error)
	}
	if fixRes.FixedCount != 3 {
		t.Fatalf("expected FixedCount = 3, got %d", fixRes.FixedCount)
	}

	after, err := InspectGoTestingSafety(fixRes.NewContent, "json_test.go")
	if err != nil || len(after.Issues) != 0 {
		t.Fatalf("expected 0 issues after JSON fix, got err=%v issues=%+v", err, after.Issues)
	}
}

func TestInspectGoTestingSafety_SynctestBubbleCapture(t *testing.T) {
	src := `package bubble_test

import (
	"testing"
	"testing/synctest"
	"time"
)

type envelope struct {
	ch int
}

func helperUsesBubble(t *testing.T, paramCh chan int) {
	synctest.Test(t, func(t *testing.T) {
		paramCh <- 1
	})
}

func TestBubbleCaptures(t *testing.T) {
	outerCh := make(chan int)
	outerTimer := time.NewTimer(time.Second)
	outerTicker := time.NewTicker(time.Second)
	defer outerTimer.Stop()
	defer outerTicker.Stop()

	synctest.Test(t, func(t *testing.T) {
		innerCh := make(chan int)
		innerTimer := time.NewTimer(time.Millisecond)
		innerTicker := time.NewTicker(time.Millisecond)
		defer innerTimer.Stop()
		defer innerTicker.Stop()

		go func() {
			innerCh <- 1
			outerCh <- 2
		}()
		<-innerCh
		_ = outerTimer.Stop()
		select {
		case <-outerTicker.C:
		default:
		}
	})

	runner := func() {
		<-outerCh
	}
	synctest.Run(runner)

	synctest.Run(func() {
		outerCh := make(chan int)
		go func() { outerCh <- 3 }()
		<-outerCh
		env := envelope{ch: 4}
		_ = env.ch
	})
}
`

	res, err := InspectGoTestingSafety(src, "bubble_test.go")
	if err != nil {
		t.Fatalf("InspectGoTestingSafety returned unexpected error: %v", err)
	}
	if res.SynctestBubbleCaptureCount != 5 {
		t.Fatalf("expected 5 synctest bubble captures, got %d (issues=%+v)", res.SynctestBubbleCaptureCount, res.Issues)
	}

	var synctestLines []int
	for _, iss := range res.Issues {
		if iss.Category != "synctest_bubble_capture" {
			continue
		}
		if iss.Severity != "error" {
			t.Errorf("expected error severity for synctest capture, got %q", iss.Severity)
		}
		synctestLines = append(synctestLines, iss.Line)
	}
	wantLines := []int{15, 35, 38, 40, 46}
	if len(synctestLines) != len(wantLines) {
		t.Fatalf("got lines %v, want %v", synctestLines, wantLines)
	}
	for i := range wantLines {
		if synctestLines[i] != wantLines[i] {
			t.Errorf("capture %d line = %d, want %d", i, synctestLines[i], wantLines[i])
		}
	}
}

func TestRunPackageAnalyzersJSON_SynctestTestFileCleanPrecision(t *testing.T) {
	pkgDir := t.TempDir()
	testFile := filepath.Join(pkgDir, "clock_test.go")
	src := `package clock_test

import (
	st "testing/synctest"
	"testing"
	"time"
)

func checkReady(t *testing.T, ch chan int) {
	if ch == nil {
		t.Fatal("nil channel")
	}
}

func TestCleanAndLeakyBubble(t *testing.T) {
	leakedCh := make(chan int)
	checkReady(t, leakedCh)

	st.Test(t, func(t *testing.T) {
		safeCh := make(chan struct{})
		tm := time.NewTimer(time.Second)
		defer tm.Stop()
		go func() {
			close(safeCh)
		}()
		<-safeCh
		leakedCh <- 1
	})
}
`
	if err := os.WriteFile(testFile, []byte(src), 0o644); err != nil {
		t.Fatal(err)
	}
	raw := RunPackageAnalyzersJSON(pkgDir, pkgDir, "")
	var out PackageAnalyzeResult
	if err := json.Unmarshal([]byte(raw), &out); err != nil {
		t.Fatal(err)
	}
	diags := out.Files[testFile]
	if len(diags) != 1 {
		t.Fatalf("expected exactly 1 synctest diagnostic without unrelated test noise, got %+v", diags)
	}
	if diags[0].Code != CategoryConcurrency || diags[0].Line+1 != 27 || !strings.Contains(diags[0].Message, "leakedCh") {
		t.Fatalf("unexpected diagnostic: %+v", diags[0])
	}
}
