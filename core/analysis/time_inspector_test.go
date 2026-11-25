package analysis

import (
	"go/ast"
	"go/format"
	"go/importer"
	"go/parser"
	"go/token"
	"go/types"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestTimeSafetyInspectAllCategories(t *testing.T) {
	src := `package sample

import "time"

func MonitorAndCompare(a, b time.Time, items []string) bool {
	ticker := time.NewTicker(100 * time.Millisecond)
	_ = ticker.C

	timer := time.NewTimer(5 * time.Second)
	_ = timer.C

	safeTicker := time.NewTicker(time.Second)
	defer safeTicker.Stop()

	if a == b {
		return true
	}

	var createdAt, updatedAt time.Time
	if createdAt != updatedAt {
		return false
	}

	deadline := time.Now().Add(time.Minute)
	if time.Now() == deadline {
		return true
	}

	for _, item := range items {
		_ = item
		select {
		case <-time.After(2 * time.Second):
			return false
		default:
		}
	}

	for i := 0; i < 3; i++ {
		<-time.After(50 * time.Millisecond)
	}

	// Outside loop should not trigger TIME_AFTER_LOOP
	<-time.After(time.Second)

	return false
}
`

	report := InspectTimeSafety(TimeSafetyInspectRequest{
		FilePath: "sample.go",
		Content:  src,
		Scope:    "file",
	})

	if report.Error != "" {
		t.Fatalf("unexpected error: %s", report.Error)
	}
	if report.UnstoppedTicker != 2 {
		t.Fatalf("expected 2 unstoppedTicker findings, got %d", report.UnstoppedTicker)
	}
	if report.TimeEquality != 3 {
		t.Fatalf("expected 3 timeEquality findings, got %d", report.TimeEquality)
	}
	if report.TimeAfterLoop != 2 {
		t.Fatalf("expected 2 timeAfterLoop findings, got %d", report.TimeAfterLoop)
	}
	if report.TotalCount != 7 {
		t.Fatalf("expected totalCount 7, got %d", report.TotalCount)
	}
	if report.AutoFixable != 5 {
		t.Fatalf("expected autoFixable 5, got %d", report.AutoFixable)
	}

	foundTicker := false
	foundEqual := false
	foundNotEqual := false
	foundTimeAfter := false

	for _, f := range report.Findings {
		if f.Category == "TICKER_UNSTOPPED" && f.VarName == "ticker" {
			foundTicker = true
			if f.Replacement != "defer ticker.Stop()" {
				t.Errorf("unexpected ticker replacement: %q", f.Replacement)
			}
		}
		if f.Category == "TIME_EQUALITY" && f.Replacement == "a.Equal(b)" {
			foundEqual = true
		}
		if f.Category == "TIME_EQUALITY" && f.Replacement == "!createdAt.Equal(updatedAt)" {
			foundNotEqual = true
		}
		if f.Category == "TIME_AFTER_LOOP" {
			foundTimeAfter = true
			if f.CanAutoFix {
				t.Errorf("expected TIME_AFTER_LOOP CanAutoFix=false")
			}
		}
	}

	if !foundTicker || !foundEqual || !foundNotEqual || !foundTimeAfter {
		t.Fatalf("missing expected findings: ticker=%v equal=%v notEqual=%v timeAfter=%v",
			foundTicker, foundEqual, foundNotEqual, foundTimeAfter)
	}
}

func TestTimeSafetySingleFixAndFixAll(t *testing.T) {
	src := `package sample

import "time"

func SyncSchedule(startTime, endTime time.Time, expiresAt time.Time) bool {
	ticker := time.NewTicker(250 * time.Millisecond)
	_ = ticker.C

	now := time.Now()
	if startTime == endTime {
		return true
	}
	if now != expiresAt {
		return false
	}
	return true
}
`

	initial := InspectTimeSafety(TimeSafetyInspectRequest{
		FilePath: "schedule.go",
		Content:  src,
		Scope:    "file",
	})
	if initial.TotalCount != 3 {
		t.Fatalf("expected 3 findings, got %d", initial.TotalCount)
	}
	if initial.UnstoppedTicker != 1 || initial.TimeEquality != 2 {
		t.Fatalf("unexpected counts: ticker=%d equality=%d", initial.UnstoppedTicker, initial.TimeEquality)
	}

	singleRes := ApplyTimeSafetyFixes(TimeSafetyFixRequest{
		FilePath:  "schedule.go",
		Content:   src,
		FindingID: initial.Findings[0].ID,
	})
	if singleRes.Error != "" {
		t.Fatalf("unexpected single fix error: %s", singleRes.Error)
	}
	if singleRes.AppliedCount != 1 {
		t.Fatalf("expected appliedCount 1, got %d", singleRes.AppliedCount)
	}
	if !strings.Contains(singleRes.NewContent, "defer ticker.Stop()") {
		t.Fatalf("expected defer ticker.Stop() in single fix output:\n%s", singleRes.NewContent)
	}

	allRes := ApplyTimeSafetyFixes(TimeSafetyFixRequest{
		FilePath:  "schedule.go",
		Content:   src,
		FindingID: "",
	})
	if allRes.Error != "" {
		t.Fatalf("unexpected fix-all error: %s", allRes.Error)
	}
	if allRes.AppliedCount != 3 {
		t.Fatalf("expected appliedCount 3, got %d", allRes.AppliedCount)
	}
	if !strings.Contains(allRes.NewContent, "defer ticker.Stop()") {
		t.Errorf("missing defer ticker.Stop() in fix-all output:\n%s", allRes.NewContent)
	}
	if !strings.Contains(allRes.NewContent, "if startTime.Equal(endTime) {") {
		t.Errorf("missing startTime.Equal(endTime) in fix-all output:\n%s", allRes.NewContent)
	}
	if !strings.Contains(allRes.NewContent, "if !now.Equal(expiresAt) {") {
		t.Errorf("missing !now.Equal(expiresAt) in fix-all output:\n%s", allRes.NewContent)
	}

	formatted, err := format.Source([]byte(allRes.NewContent))
	if err != nil {
		t.Fatalf("expected valid go/format output, got err: %v", err)
	}
	if string(formatted) != allRes.NewContent {
		t.Fatalf("expected NewContent to be gofmt-formatted")
	}

	recheck := InspectTimeSafety(TimeSafetyInspectRequest{
		FilePath: "schedule.go",
		Content:  allRes.NewContent,
		Scope:    "file",
	})
	if recheck.TotalCount != 0 {
		t.Fatalf("expected 0 remaining findings after fix-all, got %d", recheck.TotalCount)
	}
}

func TestTimeSafetyWorkspaceScanning(t *testing.T) {
	tmpDir := t.TempDir()

	fileA := filepath.Join(tmpDir, "a.go")
	err := os.WriteFile(fileA, []byte(`package pkg

import "time"

func Worker() {
	t := time.NewTicker(time.Second)
	_ = t.C
}
`), 0o644)
	if err != nil {
		t.Fatal(err)
	}

	fileB := filepath.Join(tmpDir, "b.go")
	err = os.WriteFile(fileB, []byte(`package pkg

import "time"

func Check(t1, t2 time.Time, jobs []int) bool {
	for range jobs {
		<-time.After(time.Millisecond)
	}
	return t1 == t2
}
`), 0o644)
	if err != nil {
		t.Fatal(err)
	}

	testFile := filepath.Join(tmpDir, "b_test.go")
	err = os.WriteFile(testFile, []byte(`package pkg

import "time"

func IgnoreTest(t1, t2 time.Time) bool {
	return t1 == t2
}
`), 0o644)
	if err != nil {
		t.Fatal(err)
	}

	report := InspectTimeSafety(TimeSafetyInspectRequest{
		WorkspacePath: tmpDir,
		Scope:         "workspace",
	})
	if report.Error != "" {
		t.Fatalf("unexpected error: %s", report.Error)
	}
	if report.TotalCount != 3 {
		t.Fatalf("expected 3 workspace findings (excluding _test.go), got %d", report.TotalCount)
	}
	if report.UnstoppedTicker != 1 || report.TimeEquality != 1 || report.TimeAfterLoop != 1 {
		t.Fatalf("unexpected counts: ticker=%d equality=%d afterLoop=%d",
			report.UnstoppedTicker, report.TimeEquality, report.TimeAfterLoop)
	}
}

func TestTimeSafetySingleLineTickerFixCompiles(t *testing.T) {
	src := `package main

import "time"

func main() { t := time.NewTicker(time.Second); _ = t }
`

	res := ApplyTimeSafetyFixes(TimeSafetyFixRequest{
		FilePath: "main.go",
		Content:  src,
	})
	if res.Error != "" {
		t.Fatalf("unexpected error: %s", res.Error)
	}
	if res.AppliedCount != 1 {
		t.Fatalf("expected AppliedCount 1, got %d", res.AppliedCount)
	}
	if !strings.Contains(res.NewContent, "defer t.Stop()") {
		t.Fatalf("expected defer t.Stop() in fixed output:\n%s", res.NewContent)
	}

	fset := token.NewFileSet()
	astFile, err := parser.ParseFile(fset, "main.go", res.NewContent, parser.AllErrors)
	if err != nil {
		t.Fatalf("expected fixed single-line ticker function to parse cleanly, got error: %v\nOutput:\n%s", err, res.NewContent)
	}

	conf := types.Config{Importer: importer.Default()}
	if _, err := conf.Check("main", fset, []*ast.File{astFile}, nil); err != nil {
		t.Fatalf("expected fixed single-line ticker function to typecheck cleanly, got error: %v\nOutput:\n%s", err, res.NewContent)
	}

	recheck := InspectTimeSafety(TimeSafetyInspectRequest{
		FilePath: "main.go",
		Content:  res.NewContent,
		Scope:    "file",
	})
	if recheck.TotalCount != 0 {
		t.Fatalf("expected 0 remaining findings after fix, got %d:\n%s", recheck.TotalCount, res.NewContent)
	}
}
