package analysis

import (
	"strings"
	"testing"
)

func TestInspectGoroutineSafety_LoopVarCaptureAndAutoFix(t *testing.T) {
	src := `package sample

import "fmt"

func dispatchAll(items []string) {
	for _, item := range items {
		go func() {
			fmt.Println(item)
		}()
	}

	for i := 0; i < len(items); i++ {
		go func() {
			fmt.Println(i)
		}()
	}
}
`
	report, err := InspectGoroutineSafety("sample.go", src)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if report.PackageName != "sample" {
		t.Fatalf("expected package sample, got %q", report.PackageName)
	}
	if report.TotalIssues != 2 || report.LoopCaptureCount != 2 || report.AutoFixableCount != 2 {
		t.Fatalf("expected 2 auto-fixable LOOP_VAR_CAPTURE issues, got %+v", report)
	}
	for _, issue := range report.Issues {
		if issue.Kind != "LOOP_VAR_CAPTURE" {
			t.Fatalf("expected LOOP_VAR_CAPTURE, got %q", issue.Kind)
		}
		if !issue.CanAutoFix {
			t.Fatalf("expected CanAutoFix=true for %+v", issue)
		}
	}

	fixedSrc, applied, err := ApplyGoroutineSafetyFixes("sample.go", src)
	if err != nil {
		t.Fatalf("ApplyGoroutineSafetyFixes failed: %v", err)
	}
	if applied != 2 {
		t.Fatalf("expected 2 applied fixes, got %d", applied)
	}
	if !strings.Contains(fixedSrc, "item := item") {
		t.Fatalf("expected fixed source to contain 'item := item', got:\n%s", fixedSrc)
	}
	if !strings.Contains(fixedSrc, "i := i") {
		t.Fatalf("expected fixed source to contain 'i := i', got:\n%s", fixedSrc)
	}

	afterReport, err := InspectGoroutineSafety("sample.go", fixedSrc)
	if err != nil {
		t.Fatalf("re-inspect failed: %v", err)
	}
	if afterReport.TotalIssues != 0 || afterReport.LoopCaptureCount != 0 {
		t.Fatalf("expected 0 issues after applying fixes, got %+v", afterReport)
	}
}

func TestInspectGoroutineSafety_WaitGroupAddInsideGo(t *testing.T) {
	src := `package sample

import "sync"

func runTasks() {
	var wg sync.WaitGroup
	go func() {
		wg.Add(1)
		defer wg.Done()
	}()
	wg.Wait()
}
`
	report, err := InspectGoroutineSafety("sample.go", src)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if report.TotalIssues != 1 || report.WaitGroupBugCount != 1 {
		t.Fatalf("expected 1 WAITGROUP_ADD_INSIDE_GO issue, got %+v", report)
	}
	issue := report.Issues[0]
	if issue.Kind != "WAITGROUP_ADD_INSIDE_GO" {
		t.Fatalf("expected WAITGROUP_ADD_INSIDE_GO, got %q", issue.Kind)
	}
	if issue.Severity != "error" {
		t.Fatalf("expected severity error, got %q", issue.Severity)
	}
	if issue.CanAutoFix {
		t.Fatalf("expected CanAutoFix=false for WAITGROUP_ADD_INSIDE_GO")
	}
	if !strings.Contains(issue.Message, "wg.Add(1)") {
		t.Fatalf("expected message to mention wg.Add(1), got %q", issue.Message)
	}
}

func TestInspectGoroutineSafety_UnboundedGoroutineLoop(t *testing.T) {
	src := `package sample

func process(s string) {}

func fanOutUnbounded(items []string) {
	for _, item := range items {
		go process(item)
	}
}
`
	report, err := InspectGoroutineSafety("sample.go", src)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if report.TotalIssues != 1 || report.UnboundedGoCount != 1 {
		t.Fatalf("expected 1 UNBOUNDED_GOROUTINE_LOOP issue, got %+v", report)
	}
	issue := report.Issues[0]
	if issue.Kind != "UNBOUNDED_GOROUTINE_LOOP" {
		t.Fatalf("expected UNBOUNDED_GOROUTINE_LOOP, got %q", issue.Kind)
	}
	if issue.Severity != "warning" {
		t.Fatalf("expected severity warning, got %q", issue.Severity)
	}
	if issue.CanAutoFix {
		t.Fatalf("expected CanAutoFix=false for UNBOUNDED_GOROUTINE_LOOP")
	}
}

func TestInspectGoroutineSafety_SafePatternsReportZeroIssues(t *testing.T) {
	src := `package sample

import "sync"

func worker(s string, wg *sync.WaitGroup) {
	defer wg.Done()
}

func safeConcurrent(items []string) {
	var wg sync.WaitGroup
	for _, item := range items {
		item := item
		wg.Add(1)
		go func() {
			defer wg.Done()
			_ = item
		}()
	}

	for _, item := range items {
		wg.Add(1)
		go func(v string) {
			defer wg.Done()
			_ = v
		}(item)
	}

	for _, item := range items {
		wg.Add(1)
		go worker(item, &wg)
	}

	wg.Wait()
}
`
	report, err := InspectGoroutineSafety("sample.go", src)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if report.TotalIssues != 0 {
		t.Fatalf("expected 0 issues on safe patterns, got %+v", report)
	}
}
