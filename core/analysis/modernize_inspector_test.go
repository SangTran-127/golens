package analysis

import (
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestInspectGoModernization_AllThreeCategories(t *testing.T) {
	src := `package service

type Payload struct {
	Meta map[string]interface{}
}

func ProcessItems(items []interface{}, limit int, a, b int) int {
	for i := 0; i < limit; i++ {
		_ = items[i]
	}

	for j := 0; j < limit; j++ {
		j++
	}

	if a < b {
		return a
	}
	return b
}
`

	report, err := InspectGoModernization("", "service.go", src, false)
	if err != nil {
		t.Fatalf("InspectGoModernization returned error: %v", err)
	}

	if report.AnyCount != 2 {
		t.Errorf("expected AnyCount=2, got %d", report.AnyCount)
	}
	if report.RangeIntCount != 1 {
		t.Errorf("expected RangeIntCount=1 (excluding mutated loop var j), got %d", report.RangeIntCount)
	}
	if report.MinMaxCount != 1 {
		t.Errorf("expected MinMaxCount=1, got %d", report.MinMaxCount)
	}
	if report.TotalFindings != 4 {
		t.Fatalf("expected TotalFindings=4, got %d: %+v", report.TotalFindings, report.Findings)
	}

	var sawAny, sawRangeInt, sawMinMax bool
	for _, f := range report.Findings {
		switch f.Kind {
		case "MODERN_ANY":
			sawAny = true
			if f.Title != "Use any instead of interface{}" {
				t.Errorf("unexpected MODERN_ANY title: %q", f.Title)
			}
			if f.SuggestedFix != "Replace interface{} with any" {
				t.Errorf("unexpected MODERN_ANY SuggestedFix: %q", f.SuggestedFix)
			}
			if !f.CanQuickFix {
				t.Errorf("expected CanQuickFix=true for MODERN_ANY")
			}
		case "MODERN_RANGE_INT":
			sawRangeInt = true
			wantTitle := "Use a range-over-int loop: for i := range limit"
			if f.Title != wantTitle {
				t.Errorf("expected MODERN_RANGE_INT title %q, got %q", wantTitle, f.Title)
			}
			wantFix := "Rewrite loop header to 'for i := range limit'"
			if f.SuggestedFix != wantFix {
				t.Errorf("expected MODERN_RANGE_INT SuggestedFix %q, got %q", wantFix, f.SuggestedFix)
			}
			if !f.CanQuickFix {
				t.Errorf("expected CanQuickFix=true for MODERN_RANGE_INT")
			}
		case "MODERN_MIN_MAX":
			sawMinMax = true
			wantTitle := "Use the built-in min or max"
			if f.Title != wantTitle {
				t.Errorf("expected MODERN_MIN_MAX title %q, got %q", wantTitle, f.Title)
			}
		}
	}

	if !sawAny || !sawRangeInt || !sawMinMax {
		t.Errorf("missing expected findings: sawAny=%v sawRangeInt=%v sawMinMax=%v", sawAny, sawRangeInt, sawMinMax)
	}
}

func TestInspectGoModernization_FixAnyAndRangeInt(t *testing.T) {
	src := `package worker

type Entry struct {
	Value interface{}
}

func RunBatch(n int, extra interface{}) {
	for i := 0; i < n; i++ {
		_ = i
	}
	for _ := 0; _ < 3; _++ {
	}
	_ = extra
}
`

	report, err := InspectGoModernization("", "worker.go", src, false)
	if err != nil {
		t.Fatalf("InspectGoModernization failed: %v", err)
	}
	if report.AnyCount != 2 || report.RangeIntCount != 2 {
		t.Fatalf("expected AnyCount=2 and RangeIntCount=2, got %+v", report)
	}

	cur := src
	for _, f := range report.Findings {
		if !f.CanQuickFix {
			continue
		}
		cur, err = FixGoModernizationIssue("worker.go", cur, f.Line, f.Kind, f.TargetName)
		if err != nil {
			t.Fatalf("FixGoModernizationIssue(%s at line %d) failed: %v", f.Kind, f.Line, err)
		}
	}

	if strings.Contains(cur, "interface{}") {
		t.Errorf("expected all interface{} replaced with any, got:\n%s", cur)
	}
	if !strings.Contains(cur, "Value any") {
		t.Errorf("expected 'Value any', got:\n%s", cur)
	}
	if !strings.Contains(cur, "extra any") {
		t.Errorf("expected 'extra any', got:\n%s", cur)
	}
	if !strings.Contains(cur, "for i := range n {") {
		t.Errorf("expected 'for i := range n {', got:\n%s", cur)
	}
	if !strings.Contains(cur, "for range 3 {") {
		t.Errorf("expected 'for range 3 {', got:\n%s", cur)
	}

	if _, parseErr := parser.ParseFile(token.NewFileSet(), "worker.go", cur, parser.ParseComments); parseErr != nil {
		t.Fatalf("fixed code does not parse cleanly: %v\n%s", parseErr, cur)
	}

	afterReport, err := InspectGoModernization("", "worker.go", cur, false)
	if err != nil {
		t.Fatalf("re-inspect failed: %v", err)
	}
	if afterReport.TotalFindings != 0 {
		t.Errorf("expected 0 findings after fixing all issues, got %d: %+v", afterReport.TotalFindings, afterReport.Findings)
	}

	idempotent, err := FixGoModernizationIssue("worker.go", cur, 4, "MODERN_ANY", "interface{}")
	if err != nil {
		t.Fatalf("idempotent call returned error: %v", err)
	}
	if idempotent != cur {
		t.Errorf("expected FixGoModernizationIssue to be idempotent")
	}
}

func TestInspectGoModernization_WorkspaceInspection(t *testing.T) {
	tmpDir := t.TempDir()

	mainFile := filepath.Join(tmpDir, "legacy.go")
	mainSrc := `package legacy

func Collect(n int) []interface{} {
	out := make([]interface{}, 0, n)
	for i := 0; i < n; i++ {
		out = append(out, i)
	}
	return out
}
`
	if err := os.WriteFile(mainFile, []byte(mainSrc), 0644); err != nil {
		t.Fatal(err)
	}

	vendorDir := filepath.Join(tmpDir, "vendor", "oldpkg")
	if err := os.MkdirAll(vendorDir, 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(vendorDir, "old.go"), []byte(`package oldpkg
var Global interface{}
`), 0644); err != nil {
		t.Fatal(err)
	}

	report, err := InspectGoModernization(tmpDir, mainFile, "", true)
	if err != nil {
		t.Fatalf("workspace InspectGoModernization failed: %v", err)
	}
	if report.AnyCount != 2 || report.RangeIntCount != 1 || report.TotalFindings != 3 {
		t.Fatalf("expected 3 findings from workspace (excluding vendor), got %+v", report)
	}
}

func TestInspectGoModernization_SkipsRangeIntWhenBoundMutatedInBody(t *testing.T) {
	src := `package main

import "fmt"

func main() {
	n := 3
	for i := 0; i < n; i++ {
		n = 1
		fmt.Println(i)
	}
}
`
	report, err := InspectGoModernization("", "main.go", src, false)
	if err != nil {
		t.Fatalf("InspectGoModernization failed: %v", err)
	}
	if report.RangeIntCount != 0 || report.TotalFindings != 0 {
		t.Fatalf("expected 0 range-int findings when bound n is mutated in loop body, got %+v", report)
	}

	fixed, err := FixGoModernizationIssue("main.go", src, 7, "MODERN_RANGE_INT", "i")
	if err != nil {
		t.Fatalf("FixGoModernizationIssue failed: %v", err)
	}
	if strings.Contains(fixed, "range n") {
		t.Fatalf("did not expect loop to be rewritten to 'range n' when bound n is mutated:\n%s", fixed)
	}
}
