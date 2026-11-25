package testutil

import (
	"math"
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func TestParseCoverProfile(t *testing.T) {
	dir := t.TempDir()
	profilePath := filepath.Join(dir, "cover.out")
	profileContent := `mode: atomic
example.com/myapp/pkg/calc.go:10.15,12.2 2 1
example.com/myapp/pkg/calc.go:12.2,14.2 1 0
example.com/myapp/pkg/calc.go:20.5,22.2 3 0
example.com/myapp/root.go:5.10,7.2 4 2
`
	if err := os.WriteFile(profilePath, []byte(profileContent), 0o644); err != nil {
		t.Fatal(err)
	}

	filesCov, pkgCov, err := ParseCoverProfile(
		profilePath,
		"/workspace/myapp",
		"example.com/myapp",
		map[string]string{"example.com/myapp/pkg": "pkg"},
	)
	if err != nil {
		t.Fatalf("ParseCoverProfile failed: %v", err)
	}
	if len(filesCov) != 2 {
		t.Fatalf("expected 2 files, got %+v", filesCov)
	}

	calc := filesCov[0]
	if calc.File != "/workspace/myapp/pkg/calc.go" {
		t.Fatalf("calc.File = %q", calc.File)
	}
	// Line 12 has both a covered statement (count=1) and an uncovered statement (count=0); covered wins.
	if !reflect.DeepEqual(calc.CoveredLines, []int{10, 11, 12}) {
		t.Fatalf("calc.CoveredLines = %v", calc.CoveredLines)
	}
	if !reflect.DeepEqual(calc.UncoveredLines, []int{13, 14, 20, 21, 22}) {
		t.Fatalf("calc.UncoveredLines = %v", calc.UncoveredLines)
	}

	root := filesCov[1]
	if root.File != "/workspace/myapp/root.go" {
		t.Fatalf("root.File = %q", root.File)
	}
	if !reflect.DeepEqual(root.CoveredLines, []int{5, 6, 7}) || len(root.UncoveredLines) != 0 {
		t.Fatalf("root coverage = %+v", root)
	}

	// pkg has 2 covered statements out of 2+1+3 = 6 total statements -> 33.333...%
	if got := pkgCov["example.com/myapp/pkg"]; math.Abs(got-(200.0/6.0)) > 0.01 {
		t.Fatalf("pkgCov[pkg] = %v, want %v", got, 200.0/6.0)
	}
	if got := pkgCov["example.com/myapp"]; math.Abs(got-100.0) > 0.01 {
		t.Fatalf("pkgCov[root] = %v, want 100.0", got)
	}
}
