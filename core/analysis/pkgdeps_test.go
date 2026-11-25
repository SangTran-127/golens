package analysis

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func writePkgFile(t *testing.T, root string, relPath string, content string) string {
	t.Helper()
	full := filepath.Join(root, relPath)
	if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
		t.Fatalf("mkdir %s: %v", filepath.Dir(full), err)
	}
	if err := os.WriteFile(full, []byte(content), 0o644); err != nil {
		t.Fatalf("write %s: %v", full, err)
	}
	return full
}

func TestInspectPackageDependencies_ClassificationAndFanMetrics(t *testing.T) {
	tmpDir := t.TempDir()

	writePkgFile(t, tmpDir, "go.mod", "module example.com/kvservice\n\ngo 1.22\n")
	writePkgFile(t, tmpDir, "main.go", `package main

import (
	"fmt"
	"net/http"
	"example.com/kvservice/internal/api"
	"example.com/kvservice/internal/store"
	"github.com/google/uuid"
)

func main() {
	_, _, _, _ = fmt.Println, http.StatusOK, api.Name, store.Kind
	_ = uuid.New
}
`)
	writePkgFile(t, tmpDir, "internal/api/api.go", `package api

import (
	"fmt"
	"example.com/kvservice/internal/store"
	"golang.org/x/sync/errgroup"
)

var Name = store.Kind + fmt.Sprint(errgroup.Group{})
`)
	writePkgFile(t, tmpDir, "internal/store/store.go", `package store

import "sync"

var Kind = "mem"
var _ sync.Mutex
`)

	raw, err := InspectPackageDependencies(tmpDir)
	if err != nil {
		t.Fatalf("InspectPackageDependencies failed: %v", err)
	}

	var report PackageDependencyReport
	if err := json.Unmarshal([]byte(raw), &report); err != nil {
		t.Fatalf("json unmarshal failed: %v", err)
	}

	if report.ModulePath != "example.com/kvservice" {
		t.Fatalf("expected modulePath example.com/kvservice, got %q", report.ModulePath)
	}
	if report.PackageCount != 3 {
		t.Fatalf("expected packageCount 3, got %d", report.PackageCount)
	}
	if report.StdlibImportCount != 3 {
		t.Fatalf("expected stdlibImportCount 3 (fmt, net/http, sync), got %d", report.StdlibImportCount)
	}
	if report.ExternalImportCount != 2 {
		t.Fatalf("expected externalImportCount 2 (github.com/google/uuid, golang.org/x/sync/errgroup), got %d", report.ExternalImportCount)
	}
	if len(report.Cycles) != 0 {
		t.Fatalf("expected 0 cycles, got %d", len(report.Cycles))
	}

	pkgMap := make(map[string]PackageNode)
	for _, p := range report.Packages {
		pkgMap[p.ImportPath] = p
	}

	rootPkg, ok := pkgMap["example.com/kvservice"]
	if !ok {
		t.Fatalf("missing root package example.com/kvservice")
	}
	if rootPkg.PackageName != "main" || rootPkg.RelativeDir != "." {
		t.Fatalf("unexpected root package metadata: %+v", rootPkg)
	}
	if rootPkg.FanIn != 0 || rootPkg.FanOut != 5 {
		t.Fatalf("expected rootPkg fanIn=0 fanOut=5, got fanIn=%d fanOut=%d", rootPkg.FanIn, rootPkg.FanOut)
	}

	storePkg, ok := pkgMap["example.com/kvservice/internal/store"]
	if !ok {
		t.Fatalf("missing store package")
	}
	if storePkg.FanIn != 2 || storePkg.FanOut != 1 {
		t.Fatalf("expected storePkg fanIn=2 fanOut=1, got fanIn=%d fanOut=%d", storePkg.FanIn, storePkg.FanOut)
	}
	if len(storePkg.ImportedBy) != 2 {
		t.Fatalf("expected storePkg importedBy 2 packages, got %v", storePkg.ImportedBy)
	}

	categories := make(map[string]string)
	for _, imp := range rootPkg.Imports {
		categories[imp.TargetPath] = imp.Category
		if imp.Line <= 0 || imp.FilePath == "" {
			t.Fatalf("expected valid filePath and line on import edge: %+v", imp)
		}
	}
	if categories["fmt"] != "stdlib" {
		t.Fatalf("expected fmt to be stdlib, got %q", categories["fmt"])
	}
	if categories["example.com/kvservice/internal/store"] != "internal" {
		t.Fatalf("expected internal/store to be internal, got %q", categories["example.com/kvservice/internal/store"])
	}
	if categories["github.com/google/uuid"] != "external" {
		t.Fatalf("expected github.com/google/uuid to be external, got %q", categories["github.com/google/uuid"])
	}
}

func TestInspectPackageDependencies_CycleDetection(t *testing.T) {
	tmpDir := t.TempDir()

	writePkgFile(t, tmpDir, "go.mod", "module example.com/app\n\ngo 1.22\n")
	aFile := writePkgFile(t, tmpDir, "a/a.go", `package a

import (
	"fmt"
	"example.com/app/b"
)

var _ = fmt.Sprint(b.Val)
`)
	bFile := writePkgFile(t, tmpDir, "b/b.go", `package b

import "example.com/app/a"

var Val = a. hooks
`)

	raw, err := InspectPackageDependencies(tmpDir)
	if err != nil {
		t.Fatalf("InspectPackageDependencies failed: %v", err)
	}

	var report PackageDependencyReport
	if err := json.Unmarshal([]byte(raw), &report); err != nil {
		t.Fatalf("json unmarshal failed: %v", err)
	}

	if len(report.Cycles) != 1 {
		t.Fatalf("expected 1 cycle, got %d (%+v)", len(report.Cycles), report.Cycles)
	}

	cycle := report.Cycles[0]
	expectedChain := []string{"example.com/app/a", "example.com/app/b", "example.com/app/a"}
	if len(cycle.Chain) != len(expectedChain) {
		t.Fatalf("expected cycle chain %v, got %v", expectedChain, cycle.Chain)
	}
	for i := range expectedChain {
		if cycle.Chain[i] != expectedChain[i] {
			t.Fatalf("expected cycle chain[%d]=%q, got %q", i, expectedChain[i], cycle.Chain[i])
		}
	}

	if len(cycle.Edges) != 2 {
		t.Fatalf("expected 2 cycle edges, got %d", len(cycle.Edges))
	}
	if cycle.Edges[0].FromPkg != "example.com/app/a" || cycle.Edges[0].ToPkg != "example.com/app/b" {
		t.Fatalf("unexpected edge[0]: %+v", cycle.Edges[0])
	}
	if cycle.Edges[0].FilePath != aFile || cycle.Edges[0].Line != 5 {
		t.Fatalf("expected edge[0] at %s:5, got %s:%d", aFile, cycle.Edges[0].FilePath, cycle.Edges[0].Line)
	}
	if cycle.Edges[1].FromPkg != "example.com/app/b" || cycle.Edges[1].ToPkg != "example.com/app/a" {
		t.Fatalf("unexpected edge[1]: %+v", cycle.Edges[1])
	}
	if cycle.Edges[1].FilePath != bFile || cycle.Edges[1].Line != 3 {
		t.Fatalf("expected edge[1] at %s:3, got %s:%d", bFile, cycle.Edges[1].FilePath, cycle.Edges[1].Line)
	}
}
