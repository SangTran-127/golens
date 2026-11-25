package analysis

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestInspectFunctionComplexity_SimpleModerateAndHigh(t *testing.T) {
	src := `package store

type KVStore struct {
	data map[string]string
}

func (s *KVStore) Get(key string) (string, bool) {
	v, ok := s.data[key]
	return v, ok
}

func EvaluateModerate(items []int, flag bool) int {
	total := 0
	for _, x := range items {
		if x > 10 && flag {
			for i := 0; i < x; i++ {
				if i%2 == 0 {
					total += i
				} else if i%3 == 0 {
					total -= i
				}
			}
		}
	}
	return total
}

func DeeplyComplexRouter(events []string, mode int, ch <-chan int) int {
	score := 0
outer:
	for _, ev := range events {
		if ev == "" || ev == "ignore" {
			continue outer
		}
		switch mode {
		case 1:
			for i := 0; i < len(ev); i++ {
				if ev[i] == 'a' && i > 0 {
					select {
					case v := <-ch:
						if v > 0 {
							score += v
						}
					default:
						score++
					}
				} else if ev[i] == 'b' {
					score += 2
				}
			}
		case 2:
			if len(ev) > 5 {
				score += 5
			}
		default:
			score--
		}
	}
	return score
}
`
	report, err := InspectFunctionComplexity("/workspace", "/workspace/pkg/store.go", src, false)
	if err != nil {
		t.Fatalf("InspectFunctionComplexity returned unexpected error: %v", err)
	}

	if report.TotalFunctions != 3 {
		t.Fatalf("expected 3 functions, got %d", report.TotalFunctions)
	}
	if report.HighCount != 1 || report.ModerateCount != 1 || report.GoodCount != 1 {
		t.Fatalf("expected counts high=1 moderate=1 good=1, got high=%d moderate=%d good=%d",
			report.HighCount, report.ModerateCount, report.GoodCount)
	}

	// Verify sorted descending by cognitive complexity
	first := report.Functions[0]
	second := report.Functions[1]
	third := report.Functions[2]

	if first.Name != "DeeplyComplexRouter" {
		t.Errorf("expected highest complexity function first (DeeplyComplexRouter), got %q", first.Name)
	}
	if first.Rating != "high" {
		t.Errorf("expected DeeplyComplexRouter rating 'high', got %q (cognitive=%d, cyclomatic=%d)",
			first.Rating, first.Cognitive, first.Cyclomatic)
	}
	if first.Cognitive <= 15 {
		t.Errorf("expected DeeplyComplexRouter cognitive > 15, got %d", first.Cognitive)
	}
	if first.MaxNesting < 4 {
		t.Errorf("expected DeeplyComplexRouter maxNesting >= 4, got %d", first.MaxNesting)
	}
	if first.ParamCount != 3 || first.ReturnCount != 1 {
		t.Errorf("expected DeeplyComplexRouter params=3 returns=1, got params=%d returns=%d",
			first.ParamCount, first.ReturnCount)
	}
	if !strings.Contains(first.Suggestion, "Extract Function") {
		t.Errorf("expected actionable suggestion mentioning Extract Function, got %q", first.Suggestion)
	}

	if second.Name != "EvaluateModerate" {
		t.Errorf("expected second function EvaluateModerate, got %q", second.Name)
	}
	if second.Rating != "moderate" {
		t.Errorf("expected EvaluateModerate rating 'moderate', got %q (cognitive=%d, cyclomatic=%d, maxNesting=%d)",
			second.Rating, second.Cognitive, second.Cyclomatic, second.MaxNesting)
	}
	// EvaluateModerate:
	// Cyclomatic: 1 + range(1) + if(1) + &&(1) + for(1) + if(1) + else-if(1) = 7
	// Cognitive: range(1+0=1) + if(1+1=2) + &&(1) + for(1+2=3) + if(1+3=4) + else-if(1) = 12
	if second.Cyclomatic != 7 {
		t.Errorf("expected EvaluateModerate cyclomatic=7, got %d", second.Cyclomatic)
	}
	if second.Cognitive != 12 {
		t.Errorf("expected EvaluateModerate cognitive=12, got %d", second.Cognitive)
	}
	if second.MaxNesting != 4 {
		t.Errorf("expected EvaluateModerate maxNesting=4, got %d", second.MaxNesting)
	}
	hasNestedLoopsDriver := false
	for _, d := range second.Drivers {
		if strings.Contains(d, "nested loops") {
			hasNestedLoopsDriver = true
			break
		}
	}
	if !hasNestedLoopsDriver {
		t.Errorf("expected drivers to include 'nested loops', got %v", second.Drivers)
	}

	if third.Name != "(*KVStore).Get" {
		t.Errorf("expected third function '(*KVStore).Get', got %q", third.Name)
	}
	if third.Rating != "good" || third.Cyclomatic != 1 || third.Cognitive != 0 || third.MaxNesting != 0 {
		t.Errorf("expected (*KVStore).Get good/1/0/0, got rating=%s cyclo=%d cog=%d nest=%d",
			third.Rating, third.Cyclomatic, third.Cognitive, third.MaxNesting)
	}
	if third.RelFile != "pkg/store.go" {
		t.Errorf("expected relFile 'pkg/store.go', got %q", third.RelFile)
	}
	if third.ParamCount != 1 || third.ReturnCount != 2 {
		t.Errorf("expected (*KVStore).Get params=1 returns=2, got params=%d returns=%d",
			third.ParamCount, third.ReturnCount)
	}
}

func TestInspectFunctionComplexity_WorkspaceScanningAndSorting(t *testing.T) {
	tmpDir := t.TempDir()

	// Valid package file 1
	fileA := filepath.Join(tmpDir, "cmd", "main.go")
	if err := os.MkdirAll(filepath.Dir(fileA), 0o755); err != nil {
		t.Fatal(err)
	}
	srcA := `package main

func main() {
	println("hello")
}
`
	if err := os.WriteFile(fileA, []byte(srcA), 0o644); err != nil {
		t.Fatal(err)
	}

	// Valid package file 2 with complex function
	fileB := filepath.Join(tmpDir, "internal", "engine.go")
	if err := os.MkdirAll(filepath.Dir(fileB), 0o755); err != nil {
		t.Fatal(err)
	}
	srcB := `package internal

func ProcessBatch(matrix [][]int) int {
	sum := 0
	for _, row := range matrix {
		for _, v := range row {
			if v > 0 {
				if v%2 == 0 {
					sum += v
				} else {
					sum += v * 2
				}
			}
		}
	}
	return sum
}
`
	if err := os.WriteFile(fileB, []byte(srcB), 0o644); err != nil {
		t.Fatal(err)
	}

	// Excluded vendor directory file (must be ignored)
	vendorFile := filepath.Join(tmpDir, "vendor", "dep", "dep.go")
	if err := os.MkdirAll(filepath.Dir(vendorFile), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(vendorFile, []byte("package dep\nfunc IgnoredVendorFunc() {}\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	// Excluded .build directory file (must be ignored)
	buildFile := filepath.Join(tmpDir, ".build", "gen.go")
	if err := os.MkdirAll(filepath.Dir(buildFile), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(buildFile, []byte("package gen\nfunc IgnoredBuildFunc() {}\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	// Override fileA in-memory content to add a second function
	unsavedMain := `package main

func main() {
	println("hello")
}

func helperWithBranch(x int) int {
	if x > 0 {
		return x
	}
	return 0
}
`

	report, err := InspectFunctionComplexity(tmpDir, fileA, unsavedMain, true)
	if err != nil {
		t.Fatalf("InspectFunctionComplexity workspace scan failed: %v", err)
	}

	if report.TotalFunctions != 3 {
		t.Fatalf("expected 3 functions across workspace (excluding vendor/.build), got %d: %+v",
			report.TotalFunctions, report.Functions)
	}

	if report.Functions[0].Name != "ProcessBatch" {
		t.Errorf("expected ProcessBatch first, got %q", report.Functions[0].Name)
	}
	if report.Functions[0].RelFile != "internal/engine.go" {
		t.Errorf("expected RelFile 'internal/engine.go', got %q", report.Functions[0].RelFile)
	}
	if report.Functions[1].Name != "helperWithBranch" {
		t.Errorf("expected helperWithBranch second, got %q", report.Functions[1].Name)
	}
	if report.Functions[2].Name != "main" {
		t.Errorf("expected main third, got %q", report.Functions[2].Name)
	}
}

func TestInspectFunctionComplexity_RatingThresholdsGoodUpToTen(t *testing.T) {
	src := `package main

func Analyze(a, b, c bool) int {
	if a {
		if b {
			if c {
				return 1
			}
		}
	}
	return 0
}
`
	report, err := InspectFunctionComplexity("", "main.go", src, false)
	if err != nil {
		t.Fatalf("InspectFunctionComplexity failed: %v", err)
	}
	if len(report.Functions) != 1 {
		t.Fatalf("expected 1 function, got %d", len(report.Functions))
	}
	fn := report.Functions[0]
	if fn.Cognitive != 6 || fn.Cyclomatic != 4 || fn.MaxNesting != 3 {
		t.Fatalf("expected cognitive=6 cyclomatic=4 maxNesting=3, got %+v", fn)
	}
	if fn.Rating != "good" || report.GoodCount != 1 || report.ModerateCount != 0 {
		t.Fatalf("expected Analyze with cognitive=6 (<=10) to be rated 'good', got rating=%q report=%+v", fn.Rating, report)
	}
}
