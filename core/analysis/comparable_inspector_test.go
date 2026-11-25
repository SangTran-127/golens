package analysis

import (
	"strings"
	"testing"
)

func TestInspectComparableSafetyDetectsAllCategories(t *testing.T) {
	src := `package sample

import (
	"math"
	"time"
)

type Filter struct {
	Tags []string
}

func evaluate(score float64, t1, t2 time.Time) bool {
	cache := make(map[*Filter]string)
	_ = cache
	if score == math.NaN() {
		return false
	}
	return t1 == t2
}
`
	report, err := InspectComparableSafety(src, "sample.go")
	if err != nil {
		t.Fatalf("InspectComparableSafety failed: %v", err)
	}
	if report.TotalCount < 3 {
		t.Fatalf("expected at least 3 comparable issues, got %d", report.TotalCount)
	}

	categories := map[string]bool{}
	for _, issue := range report.Issues {
		categories[issue.Category] = true
	}
	for _, want := range []string{
		"map-key-non-comparable-or-pointer",
		"float-nan-equality-comparison",
		"time-equal-operator-mismatch",
	} {
		if !categories[want] {
			t.Fatalf("missing expected category %q in %+v", want, report.Issues)
		}
	}
}

func TestApplyComparableSafetyFixesRewritesAllIssues(t *testing.T) {
	src := `package sample

import (
	"math"
	"time"
)

type Key struct {
	ID string
}

func evaluate(score float64, t1, t2 time.Time) bool {
	cache := make(map[*Key]string)
	_ = cache
	if score == math.NaN() {
		return false
	}
	return t1 == t2
}
`
	res, err := ApplyComparableSafetyFixes(src, "sample.go", nil)
	if err != nil {
		t.Fatalf("ApplyComparableSafetyFixes failed: %v", err)
	}
	if res.AppliedCount < 3 {
		t.Fatalf("expected at least 3 applied fixes, got %d", res.AppliedCount)
	}
	if !strings.Contains(res.ModifiedSource, "map[Key]string") {
		t.Fatalf("expected pointer map key normalized to value key, got:\n%s", res.ModifiedSource)
	}
	if !strings.Contains(res.ModifiedSource, "math.IsNaN(score)") {
		t.Fatalf("expected math.IsNaN(score), got:\n%s", res.ModifiedSource)
	}
	if !strings.Contains(res.ModifiedSource, "t1.Equal(t2)") {
		t.Fatalf("expected t1.Equal(t2), got:\n%s", res.ModifiedSource)
	}
}

func TestApplyComparableSafetyFixes_NonComparablePointerKeyFallbackToString(t *testing.T) {
	src := `package sample

type Filter struct {
	Tags []string
}

func initCache() {
	cache := make(map[*Filter]int)
	_ = cache
}
`
	res, err := ApplyComparableSafetyFixes(src, "sample.go", nil)
	if err != nil {
		t.Fatalf("ApplyComparableSafetyFixes failed: %v", err)
	}
	if !strings.Contains(res.ModifiedSource, "map[string]int") {
		t.Fatalf("expected non-comparable pointer key to fallback to map[string]int, got:\n%s", res.ModifiedSource)
	}
	if strings.Contains(res.ModifiedSource, "map[Filter]int") {
		t.Fatalf("illegal non-comparable value key map[Filter]int generated:\n%s", res.ModifiedSource)
	}
}
