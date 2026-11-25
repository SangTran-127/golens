package analysis

import (
	"go/format"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestPreallocInspectAllCategories(t *testing.T) {
	src := `package sample

func ProcessItems(items []string, nums []int) ([]string, []int, map[string]int, []string) {
	var out []string
	for _, item := range items {
		out = append(out, item)
	}

	doubled := []int{}
	for i := 0; i < len(nums); i++ {
		doubled = append(doubled, nums[i]*2)
	}

	extra := make([]string, 0)
	for _, item := range items {
		extra = append(extra, item+"!")
	}

	alreadySized := make([]string, 0, len(items))
	for _, item := range items {
		alreadySized = append(alreadySized, item)
	}

	indexByKey := make(map[string]int)
	for idx, item := range items {
		indexByKey[item] = idx
	}

	lookup := map[int]int{}
	for idx, n := range nums {
		lookup[idx] = n
	}

	preSizedMap := make(map[string]int, len(items))
	for idx, item := range items {
		preSizedMap[item] = idx
	}

	cloned := append([]string(nil), items...)
	clonedNums := append([]int{}, nums...)
	_ = extra
	_ = alreadySized
	_ = lookup
	_ = preSizedMap
	_ = clonedNums

	return out, doubled, indexByKey, cloned
}
`

	report := InspectPrealloc(PreallocInspectRequest{
		FilePath: "sample.go",
		Content:  src,
		Scope:    "file",
	})

	if report.Error != "" {
		t.Fatalf("unexpected error: %s", report.Error)
	}
	if report.SlicePrealloc != 3 {
		t.Fatalf("expected 3 slicePrealloc findings, got %d", report.SlicePrealloc)
	}
	if report.MapPrealloc != 2 {
		t.Fatalf("expected 2 mapPrealloc findings, got %d", report.MapPrealloc)
	}
	if report.SliceClone != 2 {
		t.Fatalf("expected 2 sliceClone findings, got %d", report.SliceClone)
	}
	if report.TotalCount != 7 {
		t.Fatalf("expected totalCount 7, got %d", report.TotalCount)
	}
	if report.AutoFixable != 7 {
		t.Fatalf("expected autoFixable 7, got %d", report.AutoFixable)
	}

	foundOut := false
	foundIndexByKey := false
	foundCloned := false
	for _, f := range report.Findings {
		if f.Category == "PREALLOC_SLICE" && f.VarName == "out" {
			foundOut = true
			if f.Replacement != "out := make([]string, 0, len(items))" {
				t.Errorf("unexpected replacement for out: %q", f.Replacement)
			}
		}
		if f.Category == "PREALLOC_MAP" && f.VarName == "indexByKey" {
			foundIndexByKey = true
			if f.Replacement != "indexByKey := make(map[string]int, len(items))" {
				t.Errorf("unexpected replacement for indexByKey: %q", f.Replacement)
			}
		}
		if f.Category == "SLICE_CLONE" && strings.Contains(f.Replacement, "slices.Clone(items)") {
			foundCloned = true
		}
	}
	if !foundOut || !foundIndexByKey || !foundCloned {
		t.Fatalf("missing expected findings: out=%v indexByKey=%v cloned=%v", foundOut, foundIndexByKey, foundCloned)
	}
}

func TestPreallocSingleFixAndFixAll(t *testing.T) {
	src := `package sample

func Transform(src []string) ([]string, map[string]int, []string) {
	var names []string
	for _, s := range src {
		names = append(names, s)
	}

	counts := make(map[string]int)
	for i, s := range src {
		counts[s] = i
	}

	cp := append([]string(nil), src...)
	return names, counts, cp
}
`

	initial := InspectPrealloc(PreallocInspectRequest{
		FilePath: "transform.go",
		Content:  src,
		Scope:    "file",
	})
	if initial.TotalCount != 3 {
		t.Fatalf("expected 3 findings, got %d", initial.TotalCount)
	}

	singleRes := ApplyPreallocFixes(PreallocFixRequest{
		FilePath:  "transform.go",
		Content:   src,
		FindingID: initial.Findings[0].ID,
	})
	if singleRes.Error != "" {
		t.Fatalf("unexpected single fix error: %s", singleRes.Error)
	}
	if singleRes.AppliedCount != 1 {
		t.Fatalf("expected appliedCount 1, got %d", singleRes.AppliedCount)
	}
	if !strings.Contains(singleRes.NewContent, "names := make([]string, 0, len(src))") {
		t.Fatalf("expected pre-allocated slice in single fix output:\n%s", singleRes.NewContent)
	}

	allRes := ApplyPreallocFixes(PreallocFixRequest{
		FilePath:  "transform.go",
		Content:   src,
		FindingID: "",
	})
	if allRes.Error != "" {
		t.Fatalf("unexpected fix-all error: %s", allRes.Error)
	}
	if allRes.AppliedCount != 3 {
		t.Fatalf("expected appliedCount 3, got %d", allRes.AppliedCount)
	}
	if !strings.Contains(allRes.NewContent, "names := make([]string, 0, len(src))") {
		t.Errorf("missing slice prealloc in fix-all output:\n%s", allRes.NewContent)
	}
	if !strings.Contains(allRes.NewContent, "counts := make(map[string]int, len(src))") {
		t.Errorf("missing map prealloc in fix-all output:\n%s", allRes.NewContent)
	}
	if !strings.Contains(allRes.NewContent, "slices.Clone(src)") {
		t.Errorf("missing slices.Clone in fix-all output:\n%s", allRes.NewContent)
	}

	formatted, err := format.Source([]byte(allRes.NewContent))
	if err != nil {
		t.Fatalf("expected valid go/format output, got err: %v", err)
	}
	if string(formatted) != allRes.NewContent {
		t.Fatalf("expected NewContent to be gofmt-formatted")
	}

	recheck := InspectPrealloc(PreallocInspectRequest{
		FilePath: "transform.go",
		Content:  allRes.NewContent,
		Scope:    "file",
	})
	if recheck.TotalCount != 0 {
		t.Fatalf("expected 0 remaining findings after fix-all, got %d", recheck.TotalCount)
	}
}

func TestPreallocWorkspaceScanning(t *testing.T) {
	tmpDir := t.TempDir()

	fileA := filepath.Join(tmpDir, "a.go")
	err := os.WriteFile(fileA, []byte(`package pkg

func Collect(in []int) []int {
	var res []int
	for _, x := range in {
		res = append(res, x)
	}
	return res
}
`), 0o644)
	if err != nil {
		t.Fatal(err)
	}

	fileB := filepath.Join(tmpDir, "b.go")
	err = os.WriteFile(fileB, []byte(`package pkg

func BuildMap(keys []string) map[string]bool {
	m := map[string]bool{}
	for _, k := range keys {
		m[k] = true
	}
	return m
}
`), 0o644)
	if err != nil {
		t.Fatal(err)
	}

	testFile := filepath.Join(tmpDir, "b_test.go")
	err = os.WriteFile(testFile, []byte(`package pkg

func IgnoreTest(keys []string) []string {
	var s []string
	for _, k := range keys {
		s = append(s, k)
	}
	return s
}
`), 0o644)
	if err != nil {
		t.Fatal(err)
	}

	report := InspectPrealloc(PreallocInspectRequest{
		WorkspacePath: tmpDir,
		Scope:         "workspace",
	})
	if report.Error != "" {
		t.Fatalf("unexpected error: %s", report.Error)
	}
	if report.TotalCount != 2 {
		t.Fatalf("expected 2 workspace findings (excluding _test.go), got %d", report.TotalCount)
	}
	if report.SlicePrealloc != 1 || report.MapPrealloc != 1 {
		t.Fatalf("unexpected counts: slice=%d map=%d", report.SlicePrealloc, report.MapPrealloc)
	}
}

func TestPreallocFixPreservesSameLineStatements(t *testing.T) {
	src := `package main

import "fmt"

func audit() { fmt.Println("AUDIT") }

func work(src []int) []int {
	var out []int; audit()
	for _, v := range src {
		out = append(out, v)
	}
	return out
}
`

	res := ApplyPreallocFixes(PreallocFixRequest{
		FilePath: "main.go",
		Content:  src,
	})
	if res.Error != "" {
		t.Fatalf("ApplyPreallocFixes returned error: %s", res.Error)
	}
	if res.AppliedCount != 1 {
		t.Fatalf("expected AppliedCount=1, got %d", res.AppliedCount)
	}
	if !strings.Contains(res.NewContent, "out := make([]int, 0, len(src))") {
		t.Fatalf("expected preallocated slice make call in NewContent:\n%s", res.NewContent)
	}
	if !strings.Contains(res.NewContent, "audit()") {
		t.Fatalf("expected same-line audit() call to be preserved in NewContent:\n%s", res.NewContent)
	}
}
